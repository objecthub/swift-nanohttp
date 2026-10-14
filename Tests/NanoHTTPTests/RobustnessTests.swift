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

// MARK: - R1: accept loop must survive transient accept() errors (fixed)

final class AcceptLoopTests: XCTestCase {

  /// Exhausts the process' file descriptors while connections arrive, so `accept()` fails with
  /// EMFILE, then restores the limit. One shortage must not take the server down: it keeps
  /// operating and serves new connections afterwards. (Connections that arrive during the shortage
  /// may be lost: macOS discards a pending connection whose `accept` failed.)
  func testServerSurvivesDescriptorExhaustion() throws {
    raiseFileDescriptorLimit()
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { server, port in
      // Reserve four client sockets, then leave exactly one descriptor free: the server can
      // accept one connection, the following accept() calls fail with EMFILE.
      let clients = try (0..<4).map { _ in try RawClient(port: port, connect: false) }
      let restore = exhaustFileDescriptors(leaving: 1)
      for client in clients {
        try? client.connect(port: port)
        client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: close"]))
      }
      usleep(400_000) // the accept loop runs into EMFILE and backs off
      restore()
      clients.forEach { $0.close() }
      usleep(100_000)
      XCTAssertTrue(server.operating, "server stopped itself after an accept() failure")
      for round in 0..<5 {
        XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200, "request \(round) after the shortage")
      }
    }
  }

  func testAcceptClassifiesDescriptorExhaustionAsTemporary() throws {
    raiseFileDescriptorLimit()
    let listener = try NanoSocket.tcpSocketForListen(0, .loopback, backlog: 8)
    let port = Int(try listener.port())
    let client = try RawClient(port: port)
    defer { client.close() }
    usleep(100_000) // the connection is complete and waits in the queue
    let restore = exhaustFileDescriptors(leaving: 0)
    var exhausted = false
    if case .exhausted = listener.acceptOutcome() {
      exhausted = true
    }
    restore()
    XCTAssertTrue(exhausted, "EMFILE must be reported as a shortage, not as a failure of the socket")
  }

  func testAcceptReportsAUnusableSocketAsFailed() {
    var closed = false
    if case .failed = NanoSocket(socketFileDescriptor: -1).acceptOutcome() {
      closed = true
    }
    XCTAssertTrue(closed)
    let notListening = NanoSocket(socketFileDescriptor: socket(AF_INET, SOCK_STREAM, 0))
    var unusable = false
    if case .failed = notListening.acceptOutcome() {
      unusable = true
    }
    XCTAssertTrue(unusable)
  }
}

// MARK: - R2: file descriptors must not leak (fixed)

final class DescriptorLeakTests: XCTestCase {
  var fixture: FileFixture!

  override func setUpWithError() throws {
    self.fixture = try FileFixture()
  }

  override func tearDown() {
    self.fixture?.remove()
    self.fixture = nil
  }

  /// A handler opens the file when it *builds* the response; the descriptor used to be closed only
  /// when the response was actually written. If the response is dropped (header write failed,
  /// server stopping, ...) the descriptor leaked because `NanoFile` had no `deinit`.
  func testShareFileDoesNotLeakWhenResponseIsNeverWritten() throws {
    let handler = NanoFiles.share(file: self.fixture.helloFile)
    let request = NanoHTTPRequest(method: "GET", path: "/")
    let before = openFileDescriptorCount()
    for _ in 0..<50 {
      _ = try handler(request)
    }
    XCTAssertLessThan(openFileDescriptorCount() - before, 5)
  }

  func testShareDirectoryAndBrowseDoNotLeakWhenResponseIsNeverWritten() {
    let request = NanoHTTPRequest(method: "GET", path: "/public/hello.txt")
    request.params = ["path": "hello.txt"]
    let handlers = [NanoFiles.share(directory: self.fixture.publicDir), NanoFiles.browse(directory: self.fixture.publicDir)]
    let before = openFileDescriptorCount()
    for _ in 0..<50 {
      for handler in handlers {
        XCTAssertEqual(try handler(request).statusCode, 200)
      }
    }
    XCTAssertLessThan(openFileDescriptorCount() - before, 5)
  }

