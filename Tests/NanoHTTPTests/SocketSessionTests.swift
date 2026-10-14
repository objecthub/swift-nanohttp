//
//  SocketSessionTests.swift
//  NanoHTTPTests
//
//  A server with one thread serves WebSockets next to everything else: the server waits for all sessions
//  and connections together, and a session only has the thread while it handles one message. Sessions of
//  other protocols (`NanoSocketSession`) work the same way, with one thread and with threads per connection.
//

import XCTest
@testable import NanoHTTP

private final class Counter {
  private let lock = NSLock()
  private var value = 0
  func increment() {
    self.lock.lock()
    self.value += 1
    self.lock.unlock()
  }
  var count: Int {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.value
  }
}

private final class ThreadLog {
  private let lock = NSLock()
  private var ids = Set<UInt64>()
  func record() {
    let id = currentThreadID()
    self.lock.lock()
    self.ids.insert(id)
    self.lock.unlock()
  }
  var threads: Set<UInt64> {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.ids
  }
}

private func text(_ frame: (opcode: UInt8, fin: Bool, payload: [UInt8])?) -> String? {
  return frame.map { String(decoding: $0.payload, as: UTF8.self) }
}

// MARK: - WebSockets on a server with one thread

final class WebSocketOneThreadTests: XCTestCase {

  /// A chat: everything a client sends is sent to all clients. The list of the sessions is a plain
  /// variable, which is safe because every handler and every callback runs on the same thread; the thread
  /// sanitizer reports it if that is not so.
  private func serveChat(idle: TimeInterval? = 30,
                         read: TimeInterval? = 30,
                         max: Int? = 128,
                         _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    var sessions = [NanoWebSocketSession]()
    var connectedCount = 0
    var disconnectedCount = 0
    try withTestServer(configure: { server in
      server.configuration.threading = .singleThread
      server.configuration.idleTimeout = idle
      server.configuration.readTimeout = read
      server.configuration.maxConnections = max
      server["/ws"] = NanoWebSocket.handler(
        text: { _, message in sessions.forEach { $0.writeText(message) } },
        binary: { session, bytes in session.writeBinary(bytes) },
        connected: { session in sessions.append(session); connectedCount += 1 },
        disconnected: { session in sessions.removeAll { $0 === session }; disconnectedCount += 1 })
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      server.get["/stats"] = { _ in .ok(.text("\(sessions.count) \(connectedCount) \(disconnectedCount)")) }
      server.post["/notify"] = { request in
        let message = String(decoding: request.body, as: UTF8.self)
        sessions.forEach { $0.writeText(message) }
        return .ok(.text("\(sessions.count)"))
      }
    }, body)
  }

  private func stats(_ port: Int) throws -> (open: Int, connected: Int, disconnected: Int) {
    let parts = try RawClient.get("/stats", port: port).bodyString.split(separator: " ").compactMap { Int($0) }
    return (parts[0], parts[1], parts[2])
  }

  func testRequestsAreServedWhileAWebSocketIsOpen() throws {
    try serveChat { _, port in
      let client = try WS.connect(port: port)
      defer { client.close() }
      let begin = Date()
      XCTAssertEqual(try RawClient.get("/ping", port: port, timeout: 2).status, 200)
      XCTAssertLessThan(Date().timeIntervalSince(begin), 1)
      client.send(WS.text("still here"))
      XCTAssertEqual(text(WS.readFrame(client)), "still here")
    }
  }

  func testManyWebSocketsAndOtherConnectionsAreServedTogether() throws {
    try serveChat { server, port in
      let clients = try (0..<5).map { _ in try WS.connect(port: port) }
      let silent = try RawClient(port: port)
      let keepAlive = try RawClient(port: port)
      defer { silent.close() }
      for round in 0..<3 {
        keepAlive.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
        XCTAssertEqual(keepAlive.readResponse()?.bodyString, "pong", "round \(round)")
        // Every client sends a message, and every message of the chat goes to all clients.
        clients.forEach { $0.send(WS.text("m\(round)")) }
        for client in clients {
          for _ in clients {
            XCTAssertEqual(text(WS.readFrame(client)), "m\(round)")
          }
        }
      }
      XCTAssertEqual(try stats(port).open, 5)
      // 5 sessions, the silent and the keep-alive connection
      XCTAssertTrue(eventually { server.openConnections == 7 }, "\(server.openConnections) connections")
    }
  }

  func testAnHTTPHandlerCanSendToTheWebSockets() throws {
    try serveChat { _, port in
      let clients = try (0..<3).map { _ in try WS.connect(port: port) }
      let response = try RawClient.request("POST", "/notify", port: port, body: Array("breaking news".utf8))
      XCTAssertEqual(response.bodyString, "3")
      for client in clients {
        XCTAssertEqual(text(WS.readFrame(client)), "breaking news")
      }
    }
  }

