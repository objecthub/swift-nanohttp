//
//  ConnectionSemanticsTests.swift
//  NanoHTTPTests
//
//  2.0 (H4): HTTP/1.1 connections are persistent unless somebody says `Connection: close`; HTTP/1.0 connections
//  are not unless somebody says `Connection: keep-alive`; the server says `Connection: close` when it closes;
//  bodies of requests can be sent in chunks, and `Expect: 100-continue` is answered; the bodies of responses
//  that are written by a function are sent in chunks (or have the length that the handler declares), so that
//  a connection can be used for the next request after them.
//

import XCTest
@testable import NanoHTTP

private let bothModes: [NanoHTTPServer.Configuration.Threading] = [.perConnection, .singleThread]

private func parse(_ text: String, limits: NanoHTTPParser.Limits = .init()) throws -> NanoHTTPRequest {
  return try NanoHTTPParser(socket: FileSocket(text), limits: limits).readHttpRequest()
}

private func parseError(_ text: String, limits: NanoHTTPParser.Limits = .init()) -> NanoHTTPParserError? {
  do {
    _ = try parse(text, limits: limits)
    return nil
  } catch {
    return error as? NanoHTTPParserError
  }
}

private func post(_ headers: String, _ body: String) -> String {
  return "POST /x HTTP/1.1\r\nHost: x\r\n\(headers)\r\n\r\n\(body)"
}

// MARK: - The parser: how a body ends

final class RequestFramingTests: XCTestCase {

  func testChunksAreDecodedAndPutTogether() throws {
    let request = try parse(post("Transfer-Encoding: chunked", "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"))
    XCTAssertEqual(request.bodyString, "hello world")
  }

  func testTheHeadersDescribeTheDecodedBody() throws {
    let request = try parse(post("Transfer-Encoding: chunked", "5\r\nhello\r\n0\r\n\r\n"))
    XCTAssertNil(request.header("transfer-encoding"))
    XCTAssertEqual(request.header("content-length"), "5")
  }

  func testTheSizeOfAChunkIsHexadecimalInBothCases() throws {
    let big = String(repeating: "x", count: 26)
    XCTAssertEqual(try parse(post("Transfer-Encoding: chunked", "1A\r\n\(big)\r\n0\r\n\r\n")).bodyString, big)
    XCTAssertEqual(try parse(post("Transfer-Encoding: chunked", "1a\r\n\(big)\r\n0\r\n\r\n")).bodyString, big)
  }

  func testChunkExtensionsAndTrailersAreIgnored() throws {
    let request = try parse(post("Transfer-Encoding: chunked",
                                 "3;name=value;other\r\nabc\r\n0;last\r\nX-Trailer: 1\r\nX-More: 2\r\n\r\n"))
    XCTAssertEqual(request.bodyString, "abc")
    XCTAssertNil(request.header("x-trailer"))
  }

  func testTheNameOfTheEncodingIsNotCaseSensitive() throws {
    XCTAssertEqual(try parse(post("Transfer-Encoding: Chunked", "2\r\nhi\r\n0\r\n\r\n")).bodyString, "hi")
  }

  func testAnEmptyBodyInChunks() throws {
    XCTAssertEqual(try parse(post("Transfer-Encoding: chunked", "0\r\n\r\n")).body, [])
  }

  func testChunksMayContainAnything() throws {
    let request = try NanoHTTPParser(socket: FileSocket(Array("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n".utf8)
                                                        + [0, 13, 10, 255] + Array("\r\n0\r\n\r\n".utf8))).readHttpRequest()
    XCTAssertEqual(request.body, [0, 13, 10, 255])
  }

  func testNothingBeyondTheBodyIsRead() throws {
    let socket = FileSocket(post("Transfer-Encoding: chunked", "2\r\nhi\r\n0\r\n\r\n") + "GET /next HTTP/1.1\r\n\r\n")
    let parser = NanoHTTPParser(socket: socket)
    XCTAssertEqual(try parser.readHttpRequest().bodyString, "hi")
    XCTAssertEqual(try parser.readHttpRequest().rawPath, "/next")
  }

