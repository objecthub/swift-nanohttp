//
//  LoggerTests.swift
//  NanoHTTPTests
//
//  4.1: the server reports through a logger (`Configuration.logger`) with levels, instead of printing.
//  The default logger writes to the unified logging system; the server's messages, and the ones of
//  WebSocket sessions, go to whichever logger is configured.
//

import XCTest
@testable import NanoHTTP

private let bothModes: [NanoHTTPServer.Configuration.Threading] = [.perConnection, .singleThread]

/// Counts how often a message is built.
private final class Counter {
  private(set) var value = 0

  func next(_ text: String) -> String {
    self.value += 1
    return text
  }
}

final class NanoLogLevelTests: XCTestCase {

  func testLevelsAreOrderedFromDebugToError() {
    XCTAssertLessThan(NanoLogLevel.debug, .info)
    XCTAssertLessThan(NanoLogLevel.info, .warning)
    XCTAssertLessThan(NanoLogLevel.warning, .error)
    XCTAssertEqual([NanoLogLevel.error, .debug, .warning, .info].sorted(), [.debug, .info, .warning, .error])
  }

  func testLevelsHaveNames() {
    XCTAssertEqual([NanoLogLevel.debug, .info, .warning, .error].map { "\($0)" }, ["debug", "info", "warning", "error"])
  }
}

final class BuiltInLoggerTests: XCTestCase {

  private final class Lines {
    private let lock = NSLock()
    private var lines = [String]()

    func add(_ line: String) {
      self.lock.lock()
      self.lines.append(line)
      self.lock.unlock()
    }

    var all: [String] {
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.lines
    }
  }

  func testTheConsoleLoggerWritesALineWithTheLevel() {
    let lines = Lines()
    let logger = NanoConsoleLogger(minimumLevel: .debug, output: lines.add)
    logger.log(.debug, "d")
    logger.log(.info, "i")
    logger.log(.warning, "w")
    logger.log(.error, "e")
    XCTAssertEqual(lines.all, ["[DEBUG] d", "[INFO] i", "[WARNING] w", "[ERROR] e"])
  }

  func testTheConsoleLoggerDropsLowerLevelsWithoutBuildingTheirMessages() {
    let lines = Lines()
    let built = Counter()
    let logger = NanoConsoleLogger(minimumLevel: .warning, output: lines.add)
    logger.log(.debug, built.next("a"))
    logger.log(.info, built.next("b"))
    logger.log(.warning, built.next("c"))
    logger.log(.error, built.next("d"))
    XCTAssertEqual(lines.all, ["[WARNING] c", "[ERROR] d"])
    XCTAssertEqual(built.value, 2, "the messages below the minimum level are not built")
  }

  func testTheDefaultMinimumLevelOfTheConsoleLoggerIsInfo() {
    let lines = Lines()
    let logger = NanoConsoleLogger(output: lines.add)
    logger.log(.debug, "hidden")
    logger.log(.info, "shown")
    XCTAssertEqual(lines.all, ["[INFO] shown"])
    XCTAssertEqual(logger.minimumLevel, .info)
  }

  func testTheSilentLoggerDiscardsEverythingWithoutBuildingMessages() {
    let built = Counter()
    let logger = NanoSilentLogger()
    for level in [NanoLogLevel.debug, .info, .warning, .error] {
      logger.log(level, built.next("x"))
    }
    XCTAssertEqual(built.value, 0)
  }

  func testTheOSLoggerLogsAtAllLevelsAndBuildsOnlyWhatItWants() {
    let built = Counter()
    let logger = NanoOSLogger(subsystem: "org.objecthub.NanoHTTP.tests", category: "test", minimumLevel: .info)
    logger.log(.debug, built.next("not built"))
    logger.log(.info, built.next("info of the tests"))
    logger.log(.warning, built.next("warning of the tests"))
    logger.log(.error, built.next("error of the tests"))
    XCTAssertEqual(built.value, 3)
    XCTAssertEqual(logger.minimumLevel, .info)
  }