  func testShareFileClosesDescriptorAfterWriting() {
    let handler = NanoFiles.share(file: self.fixture.helloFile)
    let request = NanoHTTPRequest(method: "GET", path: "/")
    let before = openFileDescriptorCount()
    for _ in 0..<50 {
      XCTAssertEqual(try handler(request).capturedBody(), "hello")
    }
    XCTAssertLessThan(openFileDescriptorCount() - before, 5)
  }

  func testAFileClosesItselfWhenItIsReleased() throws {
    let before = openFileDescriptorCount()
    for _ in 0..<50 {
      _ = try NanoFile(path: self.fixture.helloFile)
    }
    XCTAssertLessThan(openFileDescriptorCount() - before, 5)
  }

  func testClosingAFileTwiceIsHarmless() throws {
    let before = openFileDescriptorCount()
    do {
      let file = try NanoFile(path: self.fixture.helloFile)
      XCTAssertEqual(openFileDescriptorCount(), before + 1)
      file.close()
      XCTAssertEqual(openFileDescriptorCount(), before)
      file.close() // no effect; and the release at the end of the scope must not close it again
    }
    XCTAssertEqual(openFileDescriptorCount(), before)
  }
}

// MARK: - R3: idle connections must not starve the server

final class IdleConnectionTests: XCTestCase {

  /// Number of silent connections, fewer than the server accepts at the same time
  /// (`maxConnections`). Overridable (`NANOHTTP_IDLE_CONNECTIONS=64`) to probe other numbers.
  private var idleCount: Int {
    return ProcessInfo.processInfo.environment["NANOHTTP_IDLE_CONNECTIONS"].flatMap { Int($0) } ?? 100
  }

  /// Connections used to be served by threads of the GCD pool, which holds only about 64 blocked
  /// threads: once that many connections sat idle, no thread was left for new requests. Every
  /// connection has a thread of its own now.
  func testManyIdleConnectionsDoNotBlockNewRequests() throws {
    raiseFileDescriptorLimit()
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      let idle = try (0..<self.idleCount).map { _ in try RawClient(port: port) }
      usleep(500_000)
      let response = try? RawClient.get("/ping", port: port, timeout: 2)
      XCTAssertEqual(response?.status, 200, "a new request was starved by \(idle.count) idle connections")
    }
  }
}

// MARK: - R4: stop() must release the port; restart must work

final class LifecycleTests: XCTestCase {

  func testStopReleasesListeningSocket() throws {
    let server = NanoHTTPServer()
    try server.start(0)
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
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      try server.start(port)
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
      try server.start(0)
      XCTAssertEqual(try server.port(), port)
    }
  }
}

// MARK: - R4: closing a socket while other threads use it

final class SocketCloseTests: XCTestCase {