  func testMalformedChunksAreRefused() {
    for body in ["zz\r\nhello\r\n0\r\n\r\n",       // the size is no number
                 "\r\nhello\r\n0\r\n\r\n",          // there is no size
                 "5\r\nhello0\r\n\r\n",             // no line break behind the chunk
                 "5\r\nhelloXX0\r\n\r\n",           // something else than a line break behind the chunk
                 "-5\r\nhello\r\n0\r\n\r\n",        // negative
                 "+5\r\nhello\r\n0\r\n\r\n",
                 "0x5\r\nhello\r\n0\r\n\r\n"] {
      XCTAssertEqual(parseError(post("Transfer-Encoding: chunked", body)), .invalidChunk, body)
    }
  }

  func testAChunkThatIsTooLargeIsRefusedBeforeItIsRead() {
    let limits = NanoHTTPParser.Limits(maxBodyBytes: 10)
    XCTAssertEqual(parseError(post("Transfer-Encoding: chunked", "FFFFFFFF\r\nabc"), limits: limits), .bodyTooLarge)
    XCTAssertEqual(parseError(post("Transfer-Encoding: chunked", "FFFFFFFFFFFFFFFFFFFFFFFF\r\n"), limits: limits), .bodyTooLarge)
    XCTAssertEqual(parseError(post("Transfer-Encoding: chunked", "7\r\n1234567\r\n7\r\n1234567\r\n0\r\n\r\n"), limits: limits),
                   .bodyTooLarge, "the chunks together are too large")
  }

  func testTheSizeLineOfAChunkIsLimited() {
    let limits = NanoHTTPParser.Limits(maxLineLength: 50)
    XCTAssertNotNil(parseError(post("Transfer-Encoding: chunked", "5;" + String(repeating: "e", count: 200) + "\r\nhello\r\n0\r\n\r\n"),
                               limits: limits))
  }

  func testTheTrailersAreLimited() {
    let limits = NanoHTTPParser.Limits(maxLineLength: 100, maxHeaderBytes: 400)
    let trailers = (0..<100).map { "X-Trailer-\($0): value\r\n" }.joined()
    XCTAssertNotNil(parseError(post("Transfer-Encoding: chunked", "2\r\nhi\r\n0\r\n\(trailers)\r\n"), limits: limits))
  }

  func testAStreamThatEndsInTheMiddleOfAChunkFails() {
    XCTAssertThrowsError(try parse(post("Transfer-Encoding: chunked", "5\r\nhel")))
    XCTAssertThrowsError(try parse(post("Transfer-Encoding: chunked", "5\r\nhello\r\n")))
  }

  /// If the length and the encoding both say where the body ends, a proxy and this server can disagree: refuse.
  func testALengthAndAnEncodingTogetherAreRefused() {
    XCTAssertEqual(parseError(post("Transfer-Encoding: chunked\r\nContent-Length: 5", "5\r\nhello\r\n0\r\n\r\n")), .conflictingFraming)
    XCTAssertEqual(parseError(post("Content-Length: 5\r\nTransfer-Encoding: chunked", "hello")), .conflictingFraming)
  }

  func testOtherEncodingsAreNotImplemented() {
    for encoding in ["gzip", "gzip, chunked", "chunked, gzip", "deflate", "identity", "compress"] {
      XCTAssertEqual(parseError(post("Transfer-Encoding: \(encoding)", "x")), .unsupportedTransferEncoding(encoding), encoding)
    }
  }

  func testTheVersionsThatTheServerSpeaks() throws {
    XCTAssertEqual(try parse("GET / HTTP/1.0\r\n\r\n").httpVersion, "HTTP/1.0")
    XCTAssertEqual(try parse("GET / HTTP/1.1\r\n\r\n").httpVersion, "HTTP/1.1")
    XCTAssertEqual(parseError("GET / HTTP/2.0\r\n\r\n"), .unsupportedVersion("HTTP/2.0"))
    XCTAssertEqual(parseError("GET / HTTP/0.9\r\n\r\n"), .unsupportedVersion("HTTP/0.9"))
    XCTAssertEqual(parseError("GET / HTTP/3\r\n\r\n"), .unsupportedVersion("HTTP/3"))
    if case .invalidStatusLine? = parseError("GET / SPDY\r\n\r\n") {} else {
      XCTFail("a version that is none must be a bad request")
    }
  }

  func testAMinorVersionAboveOneIsSpokenLikeHTTP11() throws {
    XCTAssertEqual(try parse("GET / HTTP/1.2\r\n\r\n").httpVersion, "HTTP/1.1")
  }

