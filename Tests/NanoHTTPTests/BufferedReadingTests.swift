//
//  BufferedReadingTests.swift
//  NanoHTTPTests
//
//  2.0 (R8): a socket reads in blocks of 16 KB instead of byte by byte. Data that has been read but not
//  consumed (the next of two pipelined requests, the second of two WebSocket frames that arrived in one
//  packet) is in memory, where `poll` cannot see it: the servers must look at it before they wait.
//

import XCTest
import Darwin
@testable import NanoHTTP

/// A connected pair of sockets: what is written to `client` can be read from `server` (a NanoSocket).
private func socketPair() -> (server: NanoSocket, client: Int32) {
  var fds: [Int32] = [0, 0]
  XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
  NanoSocket.setNoSigPipe(fds[0])
  NanoSocket.setNoSigPipe(fds[1])
  return (NanoSocket(socketFileDescriptor: fds[0]), fds[1])
}

private func send(_ bytes: [UInt8], to descriptor: Int32) {
  var sent = 0
  while sent < bytes.count {
    let n = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + sent, bytes.count - sent) }
    XCTAssertGreaterThan(n, 0)
    if n <= 0 { return }
    sent += n
  }
}

// MARK: - The socket

final class BufferedSocketTests: XCTestCase {

  func testBytesComeInOrderAcrossManyBlocks() throws {
    let (server, client) = socketPair()
    defer { Darwin.close(client) }
    let data = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    let writer = Thread { send(data, to: client) }
    writer.start()
    var received = [UInt8]()
    while received.count < data.count {
      received.append(try server.read())
    }
    XCTAssertEqual(received, data)
  }

  func testReadingBytesAndThenABlockGivesTheRestInOrder() throws {
    let (server, client) = socketPair()
    defer { Darwin.close(client) }
    let data = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 / 7) }
    let writer = Thread { send(data, to: client) }
    writer.start()
    var received = [UInt8]()
    for _ in 0..<5 { received.append(try server.read()) }
    received.append(contentsOf: try server.read(length: 60_000))
    received.append(try server.read())
    received.append(contentsOf: try server.read(length: data.count - received.count))
    XCTAssertEqual(received, data)
  }

  func testLinesAndBlocksCanBeMixed() throws {
    let (server, client) = socketPair()
    defer { Darwin.close(client) }
    send(Array("first line\r\nsecond line\r\nbody-bytes".utf8), to: client)
    XCTAssertEqual(try server.readLine(), "first line")
    XCTAssertEqual(try server.readLine(), "second line")
    XCTAssertEqual(try server.read(length: 5), Array("body-".utf8))
    XCTAssertEqual(try server.read(length: 5), Array("bytes".utf8))
  }

  func testDataThatHasBeenReadButNotConsumedIsKnown() throws {
    let (server, client) = socketPair()
    defer { Darwin.close(client) }
    XCTAssertFalse(server.hasBufferedData)
    send(Array("0123456789".utf8), to: client)
    XCTAssertEqual(try server.read(), UInt8(ascii: "0"))
    XCTAssertTrue(server.hasBufferedData, "the other nine bytes are in the buffer")
    _ = try server.read(length: 9)
    XCTAssertFalse(server.hasBufferedData)
  }

  /// The kernel has nothing more to give, but the buffer has: waiting for data must not wait.
  func testWaitingForDataSeesBufferedData() throws {
    let (server, client) = socketPair()
    defer { Darwin.close(client) }
    send(Array("ab".utf8), to: client)
    _ = try server.read()
    let begin = Date()
    XCTAssertTrue(try server.waitUntilReadable(timeout: 5))
    XCTAssertTrue(try server.awaitData())
    XCTAssertLessThan(Date().timeIntervalSince(begin), 1)
  }

  func testTheEndOfTheConnectionIsReportedAfterTheBufferedData() throws {
    let (server, client) = socketPair()
    send(Array("xyz".utf8), to: client)
    Darwin.close(client)
    XCTAssertEqual(try server.read(), UInt8(ascii: "x"))
    XCTAssertEqual(try server.read(), UInt8(ascii: "y"))
    XCTAssertEqual(try server.read(), UInt8(ascii: "z"))
    XCTAssertThrowsError(try server.read())
  }

  func testAReadThatTimesOutKeepsTheBufferedData() throws {
    let (server, client) = socketPair()
    defer { Darwin.close(client) }
    server.setReceiveTimeout(0.2)
    send(Array("abc".utf8), to: client)
    XCTAssertEqual(try server.read(), UInt8(ascii: "a"))
    XCTAssertEqual(try server.read(), UInt8(ascii: "b"))
    XCTAssertEqual(try server.read(), UInt8(ascii: "c"))
    XCTAssertThrowsError(try server.read()) { error in
      guard case NanoSocketError.timedOut = error else {
        return XCTFail("\(error)")
      }
    }
    send(Array("d".utf8), to: client) // and the socket still works afterwards
    XCTAssertEqual(try server.read(), UInt8(ascii: "d"))
  }
}