  private func socketPair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    NanoSocket.setNoSigPipe(fds[0])
    NanoSocket.setNoSigPipe(fds[1])
    return (fds[0], fds[1])
  }

  /// A closed socket whose descriptor number has been handed out again, plus the two ends of the
  /// unrelated socket pair that reuses it: `victim` has the old number, `peer` talks to it.
  private func closedSocketWithReusedDescriptor() throws -> (stale: NanoSocket, victim: Int32, peer: Int32, cleanup: () -> Void) {
    let (a0, a1) = socketPair()
    let stale = NanoSocket(socketFileDescriptor: a0)
    stale.close()
    let (b0, b1) = socketPair()
    guard b0 == a0 || b1 == a0 else {
      close(a1); close(b0); close(b1)
      throw XCTSkip("the descriptor number was not reused")
    }
    let (victim, peer) = b0 == a0 ? (b0, b1) : (b1, b0)
    _ = fcntl(peer, F_SETFL, O_NONBLOCK)
    _ = fcntl(victim, F_SETFL, O_NONBLOCK)
    return (stale, victim, peer, { close(a1); close(b0); close(b1) })
  }

  /// The descriptor number of a closed socket belongs to somebody else now. A late write used to
  /// go to that unrelated connection.
  func testWritingToAClosedSocketNeverReachesAnUnrelatedSocket() throws {
    let (stale, _, peer, cleanup) = try closedSocketWithReusedDescriptor()
    defer { cleanup() }
    XCTAssertThrowsError(try stale.writeUTF8("LEAK"))
    XCTAssertThrowsError(try stale.writeUInt8([UInt8]("LEAK".utf8)))
    XCTAssertThrowsError(try stale.writeData(Data("LEAK".utf8)))
    var buffer = [UInt8](repeating: 0, count: 16)
    XCTAssertEqual(read(peer, &buffer, buffer.count), -1, "data written to a closed socket arrived at another socket")
  }

  func testReadingFromAClosedSocketNeverConsumesDataOfAnUnrelatedSocket() throws {
    let (stale, victim, peer, cleanup) = try closedSocketWithReusedDescriptor()
    defer { cleanup() }
    XCTAssertEqual(write(peer, "DATA", 4), 4)
    XCTAssertThrowsError(try stale.read())
    XCTAssertThrowsError(try stale.read(length: 2))
    XCTAssertThrowsError(try stale.readLine())
    var buffer = [UInt8](repeating: 0, count: 8)
    XCTAssertEqual(read(victim, &buffer, buffer.count), 4, "a closed socket consumed the data of another socket")
  }

  func testAWebSocketSessionOfAClosedConnectionNeverWritesToAnUnrelatedSocket() throws {
    let (stale, _, peer, cleanup) = try closedSocketWithReusedDescriptor()
    defer { cleanup() }
    let session = NanoWebSocketSession(stale)
    session.writeText("broadcast to a client that is gone")
    var buffer = [UInt8](repeating: 0, count: 64)
    XCTAssertEqual(read(peer, &buffer, buffer.count), -1, "a stale session wrote into another connection")
  }

  func testSocketsAreComparedByIdentityNotByDescriptorNumber() throws {
    let first = open("/dev/null", O_RDONLY)
    let stale = NanoSocket(socketFileDescriptor: first)
    stale.close()
    let second = open("/dev/null", O_RDONLY)
    guard second == first else {
      close(second)
      throw XCTSkip("the descriptor number was not reused")
    }
    let current = NanoSocket(socketFileDescriptor: second)
    XCTAssertNotEqual(stale, current)
    var set: Set<NanoSocket> = [current]
    XCTAssertNil(set.remove(stale), "forgetting a stale socket must not forget the new socket with the same number")
    XCTAssertTrue(set.contains(current))
  }

  func testClosingWakesUpAThreadBlockedInRead() {
    let (a0, a1) = socketPair()
    defer { close(a1) }
    let socket = NanoSocket(socketFileDescriptor: a0)
    let returned = expectation(description: "blocked read returned")
    DispatchQueue.global().async {
      _ = try? socket.read()
      returned.fulfill()
    }
    usleep(200_000)
    socket.close()
    wait(for: [returned], timeout: 3)
  }

  func testClosingWakesUpAThreadBlockedInWrite() {
    let (a0, a1) = socketPair()
    defer { close(a1) } // nobody reads from this end, so the writer fills the buffer and blocks
    let socket = NanoSocket(socketFileDescriptor: a0)
    let returned = expectation(description: "blocked write returned")
    DispatchQueue.global().async {
      _ = try? socket.writeUInt8([UInt8](repeating: 0, count: 64 * 1024 * 1024))
      returned.fulfill()
    }
    usleep(200_000)
    socket.close()
    wait(for: [returned], timeout: 3)
  }

  func testCloseIsIdempotentAndSafeToCallConcurrently() {
    for _ in 0..<300 {
      let (a0, a1) = socketPair()
      let socket = NanoSocket(socketFileDescriptor: a0)
      DispatchQueue.concurrentPerform(iterations: 4) { _ in
        socket.close()
      }
      var byte: UInt8 = 0
      XCTAssertEqual(read(a0, &byte, 1), -1, "the descriptor must have been released")
      close(a1)
    }
  }

  func testOperationsRunningWhileTheSocketIsClosedEitherCompleteOrFail() {
    // Threads exchange data through a socket that is closed under their feet; none of them may
    // hang, crash or touch a descriptor that has been released.
    for _ in 0..<50 {
      let (a0, a1) = socketPair()
      let socket = NanoSocket(socketFileDescriptor: a0)
      let group = DispatchGroup()
      for _ in 0..<4 {
        group.enter()
        DispatchQueue.global().async {
          for _ in 0..<200 {
            if (try? socket.writeUTF8("x")) == nil { break }
          }
          group.leave()
        }
      }
      usleep(1_000)
      socket.close()
      XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
      close(a1)
    }
  }

  func testStoppingTheServerEndsBlockedConnectionsWithoutHangingOrCrashing() throws {
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { server, port in
      let clients = try (0..<20).map { _ in try RawClient(port: port) }
      for client in clients {
        client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
        XCTAssertEqual(client.readResponse()?.status, 200)
      }
      XCTAssertEqual(server.openConnections, 20)
      server.stop() // 20 connection threads are blocked in read() right now
      XCTAssertEqual(server.openConnections, 0)
      for client in clients {
        XCTAssertTrue(client.waitForClose(timeout: 2))
      }
    }
  }
}

