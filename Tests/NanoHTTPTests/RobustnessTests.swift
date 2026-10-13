//
//  RobustnessTests.swift
//  NanoHTTPTests
//
//  Regression tests for the robustness / concurrency findings R1–R9 of the assessment plan.
//  Tests wrapped in `expectKnownIssue` assert the CORRECT behavior and currently fail as
//  expected; see Support/KnownIssue.swift.
//

import XCTest
@testable import NanoHTTP

// MARK: - R1: accept loop must survive transient accept() errors

final class AcceptLoopTests: XCTestCase {

  /// Exhausts the process' file descriptors while connections are pending, so `accept()` fails
  /// with EMFILE, then restores the limit and checks that the server still serves requests.
  /// (One ephemeral error must not take the whole server down.)
  func testServerSurvivesDescriptorExhaustion() throws {
    raiseFileDescriptorLimit()
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { server, port in
      // Reserve four client sockets, then leave exactly one descriptor free: the server can
      // accept the first pending connection, the second accept() fails with EMFILE.
      let clients = try (0..<4).map { _ in try RawClient(port: port, connect: false) }
      let restore = exhaustFileDescriptors(leaving: 1)
      for client in clients {
        try? client.connect(port: port)
      }
      usleep(400_000)
      restore()
      clients.forEach { $0.close() }
      usleep(200_000)
      expectKnownIssue("R1", "any accept() error ends the accept loop and stops the whole server") {
        XCTAssertTrue(server.operating, "server stopped itself after an accept() failure")
        let response = try? RawClient.get("/ping", port: port)
        XCTAssertEqual(response?.status, 200)
      }
    }
  }
}

// MARK: - R2: file descriptors must not leak

final class DescriptorLeakTests: XCTestCase {
  var fixture: FileFixture!

  override func setUpWithError() throws {
    self.fixture = try FileFixture()
  }

  override func tearDown() {
    self.fixture?.remove()
    self.fixture = nil
  }

  /// A handler opens the file when it *builds* the response; the descriptor is only closed when
  /// the response is actually written. If the response is dropped (header write failed, server
  /// stopping, ...) the descriptor leaks because `String.File` has no `deinit`.
  func testShareFileDoesNotLeakWhenResponseIsNeverWritten() {
    let handler = share(file: self.fixture.helloFile)
    let request = NanoHTTPRequest(method: "GET", path: "/")
    let before = openFileDescriptorCount()
    for _ in 0..<50 {
      _ = handler(request)
    }
    let leaked = openFileDescriptorCount() - before
    expectKnownIssue("R2", "String.File has no deinit; unwritten responses leak their descriptor") {
      XCTAssertLessThan(leaked, 5, "leaked \(leaked) descriptors in 50 dropped responses")
    }
  }

  func testShareFileClosesDescriptorAfterWriting() {
    let handler = share(file: self.fixture.helloFile)
    let request = NanoHTTPRequest(method: "GET", path: "/")
    let before = openFileDescriptorCount()
    for _ in 0..<50 {
      XCTAssertEqual(handler(request).capturedBody(), "hello")
    }
    XCTAssertLessThan(openFileDescriptorCount() - before, 5)
  }
}

// MARK: - R3: idle connections must not starve the server

final class IdleConnectionTests: XCTestCase {

  /// Number of silent connections. Overridable (`NANOHTTP_IDLE_CONNECTIONS=64`) to probe the
  /// starvation threshold.
  private var idleCount: Int {
    return ProcessInfo.processInfo.environment["NANOHTTP_IDLE_CONNECTIONS"].flatMap { Int($0) } ?? 150
  }

  /// Every connection is served by a blocking thread from the GCD pool. Once enough connections
  /// sit idle (no timeouts exist), no thread is left for new requests.
  func testManyIdleConnectionsDoNotBlockNewRequests() throws {
    raiseFileDescriptorLimit()
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      let idle = try (0..<self.idleCount).map { _ in try RawClient(port: port) }
      usleep(500_000)
      let response = try? RawClient.get("/ping", port: port, timeout: 2)
      expectKnownIssue("R3", "no read timeout: idle connections pin threads and starve new requests") {
        XCTAssertEqual(response?.status, 200, "a new request was starved by \(idle.count) idle connections")
      }
    }
  }
}

// MARK: - R4: stop() must release the port; restart must work

final class LifecycleTests: XCTestCase {

  func testStopReleasesListeningSocket() throws {
    let server = NanoHTTPServer()
    server.listenAddressIPv4 = "127.0.0.1"
    try server.start(0, forceIPv4: true, priority: .userInitiated)
    let port = try server.port()
    usleep(200_000) // let the accept loop block in accept()
    server.stop()
    usleep(300_000)
    XCTAssertFalse(server.operating)
    XCTAssertThrowsError(try RawClient(port: port), "port \(port) still accepts connections after stop()")
  }

