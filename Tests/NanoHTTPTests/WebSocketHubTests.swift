//
//  WebSocketHubTests.swift
//  NanoHTTPTests
//
//  4.3 (W2): the WebSocket handler checks origins and negotiates subprotocols, and a `NanoWebSocketHub` keeps the
//  sessions that belong together and sends a message to all of them, on a server with a thread per connection and on
//  one with a single thread, without locks in the code that uses it. A client that does not read cannot hold the
//  others up for long.
//

import XCTest
@testable import NanoHTTP

private let bothModes: [NanoHTTPServer.Configuration.Threading] = [.perConnection, .singleThread]

/// A handshake with exactly the headers that are given.
private func handshake(_ path: String = "/ws",
                       host: String = "localhost",
                       headers: [String] = [],
                       key: String? = WS.key) -> [UInt8] {
  var text = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
  if let key {
    text += "Sec-WebSocket-Key: \(key)\r\n"
  }
  for header in headers {
    text += header + "\r\n"
  }
  return Array((text + "\r\n").utf8)
}

/// The answer to a handshake.
private func answer(_ port: Int, _ request: [UInt8]) throws -> RawResponse? {
  let client = try RawClient(port: port)
  defer { client.close() }
  client.send(request)
  return client.readResponse(head: true)
}

// MARK: - Origins

final class WebSocketOriginTests: XCTestCase {

  func testTheHandlerChecksTheOriginOfItsOwnRoute() throws {
    for threading in bothModes {
      try withTestServer(configure: { server in
        server.configuration.threading = threading // the policy of the server is off
        server["/guarded"] = NanoWebSocket.handler(text: { session, text in session.writeText(text) }, origins: .sameOrigin)
        server["/listed"] = NanoWebSocket.handler(origins: .origins(["https://app.example"]))
        server["/open"] = NanoWebSocket.handler(text: { session, text in session.writeText(text) })
      }) { _, port in
        let host = "127.0.0.1:\(port)"
        for origin in ["http://evil.example", "null", "http://127.0.0.1:\(port + 1)", "garbage"] {
          XCTAssertEqual(try answer(port, handshake("/guarded", host: host, headers: ["Origin: \(origin)"]))?.status, 403,
                         "\(threading): \(origin)")
        }
        XCTAssertEqual(try answer(port, handshake("/guarded", host: host, headers: ["Origin: http://\(host)"]))?.status, 101, "\(threading)")
        XCTAssertEqual(try answer(port, handshake("/guarded", host: host))?.status, 101, "\(threading): a client that is no browser")
        XCTAssertEqual(try answer(port, handshake("/listed", host: host, headers: ["Origin: https://app.example"]))?.status, 101)
        XCTAssertEqual(try answer(port, handshake("/listed", host: host, headers: ["Origin: https://evil.example"]))?.status, 403)
        XCTAssertEqual(try answer(port, handshake("/open", host: host, headers: ["Origin: http://evil.example"]))?.status, 101,
                       "\(threading): the other routes are not affected")
      }
    }
  }

  func testTheOriginPolicyOfTheServerAppliesToHandlersWithoutOrigins() throws {
    try withTestServer(configure: { server in
      server.configuration.originPolicy = .sameOrigin
      server["/ws"] = NanoWebSocket.handler(text: { session, text in session.writeText(text) })
    }) { _, port in
      XCTAssertEqual(try answer(port, handshake(host: "127.0.0.1:\(port)", headers: ["Origin: http://evil.example"]))?.status, 403)
      XCTAssertEqual(try answer(port, handshake(host: "127.0.0.1:\(port)", headers: ["Origin: http://127.0.0.1:\(port)"]))?.status, 101)
    }
  }
}

// MARK: - Subprotocols

final class WebSocketSubprotocolTests: XCTestCase {