  func testEverythingRunsOnTheSameThread() throws {
    let log = ThreadLog()
    try withTestServer(configure: { server in
      server.configuration.threading = .singleThread
      server["/ws"] = NanoWebSocket.handler(
        text: { session, message in log.record(); session.writeText(message) },
        connected: { _ in log.record() },
        disconnected: { _ in log.record() })
      server.get["/ping"] = { _ in log.record(); return .ok(.text("pong")) }
      server.middleware.append { request, next in log.record(); return try next(request) }
    }) { _, port in
      let clients = try (0..<4).map { _ in try WS.connect(port: port) }
      for client in clients {
        client.send(WS.text("hi"))
        _ = WS.readFrame(client)
        _ = try RawClient.get("/ping", port: port)
      }
      clients.forEach { $0.close() }
      usleep(300_000)
      XCTAssertEqual(log.threads.count, 1, "callbacks ran on \(log.threads.count) threads")
      XCTAssertFalse(log.threads.contains(currentThreadID()))
    }
  }

  // MARK: Ending a session

  func testTheCloseHandshakeEndsOnlyThatSession() throws {
    try serveChat { server, port in
      let leaving = try WS.connect(port: port)
      let staying = try WS.connect(port: port)
      leaving.send(WS.frame(.close, [0x03, 0xE8]))
      let answer = WS.readFrame(leaving)
      XCTAssertEqual(WS.closeCode(answer), 1000)
      XCTAssertTrue(leaving.waitForClose(timeout: 2))
      XCTAssertTrue(eventually { (try? self.stats(port).disconnected) == 1 })
      staying.send(WS.text("after"))
      XCTAssertEqual(text(WS.readFrame(staying)), "after")
      XCTAssertEqual(try stats(port).open, 1)
    }
  }

  func testAClientThatDisappearsIsNoticed() throws {
    try serveChat { server, port in
      let gone = try WS.connect(port: port)
      XCTAssertTrue(eventually { (try? self.stats(port).open) == 1 })
      gone.close()
      XCTAssertTrue(eventually { (try? self.stats(port)) .map { $0.open == 0 && $0.disconnected == 1 } == true },
                    "the session of a client that went away was not ended")
      XCTAssertTrue(eventually { server.openConnections == 0 })
    }
  }

  func testAProtocolErrorEndsOnlyThatSessionAndDoesNotHoldUpTheServer() throws {
    try serveChat { _, port in
      let offender = try WS.connect(port: port)
      let bystander = try WS.connect(port: port)
      offender.send(WS.frame(.text, Array("not masked".utf8), masked: false))
      XCTAssertEqual(WS.closeCode(WS.readFrame(offender)), 1002)
      let begin = Date()
      XCTAssertEqual(try RawClient.get("/ping", port: port, timeout: 2).status, 200)
      XCTAssertLessThan(Date().timeIntervalSince(begin), 0.8, "the server waited for the offender")
      bystander.send(WS.text("fine"))
      XCTAssertEqual(text(WS.readFrame(bystander)), "fine")
    }
  }

  func testAStalledMessageEndsTheSessionAfterTheReadTimeout() throws {
    try serveChat(read: 0.4) { _, port in
      let stalling = try WS.connect(port: port)
      let bystander = try WS.connect(port: port)
      let frame = WS.text(String(repeating: "x", count: 50))
      stalling.send(Array(frame[0..<10])) // the rest never comes
      XCTAssertTrue(stalling.waitForClose(timeout: 4), "the session of a stalled client was not ended")
      bystander.send(WS.text("fine"))
      XCTAssertEqual(text(WS.readFrame(bystander)), "fine")
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
    }
  }

  func testAMessageThatArrivesInPartsIsPutTogether() throws {
    try serveChat { _, port in
      let client = try WS.connect(port: port)
      let frame = WS.text(String(repeating: "y", count: 300))
      client.send(Array(frame[0..<5]))
      usleep(100_000)
      client.send(Array(frame[5..<100]))
      usleep(100_000)
      client.send(Array(frame[100...]))
      XCTAssertEqual(text(WS.readFrame(client)), String(repeating: "y", count: 300))
    }
  }

  func testSilentWebSocketsAreNotClosedByTheIdleTimeout() throws {
    try serveChat(idle: 0.3) { _, port in
      let client = try WS.connect(port: port)
      usleep(1_200_000)
      client.send(WS.text("still open"))
      XCTAssertEqual(text(WS.readFrame(client)), "still open")
    }
  }