  func testWhetherTheClientWantsToKeepTheConnection() throws {
    func wants(_ line: String, _ headers: String = "") throws -> Bool {
      return try parse("GET / \(line)\r\n\(headers)\r\n").supportsKeepAlive
    }
    XCTAssertTrue(try wants("HTTP/1.1"))
    XCTAssertFalse(try wants("HTTP/1.1", "Connection: close\r\n"))
    XCTAssertFalse(try wants("HTTP/1.1", "Connection: Close\r\n"))
    XCTAssertFalse(try wants("HTTP/1.1", "Connection: TE, close\r\n"))
    XCTAssertTrue(try wants("HTTP/1.1", "Connection: keep-alive\r\n"))
    XCTAssertFalse(try wants("HTTP/1.0"))
    XCTAssertTrue(try wants("HTTP/1.0", "Connection: keep-alive\r\n"))
    XCTAssertTrue(try wants("HTTP/1.0", "Connection: Keep-Alive\r\n"))
    XCTAssertFalse(try wants("HTTP/1.0", "Connection: close\r\n"))
    XCTAssertFalse(try wants("HTTP/1.0", "Connection: keep-alive, close\r\n"))
    XCTAssertTrue(try wants("HTTP/1.1", "Connection: upgrade\r\n"))
  }
}

// MARK: - Servers: persistent connections