  func testRestartOnSamePortManyTimes() throws {
    var port: UInt16 = 0
    for round in 0..<25 {
      let server = NanoHTTPServer()
      server.listenAddressIPv4 = "127.0.0.1"
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      try server.start(port, forceIPv4: true, priority: .userInitiated)
      if port == 0 {
        port = UInt16(try server.port())
      }
      let response = try RawClient.get("/ping", port: Int(port))
      XCTAssertEqual(response.status, 200, "round \(round)")
      server.stop()
    }
  }

  func testStopClosesOpenKeepAliveConnections() throws {
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { server, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.status, 200)
      XCTAssertEqual(server.openConnections, 1)
      server.stop()
      XCTAssertTrue(client.waitForClose(timeout: 2), "connection survived server.stop()")
    }
  }

  func testStartTwiceIsHarmless() throws {
    try withTestServer { server, port in
      try server.start(0, forceIPv4: true)
      XCTAssertEqual(try server.port(), port)
    }
  }
}

// MARK: - R6: empty bodies

final class EmptyBodyTests: XCTestCase {

  func testEmptyTextBodyIsSentAsContentLengthZero() throws {
    try withTestServer(configure: { server in
      server.get["/empty-text"] = { _ in .ok(.text("")) }
      server.get["/empty"] = { _ in .ok(.empty) }
      server.get["/empty-data"] = { _ in .ok(.data(Data())) }
    }) { _, port in
      for path in ["/empty-text", "/empty", "/empty-data"] {
        let response = try RawClient.get(path, port: port)
        XCTAssertEqual(response.status, 200, path)
        XCTAssertEqual(response.header("content-length"), "0", path)
        XCTAssertEqual(response.body.count, 0, path)
      }
    }
  }

  func testEmptyWebSocketCloseFrameCanBeWritten() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    // Accepted sockets get SO_NOSIGPIPE from the server; a bare socketpair does not, and the
    // session writes a second close frame in deinit.
    NanoSocket.setNoSigPipe(fds[0])
    NanoSocket.setNoSigPipe(fds[1])
    defer { close(fds[1]) }
    do {
      let session = WebSocketSession(NanoSocket(socketFileDescriptor: fds[0]))
      session.writeCloseFrame() // empty payload
      var received = [UInt8](repeating: 0, count: 2)
      XCTAssertEqual(read(fds[1], &received, 2), 2)
      XCTAssertEqual(received, [0x88, 0x00])
    }
  }
}

// MARK: - R7: NetworkInterface

final class NetworkInterfaceTests: XCTestCase {

  /// Independent reference: IPv6 addresses of all running, non-loopback interfaces via
  /// getifaddrs + inet_ntop on the real `sockaddr_in6`.
  private func referenceIPv6Addresses() -> Set<String> {
    var result = Set<String>()
    var list: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&list) == 0 else {
      return result
    }
    defer { freeifaddrs(list) }
    var cursor = list
    while let entry = cursor {
      let flags = Int32(entry.pointee.ifa_flags)
      if let address = entry.pointee.ifa_addr,
         address.pointee.sa_family == UInt8(AF_INET6),
         flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK) == (IFF_UP | IFF_RUNNING) {
        address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
          var addr = pointer.pointee.sin6_addr
          var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
          if inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil {
            result.insert(String(cString: buffer))
          }
        }
      }
      cursor = entry.pointee.ifa_next
    }
    return result
  }

  func testIPv4AddressesAreWellFormed() {
    for interface in NetworkInterface.available() where interface.ipv4 {
      var address = in_addr()
      XCTAssertEqual(inet_pton(AF_INET, interface.ip, &address), 1, "\(interface)")
      XCTAssertEqual(inet_pton(AF_INET, interface.netmask, &address), 1, "\(interface)")
    }
  }

  func testIPv6AddressesMatchTheOperatingSystem() throws {
    let reference = self.referenceIPv6Addresses()
    try XCTSkipIf(reference.isEmpty, "no running non-loopback IPv6 interface on this machine")
    let reported = Set(NetworkInterface.available().filter { !$0.ipv4 }.map {
      String($0.ip.split(separator: "%").first ?? "")
    })
    expectKnownIssue("R7", "sockaddr_in6 is copied into a 16-byte sockaddr; the address is truncated") {
      XCTAssertEqual(reported, reference)
    }
  }

  func testLocalIPIsOneOfTheInterfaceAddresses() {
    if let ip = NetworkInterface.localIP {
      XCTAssertTrue(NetworkInterface.available().contains { $0.ip == ip })
    }
  }
}

// MARK: - R9: malformed requests get an answer

final class MalformedRequestTests: XCTestCase {

  func testGarbageRequestLineGetsBadRequest() throws {
    try withTestServer { _, port in
      let client = try RawClient(port: port)
      client.send("garbage\r\n\r\n")
      let response = client.readResponse()
      expectKnownIssue("R9", "the connection is closed silently; the client never gets a 400") {
        XCTAssertEqual(response?.status, 400)
      }
    }
  }

  func testGarbageRequestDoesNotKillTheServer() throws {
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send("garbage\r\n\r\n")
      _ = client.waitForClose(timeout: 1)
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
    }
  }
}