  func testTheShortcutsLogAtTheirLevel() {
    let logger = CapturingLogger()
    logger.debug("a")
    logger.info("b")
    logger.warning("c")
    logger.error("d")
    XCTAssertEqual(logger.entries.map { $0.level }, [.debug, .info, .warning, .error])
    XCTAssertEqual(logger.messages, ["a", "b", "c", "d"])
  }

  func testTheShortcutsDoNotBuildMessagesForALoggerThatDoesNotWantThem() {
    let built = Counter()
    NanoSilentLogger().warning(built.next("x"))
    NanoConsoleLogger(minimumLevel: .error, output: { _ in }).info(built.next("y"))
    XCTAssertEqual(built.value, 0)
  }
}

// MARK: - The server

final class ServerLoggerTests: XCTestCase {

  func testTheDefaultLoggerWritesToTheUnifiedLog() {
    XCTAssertTrue(NanoHTTPServer.Configuration().logger is NanoOSLogger)
    XCTAssertTrue(NanoHTTPServer().logger is NanoOSLogger)
  }

  func testTheServerLogsWithTheLoggerOfItsConfiguration() {
    let logger = CapturingLogger()
    let server = NanoHTTPServer()
    server.configuration.logger = logger
    server.log("plain")
    server.log(.warning, "careful")
    server.log(.debug, "detail")
    XCTAssertEqual(logger.entries.map { $0.level }, [.info, .warning, .debug])
    XCTAssertEqual(logger.messages, ["plain", "careful", "detail"])
  }

  func testAMessageIsOnlyBuiltIfTheLoggerWantsIt() {
    let built = Counter()
    let server = NanoHTTPServer()
    server.configuration.logger = NanoSilentLogger()
    server.log(.error, built.next("x"))
    XCTAssertEqual(built.value, 0)
  }

  func testALoggerThatIsSetWhileTheServerRunsTakesEffectInTheNextRun() throws {
    let first = CapturingLogger()
    let second = CapturingLogger()
    let server = NanoHTTPServer()
    server.configuration.logger = first
    try server.start(0)
    server.configuration.logger = second
    server.log("while running")
    server.stop()
    XCTAssertEqual(first.messages, ["while running"])
    XCTAssertEqual(second.messages, [])
    server.log("after")
    XCTAssertEqual(second.messages, ["after"])
  }

  /// Closing the listening socket makes the accept that waits for it fail: that is no failure to report.
  func testStartingServingAndStoppingAServerLogsNothing() throws {
    for threading in bothModes {
      let logger = CapturingLogger()
      let server = NanoHTTPServer()
      server.configuration.threading = threading
      server.configuration.logger = logger
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      for _ in 0..<3 {
        try server.start(0)
        XCTAssertEqual(try RawClient.get("/ping", port: try server.port()).status, 200)
        server.stop()
        usleep(50_000)
      }
      XCTAssertEqual(logger.messages, [], "\(threading)")
    }
  }