  func testStoppingTheServerEndsTheSessions() throws {
    let disconnected = Counter()
    let server = NanoHTTPServer()
    server.configuration.threading = .singleThread
    server["/ws"] = NanoWebSocket.handler(text: { session, message in session.writeText(message) },
                              disconnected: { _ in disconnected.increment() })
    try server.start(0)
    let port = try server.port()
    let clients = try (0..<3).map { _ in try WS.connect(port: port) }
    XCTAssertTrue(eventually { server.openConnections == 3 })
    server.stop()
    for client in clients {
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
    XCTAssertTrue(eventually { disconnected.count == 3 }, "\(disconnected.count) of 3 sessions were told that they ended")
    XCTAssertEqual(server.openConnections, 0)
  }

  func testSessionsCountTowardsTheLimitOfConnections() throws {
    try serveChat(max: 3) { server, port in
      let clients = try (0..<3).map { _ in try WS.connect(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 3 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 503)
      clients[0].send(WS.frame(.close, [0x03, 0xE8]))
      XCTAssertTrue(clients[0].waitForClose(timeout: 2))
      XCTAssertTrue(eventually { server.openConnections == 2 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
    }
  }

  // MARK: Messages

  func testBigMessagesFragmentsAndPings() throws {
    try serveChat { _, port in
      let client = try WS.connect(port: port)
      let big = [UInt8](repeating: 0x61, count: 70_000)
      client.send(WS.frame(.binary, big))
      XCTAssertEqual(WS.readFrame(client)?.payload.count, 70_000)
      client.send(WS.text("one ", fin: false))
      client.send(WS.frame(.continuation, Array("two ".utf8), fin: false))
      client.send(WS.frame(.continuation, Array("three".utf8), fin: true))
      XCTAssertEqual(text(WS.readFrame(client)), "one two three")
      client.send(WS.frame(.ping, [1, 2, 3]))
      let pong = WS.readFrame(client)
      XCTAssertEqual(pong?.opcode, WS.Opcode.pong.rawValue)
      XCTAssertEqual(pong?.payload, [1, 2, 3])
    }
  }

  func testManyClientsTalkAtTheSameTime() throws {
    try serveChat { _, port in
      let results = Counter()
      let failures = Counter()
      DispatchQueue.concurrentPerform(iterations: 20) { index in
        guard let client = try? RawClient(port: port, timeout: 10) else { failures.increment(); return }
        client.send(WS.handshakeRequest())
        guard client.readResponse()?.status == 101 else { failures.increment(); return }
        for message in 0..<10 {
          client.send(WS.frame(.binary, Array("\(index)-\(message)".utf8)))
          guard text(WS.readFrame(client)) == "\(index)-\(message)" else { failures.increment(); return }
          results.increment()
        }
      }
      XCTAssertEqual(failures.count, 0)
      XCTAssertEqual(results.count, 200)
    }
  }

  /// With a thread per connection the wait for the next message has no limit (the read timeout is only for a
  /// message that has begun), and a message that stalls ends the session after the read timeout.
  func testAThreadPerConnectionServerTimesOutOnlyAStalledMessage() throws {
    try withTestServer(configure: { server in
      server.configuration.readTimeout = 0.4
      server["/ws"] = NanoWebSocket.handler(text: { session, message in session.writeText(message) })
    }) { _, port in
      let silent = try WS.connect(port: port)
      let stalling = try WS.connect(port: port)
      stalling.send(Array(WS.text(String(repeating: "x", count: 50))[0..<10]))
      XCTAssertTrue(stalling.waitForClose(timeout: 4), "the session of a stalled client was not ended")
      usleep(500_000) // longer than the read timeout: the silent session is still there
      silent.send(WS.text("still here"))
      XCTAssertEqual(text(WS.readFrame(silent)), "still here")
    }
  }

  func testAThreadPerConnectionServerStillWorksAsBefore() throws {
    try withTestServer(configure: { server in
      server["/ws"] = NanoWebSocket.handler(text: { session, message in session.writeText(message) })
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      let clients = try (0..<3).map { _ in try WS.connect(port: port) }
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      for client in clients {
        client.send(WS.text("echo"))
        XCTAssertEqual(text(WS.readFrame(client)), "echo")
      }
    }
  }
}

// MARK: - Sessions of other protocols

/// Answers every line it receives with the same line in upper case; `bye` ends the session.
private final class ShoutingSession: NanoSocketSession {
  private let lock = NSLock()
  private var events = [String]()
  private var socket: NanoSocket?

  var log: [String] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.events
  }

  private func note(_ event: String) {
    self.lock.lock()
    self.events.append(event)
    self.lock.unlock()
  }

  func start(socket: NanoSocket, drainTimeout: TimeInterval, logger: NanoHTTPLogger) {
    self.socket = socket
    self.note("start")
    try? socket.writeUTF8("HELLO\n")
  }

  func receive() -> Bool {
    guard let socket, let line = try? socket.readLine() else {
      self.note("closed")
      return false
    }
    self.note("line \(line)")
    try? socket.writeUTF8(line.uppercased() + "\n")
    return line != "bye"
  }

  func end() {
    self.note("end")
    self.socket = nil
  }
}

final class SocketSessionTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading,
                     sessions: @escaping () -> ShoutingSession = { ShoutingSession() },
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      server["/shout"] = { _ in
        .switchProtocols(["Upgrade": "shout", "Connection": "Upgrade"], session: sessions())
      }
    }, body)
  }