  private func serve(protocols: [String],
                     threading: NanoHTTPServer.Configuration.Threading = .perConnection,
                     seen: SubprotocolBox = SubprotocolBox(),
                     _ body: (Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server["/ws"] = NanoWebSocket.handler(connected: { seen.add($0.subprotocol) }, protocols: protocols)
    }) { _, port in
      try body(port)
    }
  }

  func testTheHandlerChoosesItsFirstProtocolThatTheClientOffers() throws {
    let cases: [(offered: String, chosen: String)] = [
      ("chat.v1, chat.v2", "chat.v2"),
      ("chat.v2", "chat.v2"),
      ("chat.v1", "chat.v1"),
      ("other,chat.v1 ,  chat.v2", "chat.v2"),
      ("chat.v1,chat.v1", "chat.v1"),
    ]
    for threading in bothModes {
      try serve(protocols: ["chat.v2", "chat.v1"], threading: threading) { port in
        for (offered, chosen) in cases {
          let response = try answer(port, handshake(headers: ["Sec-WebSocket-Protocol: \(offered)"]))
          XCTAssertEqual(response?.status, 101, "\(threading): \(offered)")
          XCTAssertEqual(response?.header("sec-websocket-protocol"), chosen, "\(threading): \(offered)")
        }
      }
    }
  }

  func testAClientThatOffersNoProtocolIsAcceptedWithoutOne() throws {
    let seen = SubprotocolBox()
    try serve(protocols: ["chat.v2"], seen: seen) { port in
      let response = try answer(port, handshake())
      XCTAssertEqual(response?.status, 101)
      XCTAssertNil(response?.header("sec-websocket-protocol"))
      XCTAssertEqual(try answer(port, handshake(headers: ["Sec-WebSocket-Protocol: "]))?.status, 101, "an empty offer is no offer")
      XCTAssertTrue(eventually { seen.all.count == 2 })
      XCTAssertEqual(seen.all.map { $0 ?? "-" }, ["-", "-"])
    }
  }

  func testAClientThatOffersOnlyProtocolsThatAreUnknownIsRefused() throws {
    try serve(protocols: ["chat.v2"]) { port in
      let response = try answer(port, handshake(headers: ["Sec-WebSocket-Protocol: mqtt, soap"]))
      XCTAssertEqual(response?.status, 400)
      XCTAssertNil(response?.header("sec-websocket-protocol"))
      XCTAssertNil(response?.header("sec-websocket-accept"))
      XCTAssertEqual(try answer(port, handshake(headers: ["Sec-WebSocket-Protocol: CHAT.V2"]))?.status, 400, "names are case-sensitive")
    }
  }

  func testWithoutProtocolsTheHeaderOfTheClientIsIgnored() throws {
    try serve(protocols: []) { port in
      let response = try answer(port, handshake(headers: ["Sec-WebSocket-Protocol: mqtt"]))
      XCTAssertEqual(response?.status, 101)
      XCTAssertNil(response?.header("sec-websocket-protocol"))
    }
  }

  func testTheHeaderMayBeSentTwice() throws {
    try serve(protocols: ["b"]) { port in
      let response = try answer(port, handshake(headers: ["Sec-WebSocket-Protocol: a", "Sec-WebSocket-Protocol: b"]))
      XCTAssertEqual(response?.status, 101)
      XCTAssertEqual(response?.header("sec-websocket-protocol"), "b")
    }
  }

  func testTheSessionKnowsTheProtocol() throws {
    for threading in bothModes {
      let seen = SubprotocolBox()
      try serve(protocols: ["x", "y"], threading: threading, seen: seen) { port in
        let client = try RawClient(port: port)
        client.send(handshake(headers: ["Sec-WebSocket-Protocol: y"]))
        XCTAssertEqual(client.readResponse(head: true)?.status, 101)
        XCTAssertTrue(eventually { seen.all.count == 1 })
        XCTAssertEqual(seen.all.first ?? nil, "y", "\(threading)")
        client.close()
      }
    }
  }
}

/// The size of a message that another thread has read.
private final class ReceivedSize {
  private let lock = NSLock()
  private var size: Int?

  func set(_ value: Int?) {
    self.lock.lock()
    self.size = value
    self.lock.unlock()
  }

  var value: Int? {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.size
  }
}

/// Collects the subprotocols that sessions report.
final class SubprotocolBox {
  private let lock = NSLock()
  private var values = [String?]()

  func add(_ value: String?) {
    self.lock.lock()
    self.values.append(value)
    self.lock.unlock()
  }

  var all: [String?] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.values
  }
}

// MARK: - The hub

final class WebSocketHubTests: XCTestCase {

  /// A session that writes into a socket pair; the other end is what a client would read.
  private func pair() -> (session: NanoWebSocketSession, peer: Int32) {
    var descriptors: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    NanoSocket.setNoSigPipe(descriptors[0])
    return (NanoWebSocketSession(NanoSocket(socketFileDescriptor: descriptors[0])), descriptors[1])
  }