  func testAFailingHandlerIsLoggedAsAnErrorWithMethodAndPath() throws {
    for threading in bothModes {
      let logger = CapturingLogger()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.logger = logger
        server.get["/broken/:id"] = { _ in throw NSError(domain: "test", code: 7) }
        server.get["/missing"] = { _ in throw NanoHTTPError.notFound() }
      }) { _, port in
        XCTAssertEqual(try RawClient.get("/broken/a%20b", port: port).status, 500)
        XCTAssertEqual(try RawClient.get("/missing", port: port).status, 404)
      }
      let messages = logger.messages(containing: "failed", level: .error)
      XCTAssertEqual(messages.count, 1, "\(threading): \(logger.messages)")
      XCTAssertTrue(messages.first?.contains("GET /broken/a%20b") ?? false, "the raw path is logged: \(messages)")
      XCTAssertTrue(messages.first?.contains("test") ?? false, "\(messages)")
    }
  }

  func testADroppedResponseHeaderIsLoggedAsAWarning() throws {
    for threading in bothModes {
      let logger = CapturingLogger()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.logger = logger
        server.get["/h"] = { _ in .ok(headers: ["Bad Name": "x", "X-Good": "y"], .text("fine")) }
      }) { _, port in
        let response = try RawClient.get("/h", port: port)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.header("x-good"), "y")
      }
      XCTAssertTrue(logger.contains("Dropped a response header", level: .warning), "\(threading): \(logger.messages)")
    }
  }

  func testAWrongContentLengthIsLoggedAsAnError() throws {
    let logger = CapturingLogger()
    try withTestServer(configure: { server in
      server.configuration.logger = logger
      server.get["/short"] = { _ in
        .custom(200, headers: ["Content-Length": "10"]) { writer in try writer.write(Array("abc".utf8)) }
      }
    }) { _, port in
      _ = try? RawClient.get("/short", port: port)
      XCTAssertTrue(logger.waitFor("fewer bytes than the 10", level: .error), "\(logger.messages)")
    }
  }

  func testABodyThatCannotBeProducedIsLoggedAsAnError() throws {
    let logger = CapturingLogger()
    try withTestServer(configure: { server in
      server.configuration.logger = logger
      server.get["/date"] = { _ in .ok(.json(Date())) } // not JSON
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/date", port: port).status, 500)
      XCTAssertTrue(logger.waitFor("Unable to produce the body", level: .error), "\(logger.messages)")
    }
  }

  func testAResponseThatCannotBeWrittenIsLoggedAsInfo() throws {
    for threading in bothModes {
      let logger = CapturingLogger()
      let big = [UInt8](repeating: 0x61, count: 32 * 1024 * 1024)
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.logger = logger
        server.configuration.writeTimeout = 0.5
        server.get["/big"] = { _ in .ok(.data(Data(big), contentType: "application/octet-stream")) }
      }) { _, port in
        let client = try RawClient(port: port, receiveBuffer: 4096)
        client.send(RawClient.requestText("GET", "/big", headers: ["Connection: close"]))
        XCTAssertTrue(logger.waitFor("Failed to send response", level: .info, timeout: 10), "\(threading): \(logger.messages)")
        client.close()
      }
    }
  }

  func testTheConnectionLimitIsReportedOnceWhileConnectionsAreRefused() throws {
    let logger = CapturingLogger()
    try withTestServer(configure: { server in
      server.configuration.logger = logger
      server.configuration.maxConnections = 2
      server.configuration.idleTimeout = 30
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { server, port in
      let held = try (0..<2).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 2 })
      for _ in 0..<3 {
        XCTAssertEqual(try RawClient.get("/ping", port: port).status, 503)
      }
      XCTAssertEqual(logger.messages(containing: "open connections", level: .warning).count, 1, "\(logger.messages)")
      held.forEach { $0.close() }
    }
  }

  func testAShortageOfDescriptorsIsReportedAsAWarning() throws {
    raiseFileDescriptorLimit()
    let logger = CapturingLogger()
    try withTestServer(configure: { server in
      server.configuration.logger = logger
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      // Descriptors that other threads free in the middle of the shortage give `accept` room again: try again then.
      var reported = false
      for _ in 0..<3 where !reported {
        _ = settledDescriptorCount()
        let clients = try (0..<4).map { _ in try RawClient(port: port, connect: false) }
        let restore = exhaustFileDescriptors(leaving: 1)
        for client in clients {
          try? client.connect(port: port)
          client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: close"]))
        }
        reported = logger.waitFor("Unable to accept a connection", level: .warning, timeout: 2)
        restore()
        clients.forEach { $0.close() }
      }
      XCTAssertTrue(reported, "\(logger.messages)")
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      XCTAssertTrue(logger.waitFor("Accepting connections again", level: .info), "\(logger.messages)")
    }
  }
}

// MARK: - Sessions

/// A session of a protocol of its own that remembers the logger it was given.
private final class ProbeSession: NanoSocketSession {
  private let lock = NSLock()
  private var received: NanoHTTPLogger?

  var logger: NanoHTTPLogger? {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.received
  }

  func start(socket: NanoSocket, drainTimeout: TimeInterval, logger: NanoHTTPLogger) {
    self.lock.lock()
    self.received = logger
    self.lock.unlock()
  }

  func receive() -> Bool {
    return false
  }

  func end() {
  }
}

final class SessionLoggingTests: XCTestCase {