// MARK: - R5: server state

final class ServerStateTests: XCTestCase {

  private func newServer() -> NanoHTTPServer {
    let server = NanoHTTPServer()
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    return server
  }

  func testStateFollowsTheLifecycle() throws {
    let server = newServer()
    XCTAssertEqual(server.state, .stopped)
    try server.start(0)
    XCTAssertEqual(server.state, .running)
    XCTAssertTrue(server.operating)
    server.stop()
    XCTAssertEqual(server.state, .stopped)
    XCTAssertFalse(server.operating)
  }

  /// A failed start used to leave the server in the state `starting` for good.
  func testFailedStartLeavesTheServerStopped() throws {
    let first = newServer()
    try first.start(0)
    defer { first.stop() }
    let second = newServer()
    defer { second.stop() }
    XCTAssertThrowsError(try second.start(UInt16(try first.port()))) // address in use
    XCTAssertEqual(second.state, .stopped)
    try second.start(0)
    XCTAssertEqual(second.state, .running)
    XCTAssertEqual(try RawClient.get("/ping", port: try second.port()).status, 200)
  }

  func testStartingARunningServerChangesNothing() throws {
    let server = newServer()
    try server.start(0)
    defer { server.stop() }
    let port = try server.port()
    try server.start(0)
    XCTAssertEqual(try server.port(), port)
    XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
  }

  func testConcurrentStopCallsStopOnce() throws {
    for _ in 0..<20 {
      let server = newServer()
      try server.start(0)
      let port = try server.port()
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.status, 200)
      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        server.stop()
      }
      XCTAssertEqual(server.state, .stopped)
      XCTAssertEqual(server.openConnections, 0)
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  /// Counts how often the accept loop is started.
  private final class CountingServer: NanoHTTPServer {
    private let countLock = NSLock()
    private var starts = 0
    var acceptLoops: Int {
      countLock.lock(); defer { countLock.unlock() }
      return starts
    }
    override func listen() {
      countLock.lock(); starts += 1; countLock.unlock()
      super.listen()
    }
  }

