//
//  TimeoutTests.swift
//  NanoHTTPTests
//
//  R3: a connection that does nothing must not hold a thread forever, and the number of connections
//  is bounded. The server has an idle timeout (nothing arrives while a request is expected), a read
//  timeout (a request stalls), a write timeout (the peer does not read) and `maxConnections`.
//

import XCTest
@testable import NanoHTTP

// MARK: - Idle and read timeouts

final class RequestTimeoutTests: XCTestCase {

  private func serve(idle: TimeInterval? = 30,
                     read: TimeInterval? = 30,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.idleTimeout = idle
      server.configuration.readTimeout = read
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      server.get["/slow"] = { _ in
        usleep(800_000)
        return .ok(.text("slow"))
      }
      server.post["/echo"] = { request in .ok(.data(Data(request.body), contentType: "text/plain")) }
    }, body)
  }

  func testDefaults() {
    let configuration = NanoHTTPServer.Configuration()
    XCTAssertEqual(configuration.idleTimeout, 60)
    XCTAssertEqual(configuration.readTimeout, 30)
    XCTAssertEqual(configuration.writeTimeout, 30)
    XCTAssertEqual(configuration.maxConnections, 128)
  }

  func testSilentConnectionIsClosedAfterTheIdleTimeout() throws {
    try serve(idle: 0.4) { server, port in
      let client = try RawClient(port: port)
      XCTAssertTrue(client.waitForClose(timeout: 3), "a silent connection was never closed")
      XCTAssertTrue(eventually { server.openConnections == 0 }, "the server still holds the connection")
    }
  }

  func testNothingIsSentToAClientThatNeverAsked() throws {
    try serve(idle: 0.3) { _, port in
      let client = try RawClient(port: port)
      XCTAssertEqual(client.readToEnd(timeout: 2), [])
      XCTAssertTrue(client.reachedEOF)
    }
  }

  func testKeepAliveConnectionIsClosedAfterTheIdleTimeout() throws {
    try serve(idle: 0.4) { server, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.status, 200)
      XCTAssertTrue(client.waitForClose(timeout: 3), "an idle keep-alive connection was never closed")
      XCTAssertTrue(eventually { server.openConnections == 0 })
    }
  }

  func testBusyKeepAliveConnectionIsNotClosed() throws {
    try serve(idle: 0.6) { _, port in
      let client = try RawClient(port: port)
      for round in 0..<6 {
        client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
        XCTAssertEqual(client.readResponse()?.status, 200, "request \(round)")
        usleep(250_000) // shorter than the idle timeout, but 1.5 s together
      }
    }
  }

  func testStalledRequestHeadGets408() throws {
    try serve(read: 0.4) { server, port in
      let client = try RawClient(port: port)
      client.send("GET /ping HTTP/1.1\r\nHost: localhost\r\n")  // the blank line never comes
      let response = client.readResponse()
      XCTAssertEqual(response?.status, 408)
      XCTAssertEqual(response?.header("connection"), "close")
      XCTAssertTrue(client.waitForClose(timeout: 2))
      XCTAssertTrue(eventually { server.openConnections == 0 })
    }
  }

  func testStalledRequestBodyGets408() throws {
    try serve(read: 0.4) { _, port in
      let client = try RawClient(port: port)
      client.send("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nabc")
      XCTAssertEqual(client.readResponse()?.status, 408)
    }
  }

  func testTheFirstByteOfARequestSwitchesToTheReadTimeout() throws {
    // A long idle timeout does not let a request that has begun stall for that long.
    try serve(idle: 30, read: 0.4) { _, port in
      let client = try RawClient(port: port)
      client.send("G")
      let begin = Date()
      XCTAssertEqual(client.readResponse()?.status, 408)
      XCTAssertLessThan(Date().timeIntervalSince(begin), 3)
    }
  }

  func testASlowRequestThatKeepsArrivingIsNotCutOff() throws {
    // The read timeout limits the pause between parts of a request, not its total duration.
    try serve(read: 0.6) { _, port in
      let client = try RawClient(port: port)
      for part in ["GET /p", "ing HT", "TP/1.1\r\n", "Host: x\r\n", "Connection: close\r\n", "\r\n"] {
        client.send(part)
        usleep(250_000) // 1.5 s in total
      }
      XCTAssertEqual(client.readResponse()?.status, 200)
    }
  }

  func testTimeoutsDoNotApplyWhileAHandlerRuns() throws {
    try serve(idle: 0.3, read: 0.3) { _, port in
      let response = try RawClient.get("/slow", port: port, timeout: 5)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.bodyString, "slow")
    }
  }

  func testNilTimeoutsWaitForever() throws {
    try serve(idle: nil, read: nil) { _, port in
      let client = try RawClient(port: port)
      XCTAssertFalse(client.waitForClose(timeout: 1.2), "closed although there is no timeout")
    }
  }

  func testZeroTimeoutsMeanNoTimeout() throws {
    try serve(idle: 0, read: 0) { _, port in
      let client = try RawClient(port: port)
      XCTAssertFalse(client.waitForClose(timeout: 1.2), "closed although there is no timeout")
    }
  }

  func testAnIdleClientDoesNotStopAnotherFromBeingServed() throws {
    try serve(idle: 30) { _, port in
      let idle = try RawClient(port: port)
      defer { idle.close() }
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
    }
  }
}