  private func frame(from peer: Int32) -> (opcode: UInt8, payload: [UInt8])? {
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var head = [UInt8](repeating: 0, count: 2)
    guard read(peer, &head, 2) == 2 else {
      return nil
    }
    var payload = [UInt8](repeating: 0, count: Int(head[1] & 0x7F))
    var received = 0
    while received < payload.count {
      let wanted = payload.count - received
      let count = payload.withUnsafeMutableBytes { read(peer, $0.baseAddress! + received, wanted) }
      guard count > 0 else {
        return nil
      }
      received += count
    }
    return (head[0] & 0x0F, payload)
  }

  func testSessionsJoinOnceAndLeave() {
    let hub = NanoWebSocketHub()
    let (a, peerA) = self.pair()
    let (b, peerB) = self.pair()
    defer { close(peerA); close(peerB) }
    XCTAssertEqual(hub.count, 0)
    hub.add(a)
    hub.add(b)
    hub.add(a)
    XCTAssertEqual(hub.count, 2, "a session is in the hub once")
    XCTAssertTrue(hub.sessions == [a, b], "in the order in which they joined")
    hub.remove(a)
    XCTAssertTrue(hub.sessions == [b])
    hub.remove(a)
    XCTAssertEqual(hub.count, 1)
  }

  func testABroadcastReachesEverySessionExceptTheOneThatIsExcluded() {
    let hub = NanoWebSocketHub()
    let members = (0..<3).map { _ in self.pair() }
    defer { members.forEach { close($0.peer) } }
    members.forEach { hub.add($0.session) }
    hub.broadcast(text: "hello", except: members[1].session)
    XCTAssertEqual(self.frame(from: members[0].peer)?.payload, Array("hello".utf8))
    XCTAssertEqual(self.frame(from: members[2].peer)?.opcode, 1)
    XCTAssertNil(self.frame(from: members[1].peer), "nothing for the session that was left out")
    hub.broadcast(binary: [1, 2, 3])
    let binary = self.frame(from: members[1].peer)
    XCTAssertEqual(binary?.opcode, 2)
    XCTAssertEqual(binary?.payload, [1, 2, 3])
  }

  func testABroadcastToAnEmptyHubDoesNothing() {
    let hub = NanoWebSocketHub()
    hub.broadcast(text: "nobody")
    hub.broadcast(binary: [])
    XCTAssertEqual(hub.count, 0)
  }

  func testAWriteThatFailsEndsTheSessionAndIsLoggedOnce() {
    let (session, peer) = self.pair()
    let logger = CapturingLogger()
    session.logger = logger
    close(peer) // the client has gone
    for _ in 0..<5 {
      session.writeText(String(repeating: "x", count: 1000))
    }
    XCTAssertTrue(session.socket.isClosed, "the connection is closed: the session is over")
    XCTAssertEqual(logger.messages(containing: "unable to write a frame", level: .info).count, 1, "\(logger.messages)")
  }