  func testConcurrentStartCallsStartOnce() throws {
    let server = CountingServer()
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    defer { server.stop() }
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      try? server.start(0)
    }
    XCTAssertEqual(server.state, .running)
    XCTAssertEqual(try RawClient.get("/ping", port: try server.port()).status, 200)
    usleep(200_000)
    XCTAssertEqual(server.acceptLoops, 1, "several of the concurrent start calls did the work")
  }

  /// The accept loop of a stopped server ends by itself; if the server has been started again in
  /// the meantime, that must not stop the new run.
  func testRestartingTheSameServerAlwaysGivesAWorkingServer() throws {
    let server = newServer()
    defer { server.stop() }
    for round in 0..<60 {
      try server.start(0)
      XCTAssertEqual(try RawClient.get("/ping", port: try server.port()).status, 200, "round \(round)")
      server.stop()
    }
  }

  /// Plays an accept loop of an earlier run that is late to notice that its run is over: it asks
  /// to stop "its" run after the server has been started again. That must not stop the new run.
  func testALateAcceptLoopOfAnEarlierRunCannotStopTheNewRun() throws {
    let server = newServer()
    defer { server.stop() }
    try server.start(0)
    let earlierRun = server.socket
    server.stop()
    try server.start(0)
    XCTAssertFalse(server.socket === earlierRun)
    server.shutDown(run: earlierRun)
    XCTAssertEqual(server.state, .running)
    XCTAssertEqual(try RawClient.get("/ping", port: try server.port()).status, 200)
    server.shutDown(run: server.socket) // the current run, on the other hand, is stopped
    XCTAssertEqual(server.state, .stopped)
  }

  func testStoppingFromAnotherThreadWhileRequestsAreServed() throws {
    let server = newServer()
    try server.start(0)
    let port = try server.port()
    let group = DispatchGroup()
    for _ in 0..<4 {
      group.enter()
      DispatchQueue.global().async {
        for _ in 0..<50 { _ = try? RawClient.get("/ping", port: port, timeout: 1) }
        group.leave()
      }
    }
    usleep(50_000)
    server.stop()
    XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
    XCTAssertEqual(server.state, .stopped)
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

  func testEmptyBuffersOfEveryKindAreWrittenAsNothing() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    NanoSocket.setNoSigPipe(fds[0])
    defer { close(fds[1]) }
    let socket = NanoSocket(socketFileDescriptor: fds[0])
    try socket.writeUInt8([])
    try socket.writeUInt8(ArraySlice<UInt8>())
    try socket.writeUInt8(Array([1, 2, 3])[1..<1])        // an empty slice of an array that has bytes
    try socket.writeUInt8(Array([1, 2, 3])[3...])
    try socket.writeUTF8("")
    try socket.writeData(Data())
    try socket.writeData(NSData())
    try socket.writeUInt8([7])                            // what arrives first is this, so nothing was written before
    var received = [UInt8](repeating: 0, count: 1)
    XCTAssertEqual(read(fds[1], &received, 1), 1)
    XCTAssertEqual(received, [7])
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
      let session = NanoWebSocketSession(NanoSocket(socketFileDescriptor: fds[0]))
      session.writeCloseFrame() // empty payload
      var received = [UInt8](repeating: 0, count: 2)
      XCTAssertEqual(read(fds[1], &received, 2), 2)
      XCTAssertEqual(received, [0x88, 0x00])
    }
  }
}

// MARK: - R7: NanoNetworkInterface (fixed)

final class NetworkInterfaceTests: XCTestCase {

  // MARK: Against the operating system