// MARK: - Write timeout

final class WriteTimeoutTests: XCTestCase {

  func testAPeerThatDoesNotReadIsDroppedAfterTheWriteTimeout() throws {
    let big = [UInt8](repeating: 0x61, count: 32 * 1024 * 1024)
    try withTestServer(configure: { server in
      server.configuration.writeTimeout = 0.5
      server.get["/big"] = { _ in .ok(.data(Data(big), contentType: "application/octet-stream")) }
    }) { server, port in
      let client = try RawClient(port: port, receiveBuffer: 4096)
      client.send(RawClient.requestText("GET", "/big", headers: ["Connection: close"]))
      XCTAssertTrue(eventually { server.openConnections == 1 })
      // The client takes nothing: after a while the send buffers are full and the server gives up.
      XCTAssertTrue(eventually(timeout: 8) { server.openConnections == 0 },
                    "the connection of a peer that does not read is still open")
      client.close()
    }
  }

  func testASlowButReadingPeerIsServedCompletely() throws {
    let body = [UInt8](repeating: 0x62, count: 4 * 1024 * 1024)
    try withTestServer(configure: { server in
      server.configuration.writeTimeout = 0.5
      server.get["/body"] = { _ in .ok(.data(Data(body), contentType: "application/octet-stream")) }
    }) { _, port in
      let client = try RawClient(port: port, timeout: 10, receiveBuffer: 16 * 1024)
      client.send(RawClient.requestText("GET", "/body", headers: ["Connection: close"]))
      usleep(300_000) // stalls for less than the write timeout, then reads
      XCTAssertEqual(client.readResponse()?.body.count, body.count)
    }
  }
}

// MARK: - Number of connections

final class ConnectionLimitTests: XCTestCase {

  private func serve(max: Int?, idle: TimeInterval? = 30,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.maxConnections = max
      server.configuration.idleTimeout = idle
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }, body)
  }

  func testConnectionsBeyondTheLimitGet503() throws {
    try serve(max: 3) { server, port in
      let held = try (0..<3).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 3 })
      let response = try RawClient.get("/ping", port: port)
      XCTAssertEqual(response.status, 503)
      XCTAssertEqual(response.header("connection"), "close")
      XCTAssertNotNil(response.header("retry-after"))
      // The connections inside the limit are not affected.
      held[0].send(RawClient.requestText("GET", "/ping", headers: ["Connection: close"]))
      XCTAssertEqual(held[0].readResponse()?.status, 200)
      XCTAssertTrue(eventually { server.openConnections == 2 })
    }
  }

  func testARefusedClientThatSendsNothingStillGets503() throws {
    try serve(max: 1) { server, port in
      let held = try RawClient(port: port)
      defer { held.close() }
      XCTAssertTrue(eventually { server.openConnections == 1 })
      let client = try RawClient(port: port)
      XCTAssertEqual(client.readResponse()?.status, 503)
    }
  }

  func testASlotIsFreeAgainWhenAConnectionCloses() throws {
    try serve(max: 2) { server, port in
      let first = try RawClient(port: port)
      let second = try RawClient(port: port)
      XCTAssertTrue(eventually { server.openConnections == 2 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 503)
      first.close()
      XCTAssertTrue(eventually { server.openConnections == 1 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      second.close()
    }
  }

  func testIdleConnectionsAreDroppedAndFreeTheirSlots() throws {
    try serve(max: 2, idle: 0.4) { server, port in
      let held = try (0..<2).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 2 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 503)
      XCTAssertTrue(eventually { server.openConnections == 0 }, "idle connections were not dropped")
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      held.forEach { $0.close() }
    }
  }

  func testRefusedConnectionsDoNotLeakDescriptorsOrConnections() throws {
    try serve(max: 1) { server, port in
      let held = try RawClient(port: port)
      defer { held.close() }
      XCTAssertTrue(eventually { server.openConnections == 1 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 503) // warm up
      let before = openFileDescriptorCount()
      for _ in 0..<30 {
        XCTAssertEqual(try RawClient.get("/ping", port: port).status, 503)
      }
      XCTAssertTrue(eventually { openFileDescriptorCount() - before < 5 },
                    "refused connections leak descriptors")
      XCTAssertEqual(server.openConnections, 1)
    }
  }

  func testNilMeansNoLimit() throws {
    raiseFileDescriptorLimit()
    try serve(max: nil) { server, port in
      let held = try (0..<200).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 200 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      held.forEach { $0.close() }
    }
  }

  func testTheDefaultLimitAllowsManyIdleConnections() throws {
    raiseFileDescriptorLimit()
    try serve(max: NanoHTTPServer.Configuration().maxConnections) { server, port in
      let held = try (0..<100).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 100 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      held.forEach { $0.close() }
    }
  }
}