  private func open(_ port: Int) throws -> RawClient {
    let client = try RawClient(port: port)
    client.send(RawClient.requestText("GET", "/shout", headers: ["Connection: Upgrade", "Upgrade: shout"]))
    XCTAssertEqual(client.readResponse()?.status, 101)
    return client
  }

  private func line(_ client: RawClient) -> String? {
    var bytes = [UInt8]()
    while let byte = client.readBytes(1)?.first {
      if byte == 10 {
        return String(decoding: bytes, as: UTF8.self)
      }
      bytes.append(byte)
    }
    return nil
  }

  func testASessionTalksWithItsClientInBothModes() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      try serve(threading) { _, port in
        let client = try open(port)
        XCTAssertEqual(line(client), "HELLO", "\(threading)")
        client.send("quiet\n")
        XCTAssertEqual(line(client), "QUIET", "\(threading)")
        client.send("louder\n")
        XCTAssertEqual(line(client), "LOUDER", "\(threading)")
      }
    }
  }

  func testASessionThatReturnsFalseEndsTheConnection() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      let session = ShoutingSession()
      try serve(threading, sessions: { session }) { server, port in
        let client = try open(port)
        XCTAssertEqual(line(client), "HELLO")
        client.send("bye\n")
        XCTAssertEqual(line(client), "BYE")
        XCTAssertTrue(client.waitForClose(timeout: 2), "\(threading)")
        XCTAssertTrue(eventually { server.openConnections == 0 })
        XCTAssertEqual(session.log, ["start", "line bye", "end"], "\(threading)")
      }
    }
  }

  func testTheSessionIsEndedWhenTheClientGoesAway() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      let session = ShoutingSession()
      try serve(threading, sessions: { session }) { server, port in
        let client = try open(port)
        XCTAssertEqual(line(client), "HELLO")
        client.close()
        XCTAssertTrue(eventually { session.log.last == "end" }, "\(threading): \(session.log)")
        XCTAssertEqual(session.log.filter { $0 == "end" }.count, 1)
        XCTAssertTrue(eventually { server.openConnections == 0 })
      }
    }
  }

  func testTheSessionIsEndedWhenTheServerStops() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      let session = ShoutingSession()
      var client: RawClient?
      try serve(threading, sessions: { session }) { server, port in
        client = try open(port)
        XCTAssertEqual(line(client!), "HELLO")
        server.stop()
        XCTAssertTrue(eventually { session.log.last == "end" }, "\(threading): \(session.log)")
      }
      XCTAssertEqual(session.log.filter { $0 == "end" }.count, 1, "\(threading)")
      _ = client
    }
  }

  func testASessionDoesNotHoldUpTheOnlyThread() throws {
    try serve(.singleThread) { _, port in
      let client = try open(port)
      XCTAssertEqual(line(client), "HELLO")
      XCTAssertEqual(try RawClient.get("/ping", port: port, timeout: 2).status, 200)
      client.send("hello again\n")
      XCTAssertEqual(line(client), "HELLO AGAIN")
    }
  }

  /// A session in the form of a function (`switchProtocols(_:_:)`) owns the thread until it returns, which is
  /// all that it can do on a server that has only one: nothing else is served meanwhile. (Use a
  /// `NanoSocketSession`, which the server drives, to avoid this.)
  func testASessionInTheFormOfAFunctionHoldsTheOnlyThread() throws {
    try withTestServer(configure: { server in
      server.configuration.threading = .singleThread
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      server["/blocking"] = { _ in
        .switchProtocols(["Upgrade": "blocking", "Connection": "Upgrade"], { socket in
          _ = try? socket.readLine() // returns when the client has sent a line
        })
      }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/blocking", headers: ["Connection: Upgrade", "Upgrade: blocking"]))
      XCTAssertEqual(client.readResponse()?.status, 101)
      XCTAssertThrowsError(try RawClient.get("/ping", port: port, timeout: 0.5), "served while the function runs")
      client.send("done\n")
      XCTAssertTrue(eventually { (try? RawClient.get("/ping", port: port, timeout: 1).status) == 200 })
    }
  }
}