final class PersistentConnectionTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      server.post["/echo"] = { request in .ok(.data(Data(request.body), contentType: "text/plain")) }
    }, body)
  }

  func testHTTP11ConnectionsAreKeptByDefaultAndNothingIsAnnounced() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        for round in 0..<3 {
          client.send(RawClient.requestText("GET", "/ping"))
          let response = client.readResponse()
          XCTAssertEqual(response?.status, 200, "\(threading), request \(round)")
          XCTAssertNil(response?.header("connection"), "\(threading): a persistent connection needs no header")
        }
      }
    }
  }

  func testAnExplicitKeepAliveIsConfirmed() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
        XCTAssertEqual(client.readResponse()?.header("connection")?.lowercased(), "keep-alive", "\(threading)")
        client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
        XCTAssertEqual(client.readResponse()?.status, 200, "\(threading)")
      }
    }
  }

  func testConnectionCloseIsAnnouncedAndDone() throws {
    for threading in bothModes {
      try serve(threading) { server, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: close"]))
        let response = client.readResponse()
        XCTAssertEqual(response?.header("connection")?.lowercased(), "close", "\(threading)")
        XCTAssertEqual(response?.bodyString, "pong")
        XCTAssertTrue(client.waitForClose(timeout: 2), "\(threading)")
        XCTAssertTrue(eventually { server.openConnections == 0 })
      }
    }
  }

  func testHTTP10ConnectionsAreClosedByDefault() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/ping", version: "HTTP/1.0"))
        let response = client.readResponse()
        XCTAssertEqual(response?.status, 200, "\(threading)")
        XCTAssertEqual(response?.header("connection")?.lowercased(), "close", "\(threading)")
        XCTAssertTrue(client.waitForClose(timeout: 2), "\(threading)")
      }
    }
  }

  func testHTTP10ConnectionsCanBeKept() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        for round in 0..<3 {
          client.send(RawClient.requestText("GET", "/ping", version: "HTTP/1.0", headers: ["Connection: keep-alive"]))
          let response = client.readResponse()
          XCTAssertEqual(response?.status, 200, "\(threading), request \(round)")
          XCTAssertEqual(response?.header("connection")?.lowercased(), "keep-alive", "\(threading)")
          XCTAssertNotNil(response?.header("content-length"), "an HTTP/1.0 client needs the length to keep the connection")
        }
      }
    }
  }

  func testTheServerAnnouncesTheClosingOfAConnectionThatCannotBeKept() throws {
    try withTestServer(configure: { server in
      // The length of this body is not known, and an HTTP/1.0 client cannot read chunks.
      server["/stream"] = { _ in .custom(200) { writer in try writer.write(Array("abc".utf8)) } }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/stream", version: "HTTP/1.0", headers: ["Connection: keep-alive"]))
      let response = client.readResponse()
      XCTAssertEqual(response?.header("connection")?.lowercased(), "close")
      XCTAssertNil(response?.header("content-length"))
      XCTAssertNil(response?.header("transfer-encoding"))
      XCTAssertEqual(response?.bodyString, "abc")
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testAServerThatStopsClosesItsConnectionsAndSaysSo() throws {
    let server = NanoHTTPServer()
    server.get["/slow"] = { _ in usleep(200_000); return .ok(.text("done")) }
    try server.start(0)
    let client = try RawClient(port: try server.port())
    client.send(RawClient.requestText("GET", "/slow"))
    usleep(50_000)
    server.stop()
    // The response may or may not be written; if it is, it does not promise a persistent connection.
    if let response = client.readResponse() {
      XCTAssertEqual(response.header("connection")?.lowercased(), "close")
    }
    XCTAssertTrue(client.waitForClose(timeout: 2))
  }

  func testTheStatusesOfRequestsThatAreRefusedAreFollowedByClose() throws {
    let cases: [(String, Int)] = [("GET / HTTP/2.0\r\nHost: x\r\n\r\n", 505),
                                  ("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\nx", 501),
                                  ("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n3\r\nabc\r\n0\r\n\r\n", 400),
                                  ("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", 400),
                                  ("POST / HTTP/1.1\r\nExpect: something-else\r\nContent-Length: 3\r\n\r\nabc", 417)]
    for threading in bothModes {
      try serve(threading) { _, port in
        for (request, status) in cases {
          let client = try RawClient(port: port)
          client.send(request)
          let response = client.readResponse()
          XCTAssertEqual(response?.status, status, "\(threading): \(request)")
          XCTAssertEqual(response?.header("connection")?.lowercased(), "close", "\(threading): \(request)")
          XCTAssertTrue(client.waitForClose(timeout: 2), "\(threading): \(request)")
        }
      }
    }
  }
}

// MARK: - Servers: bodies of requests

final class RequestBodyTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.post["/echo"] = { request in
        .ok(.text("\(request.bodyString ?? "<not text>")|\(request.header("content-length") ?? "-")|\(request.header("transfer-encoding") ?? "-")"))
      }
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }, body)
  }

  func testAChunkedBodyReachesTheHandler() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
        XCTAssertEqual(client.readResponse()?.bodyString, "hello world|11|-", "\(threading)")
      }
    }
  }

  func testAChunkedBodyThatArrivesInPiecesIsPutTogether() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
        for piece in ["3\r\nab", "c\r\n", "2\r\nde\r", "\n0\r\n", "\r\n"] {
          usleep(30_000)
          client.send(piece)
        }
        XCTAssertEqual(client.readResponse()?.bodyString, "abcde|5|-", "\(threading)")
      }
    }
  }

  func testRequestsAfterAChunkedBodyAreAnswered() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n" +
                    "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertEqual(client.readResponse()?.bodyString, "hi|2|-", "\(threading)")
        XCTAssertEqual(client.readResponse()?.bodyString, "pong", "\(threading)")
      }
    }
  }

  func testAClientThatWaitsForContinueGetsIt() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
        let interim = client.readResponse()
        XCTAssertEqual(interim?.status, 100, "\(threading): the server has to say that the body is welcome")
        XCTAssertEqual(interim?.statusLine, "HTTP/1.1 100 Continue")
        client.send("hello")
        let response = client.readResponse()
        XCTAssertEqual(response?.status, 200, "\(threading)")
        XCTAssertEqual(response?.bodyString, "hello|5|-", "\(threading)")
      }
    }
  }

  func testContinueIsAlsoSentForAChunkedBody() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n")
        XCTAssertEqual(client.readResponse()?.status, 100, "\(threading)")
        client.send("3\r\nabc\r\n0\r\n\r\n")
        XCTAssertEqual(client.readResponse()?.bodyString, "abc|3|-", "\(threading)")
      }
    }
  }

  func testAClientThatSendsTheBodyAnywayIsServed() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\nhello")
        XCTAssertEqual(client.readResponse()?.status, 100, "\(threading)")
        XCTAssertEqual(client.readResponse()?.bodyString, "hello|5|-", "\(threading)")
      }
    }
  }

  func testNoContinueIsSentWithoutABody() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send("GET /ping HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n")
        let response = client.readResponse()
        XCTAssertEqual(response?.status, 200, "\(threading): no 100 for a request that has nothing to wait for")
        XCTAssertEqual(response?.bodyString, "pong")
      }
    }
  }

  func testABodyThatIsTooLargeIsRefusedInsteadOfContinued() throws {
    for threading in bothModes {
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.limits.maxBodyBytes = 10
        server.post["/echo"] = { _ in .ok(.text("never")) }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\nExpect: 100-continue\r\n\r\n")
        XCTAssertEqual(client.readResponse()?.status, 413, "\(threading): the client must not be told to go on")
      }
    }
  }

  func testContinueIsNotSentToAnHTTP10Client() throws {
    try serve(.perConnection) { _, port in
      let client = try RawClient(port: port)
      client.send("POST /echo HTTP/1.0\r\nHost: x\r\nContent-Length: 2\r\nExpect: 100-continue\r\n\r\nhi")
      let response = client.readResponse()
      XCTAssertEqual(response?.status, 200, "HTTP/1.0 has no interim responses")
    }
  }
}