  /// Independent reference: the addresses of all running, non-loopback interfaces via getifaddrs +
  /// inet_ntop on the real `sockaddr_in`/`sockaddr_in6`.
  private func reference(ipv4: Bool) -> Set<String> {
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
         flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK) == (IFF_UP | IFF_RUNNING) {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ipv4 && address.pointee.sa_family == UInt8(AF_INET) {
          address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            var addr = pointer.pointee.sin_addr
            if inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil {
              result.insert(String(cString: buffer))
            }
          }
        } else if !ipv4 && address.pointee.sa_family == UInt8(AF_INET6) {
          address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            var addr = pointer.pointee.sin6_addr
            if inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil {
              result.insert(String(cString: buffer))
            }
          }
        }
      }
      cursor = entry.pointee.ifa_next
    }
    return result
  }

  /// `255.255.255.0` and `ffff:ffff:ffff:ffff::` are masks: ones, then zeros.
  private func isContiguousMask(_ text: String, ipv4: Bool) -> Bool {
    var bytes = [UInt8](repeating: 0, count: 16)
    let parsed = ipv4 ? inet_pton(AF_INET, text, &bytes) : inet_pton(AF_INET6, text, &bytes)
    guard parsed == 1 else { return false }
    let bits = bytes.prefix(ipv4 ? 4 : 16).map { String($0, radix: 2).leftPadded(to: 8) }.joined()
    return !bits.contains("01")
  }

  func testIPv4AddressesMatchTheOperatingSystem() {
    let reported = Set(NanoNetworkInterface.available().filter { $0.ipv4 }.map { $0.ip })
    XCTAssertEqual(reported, reference(ipv4: true))
  }

  func testIPv6AddressesMatchTheOperatingSystem() throws {
    let expected = reference(ipv4: false)
    try XCTSkipIf(expected.isEmpty, "no running non-loopback IPv6 interface on this machine")
    // Link-local addresses are reported with the zone of the interface: fe80::1%en0.
    let reported = Set(NanoNetworkInterface.available().filter { !$0.ipv4 }.map {
      String($0.ip.split(separator: "%").first ?? "")
    })
    XCTAssertEqual(reported, expected)
  }

  func testAddressesAndNetmasksAreWellFormed() {
    for interface in NanoNetworkInterface.available() {
      var storage = [UInt8](repeating: 0, count: 16)
      let address = String(interface.ip.split(separator: "%").first ?? "")
      XCTAssertEqual(inet_pton(interface.ipv4 ? AF_INET : AF_INET6, address, &storage), 1, "\(interface)")
      XCTAssertTrue(self.isContiguousMask(interface.netmask, ipv4: interface.ipv4), "\(interface)")
    }
  }

  func testLocalIPIsOneOfTheInterfaceAddressesAndStable() {
    let first = NanoNetworkInterface.localIP
    for _ in 0..<50 {
      XCTAssertEqual(NanoNetworkInterface.localIP, first)
      XCTAssertEqual(NanoNetworkInterface.localIP(ipv4: true), NanoNetworkInterface.localIP(ipv4: true))
    }
    if let ip = first {
      XCTAssertTrue(NanoNetworkInterface.available().contains { $0.ip == ip })
    }
  }

  // MARK: Ranking

  private func interface(_ name: String, _ ip: String, ipv4: Bool = true) -> NanoNetworkInterface {
    return NanoNetworkInterface(name: name, ipv4: ipv4, ip: ip, netmask: "255.255.255.0")
  }

  func testPreferredInterface() {
    let utun = interface("utun3", "10.8.0.2"), bridge = interface("bridge100", "192.168.64.1")
    let en0 = interface("en0", "192.168.1.20"), en1 = interface("en1", "10.0.0.5"), en10 = interface("en10", "172.16.0.9")
    XCTAssertEqual(NanoNetworkInterface.preferred(among: [utun, bridge, en1, en0])?.name, "en0")
    XCTAssertEqual(NanoNetworkInterface.preferred(among: [utun, bridge, en1])?.name, "en1")
    XCTAssertEqual(NanoNetworkInterface.preferred(among: [en10, en1])?.name, "en1", "numeric, not alphabetical")
    XCTAssertEqual(NanoNetworkInterface.preferred(among: [utun, bridge])?.name, "bridge100", "otherwise by name")
    XCTAssertNil(NanoNetworkInterface.preferred(among: []))
  }

  func testLinkLocalAddressesComeLast() {
    let linkLocal4 = interface("en0", "169.254.12.7"), other = interface("utun1", "10.1.1.1")
    XCTAssertEqual(NanoNetworkInterface.preferred(among: [linkLocal4, other])?.ip, "10.1.1.1")
    XCTAssertEqual(NanoNetworkInterface.preferred(among: [linkLocal4])?.ip, "169.254.12.7", "better than nothing")
    let linkLocal6 = interface("en0", "fe80::1%en0", ipv4: false), global6 = interface("awdl0", "2001:db8::5", ipv4: false)
    XCTAssertEqual(NanoNetworkInterface.preferred(among: [linkLocal6, global6])?.ip, "2001:db8::5")
  }

  func testThePreferenceDoesNotDependOnTheOrderOfTheSet() {
    let all = [interface("en2", "10.0.2.1"), interface("en0", "10.0.0.1"), interface("lo9", "10.9.9.9"), interface("en1", "10.0.1.1")]
    for _ in 0..<20 {
      XCTAssertEqual(NanoNetworkInterface.preferred(among: Set(all.shuffled()))?.name, "en0")
    }
  }

  // MARK: Entries of getifaddrs, built by hand

  /// An `ifaddrs` entry with the given contents; frees what it allocated.
  private final class Entry {
    var entry = ifaddrs()
    private var allocations = [UnsafeMutableRawPointer]()

    init(name: String = "en7", flags: Int32 = IFF_UP | IFF_RUNNING, address: [UInt8]?, netmask: [UInt8]? = nil) {
      let nameCopy = strdup(name)!
      allocations.append(UnsafeMutableRawPointer(nameCopy))
      entry.ifa_name = nameCopy
      entry.ifa_flags = UInt32(flags)
      entry.ifa_addr = address.map(storage)
      entry.ifa_netmask = netmask.map(storage)
    }

    /// Copies raw `sockaddr` bytes (as the system lays them out) into allocated memory.
    private func storage(_ bytes: [UInt8]) -> UnsafeMutablePointer<sockaddr> {
      let memory = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, MemoryLayout<sockaddr_storage>.size), alignment: 8)
      memset(memory, 0, max(bytes.count, MemoryLayout<sockaddr_storage>.size))
      memcpy(memory, bytes, bytes.count)
      allocations.append(memory)
      return memory.assumingMemoryBound(to: sockaddr.self)
    }

    deinit { allocations.forEach { free($0) } } // malloc'ed (strdup) and allocate()d memory alike come from malloc
  }

  /// The bytes of a `sockaddr_in` for `a.b.c.d`; `length` is the `sa_len` the system stores.
  private func sockaddr4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8, length: UInt8 = 16) -> [UInt8] {
    return [length, UInt8(AF_INET), 0, 0, a, b, c, d] + [UInt8](repeating: 0, count: 8)
  }

  /// The bytes of a `sockaddr_in6`: len, family, port, flowinfo, 16 address bytes, scope id.
  private func sockaddr6(_ address: [UInt8], length: UInt8 = 28, scope: UInt32 = 0) -> [UInt8] {
    return [length, UInt8(AF_INET6), 0, 0, 0, 0, 0, 0] + address + withUnsafeBytes(of: scope) { Array($0) }
  }

  func testAnEntryWithoutAnAddressIsSkipped() {
    let entry = Entry(address: nil, netmask: nil)
    XCTAssertNil(NanoNetworkInterface.interface(from: entry.entry)) // used to dereference a null pointer
  }

  func testAnIPv6AddressIsReadInFull() {
    let address: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00, 0x06]
    let mask: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff] + [UInt8](repeating: 0, count: 8)
    let entry = Entry(address: sockaddr6(address), netmask: sockaddr6(mask))
    let interface = NanoNetworkInterface.interface(from: entry.entry)
    XCTAssertEqual(interface?.ip, "2001:db8:1:2:3:4:5:6") // the second half used to be garbage
    XCTAssertEqual(interface?.netmask, "ffff:ffff:ffff:ffff::")
    XCTAssertEqual(interface?.ipv4, false)
    XCTAssertEqual(interface?.name, "en7")
  }

  func testALinkLocalAddressCarriesItsZone() {
    var address = [UInt8](repeating: 0, count: 16)
    address[0] = 0xfe; address[1] = 0x80; address[15] = 1
    let entry = Entry(name: "lo99", address: sockaddr6(address, scope: 1)) // scope 1: the first interface, lo0
    XCTAssertEqual(NanoNetworkInterface.interface(from: entry.entry)?.ip, "fe80::1%lo0")
  }

  func testANetmaskWithTrailingZeroBytesCutOffIsRestored() {
    // The system stores 255.255.255.0 with sa_len 7 (the last byte is missing) and 0.0.0.0 with sa_len 0.
    let cases: [(UInt8, [UInt8], String)] = [(7, [255, 255, 255, 0], "255.255.255.0"),
                                              (6, [255, 255, 0, 0], "255.255.0.0"),
                                              (5, [255, 0, 0, 0], "255.0.0.0"),
                                              (16, [255, 255, 255, 255], "255.255.255.255"),
                                              (0, [0, 0, 0, 0], "0.0.0.0")]
    for (length, bytes, expected) in cases {
      let mask = sockaddr4(bytes[0], bytes[1], bytes[2], bytes[3], length: length)
      let cut = Array(mask.prefix(Int(length)))
      let entry = Entry(address: sockaddr4(192, 168, 1, 20), netmask: cut)
      let interface = NanoNetworkInterface.interface(from: entry.entry)
      XCTAssertEqual(interface?.ip, "192.168.1.20")
      XCTAssertEqual(interface?.netmask, expected, "sa_len \(length)")
    }
  }

  func testAnEntryWithoutANetmaskHasAnEmptyNetmask() {
    let entry = Entry(address: sockaddr4(10, 0, 0, 1), netmask: nil)
    let interface = NanoNetworkInterface.interface(from: entry.entry)
    XCTAssertEqual(interface?.ip, "10.0.0.1")
    XCTAssertEqual(interface?.netmask, "")
  }

  func testLoopbackInterfacesInterfacesThatAreDownAndOtherAddressFamiliesAreSkipped() {
    let loopback = Entry(flags: IFF_UP | IFF_RUNNING | IFF_LOOPBACK, address: sockaddr4(127, 0, 0, 1), netmask: sockaddr4(255, 0, 0, 0))
    XCTAssertNil(NanoNetworkInterface.interface(from: loopback.entry))
    let down = Entry(flags: IFF_UP, address: sockaddr4(10, 0, 0, 1), netmask: sockaddr4(255, 0, 0, 0))
    XCTAssertNil(NanoNetworkInterface.interface(from: down.entry))
    let linkLayer = Entry(address: [20, UInt8(AF_LINK), 0, 0, 6, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef, 0, 1, 0, 0, 0, 0, 0, 0])
    XCTAssertNil(NanoNetworkInterface.interface(from: linkLayer.entry))
  }
}

private extension String {
  func leftPadded(to length: Int) -> String {
    return String(repeating: "0", count: max(0, length - self.count)) + self
  }
}

// MARK: - R9: malformed requests get an answer (fixed)

final class MalformedRequestTests: XCTestCase {

  func testGarbageRequestLineGetsBadRequest() throws {
    try withTestServer { _, port in
      let client = try RawClient(port: port)
      client.send("garbage\r\n\r\n")
      let response = client.readResponse()
      XCTAssertEqual(response?.status, 400)
      XCTAssertEqual(response?.header("connection"), "close")
      XCTAssertTrue(client.waitForClose(timeout: 2))
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