// MARK: - Servers

final class PipeliningTests: XCTestCase {

  private func request(_ path: String, keepAlive: Bool = true) -> [UInt8] {
    return RawClient.requestText("GET", path, headers: keepAlive ? ["Connection: keep-alive"] : ["Connection: close"])
  }

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.get["/a"] = { _ in .ok(.text("A")) }
      server.get["/b"] = { _ in .ok(.text("B")) }
      server.get["/c"] = { _ in .ok(.text("C")) }
      server.post["/echo"] = { request in .ok(.data(Data(request.body), contentType: "text/plain")) }
      server["/ws"] = websocket(text: { session, text in session.writeText(text) })
    }, body)
  }

  func testPipelinedRequestsInOnePacketAreAllAnswered() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      try serve(threading) { _, port in
        let client = try RawClient(port: port, timeout: 3)
        client.send(request("/a") + request("/b") + request("/c", keepAlive: false))
        XCTAssertEqual(client.readResponse()?.bodyString, "A", "\(threading)")
        XCTAssertEqual(client.readResponse()?.bodyString, "B", "\(threading)")
        XCTAssertEqual(client.readResponse()?.bodyString, "C", "\(threading)")
        XCTAssertTrue(client.waitForClose(timeout: 2), "\(threading)")
      }
    }
  }

  func testAPipelinedRequestWithABodyBehindAnother() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      try serve(threading) { _, port in
        let client = try RawClient(port: port, timeout: 3)
        let post = RawClient.requestText("POST", "/echo", headers: ["Connection: keep-alive"], body: Array("hello body".utf8))
        client.send(post + request("/a", keepAlive: false))
        XCTAssertEqual(client.readResponse()?.bodyString, "hello body", "\(threading)")
        XCTAssertEqual(client.readResponse()?.bodyString, "A", "\(threading)")
      }
    }
  }

  func testManyPipelinedRequestsOnAServerWithOneThreadAndOtherConnections() throws {
    try serve(.singleThread) { _, port in
      let pipelining = try RawClient(port: port, timeout: 5)
      pipelining.send((0..<20).flatMap { _ in request("/a") })
      let other = try RawClient(port: port, timeout: 5)
      other.send(request("/b"))
      XCTAssertEqual(other.readResponse()?.bodyString, "B")
      for _ in 0..<20 {
        XCTAssertEqual(pipelining.readResponse()?.bodyString, "A")
      }
    }
  }

  func testTwoWebSocketFramesInOnePacketAreBothAnswered() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      try serve(threading) { _, port in
        let client = try WS.connect(port: port)
        client.send(WS.text("one") + WS.text("two") + WS.text("three"))
        XCTAssertEqual(WS.readFrame(client).map { String(decoding: $0.payload, as: UTF8.self) }, "one", "\(threading)")
        XCTAssertEqual(WS.readFrame(client).map { String(decoding: $0.payload, as: UTF8.self) }, "two", "\(threading)")
        XCTAssertEqual(WS.readFrame(client).map { String(decoding: $0.payload, as: UTF8.self) }, "three", "\(threading)")
      }
    }
  }

  func testTheHandshakeAndTheFirstFrameInOnePacket() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      try serve(threading) { _, port in
        let client = try RawClient(port: port, timeout: 3)
        client.send(WS.handshakeRequest() + WS.text("early"))
        XCTAssertEqual(client.readResponse()?.status, 101, "\(threading)")
        XCTAssertEqual(WS.readFrame(client).map { String(decoding: $0.payload, as: UTF8.self) }, "early", "\(threading)")
      }
    }
  }
}