// MARK: - Servers: bodies of responses

final class StreamingResponseTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading,
                     configure: (NanoHTTPServer) -> Void = { _ in },
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      configure(server)
    }, body)
  }

  func testABodyWithoutALengthIsSentInChunksAndTheConnectionStaysOpen() throws {
    for threading in bothModes {
      try serve(threading, configure: { server in
        server["/stream"] = { _ in .custom(200, contentType: "text/plain") { writer in
          for index in 0..<4 { try writer.write(Array("[\(index)]".utf8)) }
        } }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/stream"))
        let response = client.readResponse()
        XCTAssertEqual(response?.header("transfer-encoding")?.lowercased(), "chunked", "\(threading)")
        XCTAssertNil(response?.header("content-length"))
        XCTAssertNil(response?.header("connection"), "the connection is not going to be closed")
        XCTAssertEqual(response?.bodyString, "[0][1][2][3]", "\(threading)")
        client.send(RawClient.requestText("GET", "/ping"))
        XCTAssertEqual(client.readResponse()?.bodyString, "pong", "\(threading): the connection is still in step")
      }
    }
  }

  func testEveryWriteIsAChunkAndTheEmptyOnesAreLeftOut() throws {
    try serve(.perConnection, configure: { server in
      server["/stream"] = { _ in .custom(200) { writer in
        try writer.write(Array("one".utf8))
        try writer.write(Array<UInt8>())
        try writer.write(Data("two".utf8))
        try writer.write(ArraySlice(Array("three".utf8)))
      } }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/stream"))
      _ = client.readResponse(head: true)
      XCTAssertEqual(client.readChunk(), Array("one".utf8))
      XCTAssertEqual(client.readChunk(), Array("two".utf8))
      XCTAssertEqual(client.readChunk(), Array("three".utf8))
      XCTAssertNil(client.readChunk(), "the last chunk")
    }
  }

  func testAChunkArrivesWhileTheHandlerIsStillWriting() throws {
    for threading in bothModes {
      let release = DispatchSemaphore(value: 0)
      try serve(threading, configure: { server in
        server["/events"] = { _ in .custom(200, contentType: "text/event-stream") { writer in
          try writer.write(Array("data: first\n\n".utf8))
          _ = release.wait(timeout: .now() + 5) // the client has received the first event meanwhile
          try writer.write(Array("data: second\n\n".utf8))
        } }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/events"))
        let head = client.readResponse(head: true)
        XCTAssertEqual(head?.header("content-type"), "text/event-stream")
        XCTAssertEqual(client.readChunk(), Array("data: first\n\n".utf8), "\(threading): not buffered until the end")
        release.signal()
        XCTAssertEqual(client.readChunk(), Array("data: second\n\n".utf8), "\(threading)")
        XCTAssertNil(client.readChunk())
      }
    }
  }

  func testALargeWriteIsOneChunkOfItsOwn() throws {
    try serve(.perConnection, configure: { server in
      server["/big"] = { _ in .custom(200) { writer in try writer.write([UInt8](repeating: 0x61, count: 100_000)) } }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/big"))
      _ = client.readResponse(head: true)
      XCTAssertEqual(client.readChunk()?.count, 100_000)
      XCTAssertNil(client.readChunk())
    }
  }

  func testAFileInAChunkedBodyIsSent() throws {
    let path = NSTemporaryDirectory() + "nanohttp-stream-\(UUID().uuidString).txt"
    try "file content".write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try serve(.perConnection, configure: { server in
      server["/file"] = { _ in .custom(200) { writer in
        try writer.write(Array("before ".utf8))
        try writer.write(try path.openForReading())
        try writer.write(Array(" after".utf8))
      } }
    }) { _, port in
      let response = try RawClient.get("/file", port: port, headers: [])
      XCTAssertEqual(response.bodyString, "before file content after")
    }
  }

  func testAHandlerThatFailsInTheMiddleOfAChunkedBodyEndsTheConnectionWithoutAFinalChunk() throws {
    struct Failure: Error {}
    for threading in bothModes {
      try serve(threading, configure: { server in
        server["/fail"] = { _ in .custom(200) { writer in
          try writer.write(Array("partial".utf8))
          throw Failure()
        } }
      }) { server, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/fail"))
        _ = client.readResponse(head: true)
        XCTAssertEqual(client.readChunk(), Array("partial".utf8))
        XCTAssertNil(client.readChunk(), "no final chunk: the client must see that the body is not complete")
        XCTAssertTrue(client.waitForClose(timeout: 2), "\(threading)")
        XCTAssertTrue(eventually { server.openConnections == 0 })
      }
    }
  }

  // MARK: A length that the handler declares

  func testABodyWithADeclaredLengthKeepsTheConnectionAndIsNotChunked() throws {
    for threading in bothModes {
      try serve(threading, configure: { server in
        server["/declared"] = { _ in .custom(200, headers: ["Content-Length": "6"]) { writer in
          try writer.write(Array("abc".utf8))
          try writer.write(Array("def".utf8))
        } }
      }) { _, port in
        let client = try RawClient(port: port)
        for round in 0..<2 {
          client.send(RawClient.requestText("GET", "/declared"))
          let response = client.readResponse()
          XCTAssertEqual(response?.header("content-length"), "6", "\(threading)")
          XCTAssertNil(response?.header("transfer-encoding"))
          XCTAssertEqual(response?.bodyString, "abcdef", "\(threading), request \(round)")
        }
      }
    }
  }

  func testABodyThatIsShorterThanDeclaredEndsTheConnection() throws {
    for threading in bothModes {
      try serve(threading, configure: { server in
        server["/short"] = { _ in .custom(200, headers: ["Content-Length": "10"]) { writer in
          try writer.write(Array("abc".utf8))
        } }
      }) { server, port in
        let client = try RawClient(port: port, timeout: 2)
        client.send(RawClient.requestText("GET", "/short"))
        // The client must not wait for ever for bytes that do not come: the connection ends, and the response is cut off.
        XCTAssertEqual(client.readResponse()?.bodyString, "abc", "\(threading)")
        XCTAssertTrue(client.reachedEOF, "\(threading)")
        XCTAssertTrue(eventually { server.openConnections == 0 })
      }
    }
  }

  func testABodyThatIsLongerThanDeclaredIsCutAndEndsTheConnection() throws {
    for threading in bothModes {
      try serve(threading, configure: { server in
        server["/long"] = { _ in .custom(200, headers: ["Content-Length": "3"]) { writer in
          try writer.write(Array("abcdef".utf8))
          try writer.write(Array("ghi".utf8))
        } }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/long"))
        let response = client.readResponse()
        XCTAssertEqual(response?.bodyString, "abc", "\(threading): not a byte more than the declared length")
        XCTAssertTrue(client.waitForClose(timeout: 2), "\(threading): the connection cannot be trusted any more")
      }
    }
  }

  func testAFileWithADeclaredLengthKeepsTheConnection() throws {
    let path = NSTemporaryDirectory() + "nanohttp-declared-\(UUID().uuidString).txt"
    try "0123456789".write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    for threading in bothModes {
      try serve(threading, configure: { server in
        server["/file"] = { _ in .custom(200, headers: ["Content-Length": "10"]) { writer in
          try writer.write(try path.openForReading())
        } }
      }) { _, port in
        let client = try RawClient(port: port)
        for _ in 0..<2 {
          client.send(RawClient.requestText("GET", "/file"))
          XCTAssertEqual(client.readResponse()?.bodyString, "0123456789", "\(threading)")
        }
      }
    }
  }
}