  func testASessionReceivesTheLoggerOfTheServer() throws {
    for threading in bothModes {
      let logger = CapturingLogger()
      let probe = ProbeSession()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.logger = logger
        server.get["/probe"] = { _ in NanoHTTPResponse.switchProtocols([:], session: probe) }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/probe"))
        XCTAssertEqual(client.readResponse(head: true)?.status, 101, "\(threading)")
        XCTAssertTrue(eventually { probe.logger != nil }, "\(threading)")
        XCTAssertTrue((probe.logger as? CapturingLogger) === logger, "\(threading)")
        client.close()
      }
    }
  }

  func testAWebSocketClientThatBreaksTheProtocolIsLoggedAsInfo() throws {
    for threading in bothModes {
      let logger = CapturingLogger()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.logger = logger
        server["/ws"] = NanoWebSocket.handler(text: { session, text in session.writeText(text) })
      }) { _, port in
        let unmasked = try WS.connect(port: port)
        unmasked.send(WS.frame(.text, Array("hi".utf8), masked: false))
        XCTAssertTrue(logger.waitFor("unmasked frame", level: .info), "\(threading): \(logger.messages)")
        unmasked.close()
        let invalid = try WS.connect(port: port)
        invalid.send(WS.frame(.text, [0xC3, 0x28]))
        XCTAssertTrue(logger.waitFor("invalid UTF-8", level: .info), "\(threading): \(logger.messages)")
        invalid.close()
      }
      XCTAssertEqual(logger.entries.filter { $0.level >= .warning }.count, 0, "client mistakes are no warnings: \(logger.messages)")
    }
  }

  /// A session that ends after the close handshake has nothing left to say: it used to write a second
  /// close frame to the closed connection when it was released, which failed (and was printed).
  func testAWebSocketThatEndsWithTheCloseHandshakeLogsNothing() throws {
    for threading in bothModes {
      let logger = CapturingLogger()
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.logger = logger
        server["/ws"] = NanoWebSocket.handler(text: { session, text in session.writeText(text) })
      }) { server, port in
        let client = try WS.connect(port: port)
        client.send(WS.frame(.text, Array("hello".utf8)))
        XCTAssertEqual(WS.readFrame(client)?.payload, Array("hello".utf8), "\(threading)")
        client.send(WS.frame(.close, [0x03, 0xE8])) // 1000
        XCTAssertEqual(WS.closeCode(WS.readFrame(client)), 1000, "\(threading)")
        client.close()
        XCTAssertTrue(eventually { server.openConnections == 0 }, "\(threading)")
        usleep(300_000) // the session is released about now
      }
      XCTAssertEqual(logger.messages, [], "\(threading)")
    }
  }

  func testWritingToAClientThatHasGoneIsLogged() throws {
    let logger = CapturingLogger()
    let box = SessionBox()
    try withTestServer(configure: { server in
      server.configuration.logger = logger
      server["/ws"] = NanoWebSocket.handler(connected: { box.set($0) })
    }) { _, port in
      let client = try WS.connect(port: port)
      XCTAssertTrue(eventually { box.value != nil })
      client.close()
      let session = box.value!
      let payload = String(repeating: "x", count: 64 * 1024)
      XCTAssertTrue(eventually(timeout: 8) {
        session.writeText(payload)
        return logger.contains("unable to write a frame", level: .info)
      }, "\(logger.messages)")
    }
  }

  func testASessionThatIsMadeByHandLogsOnlyIfItHasALogger() {
    let socket = NanoSocket(socketFileDescriptor: open("/dev/null", O_WRONLY))
    socket.close() // every write fails
    let session = NanoWebSocketSession(socket)
    XCTAssertNil(session.logger)
    session.writeText("nobody listens") // fails, and there is nobody to tell: no crash, no output
    let logger = CapturingLogger()
    session.logger = logger
    session.writeText("nobody listens")
    XCTAssertEqual(logger.entries.map { $0.level }, [.info])
    XCTAssertTrue(logger.contains("unable to write a frame"), "\(logger.messages)")
  }
}

/// Keeps a session that a `connected` closure was given.
private final class SessionBox {
  private let lock = NSLock()
  private var session: NanoWebSocketSession?

  func set(_ value: NanoWebSocketSession) {
    self.lock.lock()
    self.session = value
    self.lock.unlock()
  }

  var value: NanoWebSocketSession? {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.session
  }
}