  func testSessionsJoinAndLeaveWithTheirConnections() throws {
    for threading in bothModes {
      let hub = NanoWebSocketHub()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server["/chat"] = NanoWebSocket.handler(text: { session, text in hub.broadcast(text: text, except: session) }, hub: hub)
      }) { _, port in
        let clients = try (0..<3).map { _ in try WS.connect(port: port, path: "/chat") }
        XCTAssertTrue(eventually { hub.count == 3 }, "\(threading)")
        clients[0].send(WS.frame(.close, [0x03, 0xE8]))
        XCTAssertEqual(WS.closeCode(WS.readFrame(clients[0])), 1000, "\(threading)")
        clients[0].close()
        XCTAssertTrue(eventually { hub.count == 2 }, "a session that said goodbye left: \(threading)")
        clients[1].close() // gone without a goodbye
        XCTAssertTrue(eventually { hub.count == 1 }, "\(threading)")
        clients[2].close()
        XCTAssertTrue(eventually { hub.count == 0 }, "\(threading)")
      }
    }
  }

  func testAChatNeedsNoLocksOnAnyServer() throws {
    for threading in bothModes {
      let hub = NanoWebSocketHub()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server["/chat"] = NanoWebSocket.handler(text: { session, text in hub.broadcast(text: text, except: session) }, hub: hub)
        server.post["/announce"] = { request in
          hub.broadcast(text: request.bodyString ?? "")
          return .ok(.text("\(hub.count)"))
        }
      }) { _, port in
        let clients = try (0..<4).map { _ in try WS.connect(port: port, path: "/chat") }
        XCTAssertTrue(eventually { hub.count == 4 })
        clients[0].send(WS.frame(.text, Array("from zero".utf8)))
        for client in clients[1...] {
          XCTAssertEqual(WS.readFrame(client)?.payload, Array("from zero".utf8), "\(threading)")
        }
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("POST", "/announce", headers: ["Connection: close"], body: Array("news".utf8)))
        XCTAssertEqual(client.readResponse()?.bodyString, "4", "\(threading)")
        for client in clients {
          XCTAssertEqual(WS.readFrame(client)?.payload, Array("news".utf8), "\(threading)")
        }
        clients.forEach { $0.close() }
      }
    }
  }

  func testManySessions() throws {
    raiseFileDescriptorLimit()
    for threading in bothModes {
      let hub = NanoWebSocketHub()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.maxConnections = 200
        server["/chat"] = NanoWebSocket.handler(hub: hub)
      }) { _, port in
        let clients = try (0..<100).map { _ in try WS.connect(port: port, path: "/chat") }
        XCTAssertTrue(eventually(timeout: 10) { hub.count == 100 }, "\(threading): \(hub.count)")
        hub.broadcast(text: "to everybody")
        for (index, client) in clients.enumerated() {
          XCTAssertEqual(WS.readFrame(client)?.payload, Array("to everybody".utf8), "\(threading): client \(index)")
        }
        clients.forEach { $0.close() }
        XCTAssertTrue(eventually(timeout: 10) { hub.count == 0 }, "\(threading)")
      }
    }
  }

  /// A client that stops reading must not hold up the others for longer than the write timeout of sessions, and
  /// leaves the hub.
  func testAClientThatDoesNotReadIsDroppedAndTheOthersStillGetTheMessage() throws {
    for threading in bothModes {
      let hub = NanoWebSocketHub()
      let logger = CapturingLogger()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.sessionWriteTimeout = 0.5
        server.configuration.logger = logger
        server["/chat"] = NanoWebSocket.handler(hub: hub)
      }) { _, port in
        let stalled = try RawClient(port: port, receiveBuffer: 4096) // joins first, and never reads
        stalled.send(handshake("/chat"))
        XCTAssertEqual(stalled.readResponse(head: true)?.status, 101)
        let healthy = try WS.connect(port: port, path: "/chat")
        XCTAssertTrue(eventually { hub.count == 2 }, "\(threading)")
        let big = String(repeating: "x", count: 16 * 1024 * 1024)
        // The healthy client reads while the message is sent, as a client does.
        let received = ReceivedSize()
        let done = expectation(description: "the healthy client has the message")
        DispatchQueue.global().async {
          received.set(WS.readFrame(healthy)?.payload.count)
          done.fulfill()
        }
        let start = Date()
        hub.broadcast(text: big)
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 5, "\(threading): the broadcast was held up for \(took) s")
        wait(for: [done], timeout: 10)
        XCTAssertEqual(received.value, big.utf8.count, "\(threading): the other client got the message")
        XCTAssertTrue(eventually { hub.count == 1 }, "\(threading): the client that does not read has left the hub")
        XCTAssertTrue(logger.waitFor("unable to write a frame", level: .info), "\(logger.messages)")
        healthy.close()
        stalled.close()
      }
    }
  }

  /// On a server with one thread, a broadcast from a handler holds up everything for as long as the clients that do not
  /// read take to time out; then the server goes on.
  func testTheServerWithOneThreadGoesOnAfterAClientThatDoesNotRead() throws {
    let hub = NanoWebSocketHub()
    try withTestServer(configure: { server in
      server.configuration.threading = .singleThread
      server.configuration.sessionWriteTimeout = 0.5
      server["/chat"] = NanoWebSocket.handler(hub: hub)
      server.post["/shout"] = { _ in
        hub.broadcast(text: String(repeating: "y", count: 16 * 1024 * 1024))
        return .ok(.text("shouted"))
      }
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      let stalled = try RawClient(port: port, receiveBuffer: 4096)
      stalled.send(handshake("/chat"))
      XCTAssertEqual(stalled.readResponse(head: true)?.status, 101)
      XCTAssertTrue(eventually { hub.count == 1 })
      let start = Date()
      XCTAssertEqual(try RawClient.request("POST", "/shout", port: port, headers: ["Connection: close"], body: [], timeout: 10).bodyString,
                     "shouted")
      XCTAssertLessThan(Date().timeIntervalSince(start), 5)
      XCTAssertEqual(try RawClient.get("/ping", port: port).bodyString, "pong")
      XCTAssertTrue(eventually { hub.count == 0 })
      stalled.close()
    }
  }
}
