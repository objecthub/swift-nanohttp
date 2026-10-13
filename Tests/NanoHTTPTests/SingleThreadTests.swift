//
//  SingleThreadTests.swift
//  NanoHTTPTests
//
//  `Configuration.threading = .singleThread`: one thread accepts connections, reads requests, calls
//  the middleware and the handlers and writes the responses, so handlers need no locks. Connections
//  that wait for a request do not block the others.
//

import XCTest
import Darwin
@testable import NanoHTTP

/// Remembers the threads that called `record()`.
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

final class SingleThreadTests: XCTestCase {

  private func serve(idle: TimeInterval? = 30,
                     read: TimeInterval? = 30,
                     max: Int? = 128,
                     configure: (NanoHTTPServer) -> Void = { _ in },
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = .singleThread
      server.configuration.idleTimeout = idle
      server.configuration.readTimeout = read
      server.configuration.maxConnections = max
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      configure(server)
    }, body)
  }

  func testTheDefaultIsOneThreadPerConnection() {
    XCTAssertEqual(NanoHTTPServer.Configuration().threading, .perConnection)
  }

  // MARK: - Everything runs on one thread

  func testMiddlewareHandlersAndTheNotFoundHandlerRunOnTheSameThread() throws {
    let log = ThreadLog()
    try serve(configure: { server in
      server.middleware.append { _ in log.record(); return nil }
      server.get["/ping"] = { _ in log.record(); return .ok(.text("pong")) }
      server.notFoundHandler = { _ in log.record(); return .notFound() }
      server.post["/echo"] = { request in log.record(); return .ok(.data(Data(request.body), contentType: "text/plain")) }
    }) { _, port in
      DispatchQueue.concurrentPerform(iterations: 40) { index in
        switch index % 3 {
          case 0: _ = try? RawClient.get("/missing", port: port)
          case 1: _ = try? RawClient.get("/ping", port: port)
          default: _ = try? RawClient.request("POST", "/echo", port: port, body: Array("hi".utf8))
        }
      }
      XCTAssertEqual(log.threads.count, 1, "handlers ran on \(log.threads.count) threads")
      XCTAssertFalse(log.threads.contains(currentThreadID()), "the thread that called start() serves requests")
    }
  }

  func testWithPerConnectionThreadsHandlersRunOnSeveralThreads() throws {
    let log = ThreadLog()
    try withTestServer(configure: { server in
      server.get["/slow"] = { _ in log.record(); usleep(150_000); return .ok(.text("slow")) }
    }) { _, port in
      DispatchQueue.concurrentPerform(iterations: 6) { _ in
        _ = try? RawClient.get("/slow", port: port)
      }
      XCTAssertGreaterThan(log.threads.count, 1)
    }
  }

  /// The point of the mode: state that handlers share needs no lock. The counters are plain variables;
  /// the thread sanitizer reports a race if two handlers ever run at the same time.
  func testHandlersNeedNoLocks() throws {
    var inFlight = 0
    var mostInFlight = 0
    var total = 0
    try serve(configure: { server in
      server.get["/work"] = { _ in
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        usleep(15_000)
        total += 1
        inFlight -= 1
        return .ok(.text("done"))
      }
      server.get["/stats"] = { _ in .ok(.text("\(total) \(mostInFlight)")) }
    }) { _, port in
      DispatchQueue.concurrentPerform(iterations: 16) { _ in
        _ = try? RawClient.get("/work", port: port)
      }
      XCTAssertEqual(try RawClient.get("/stats", port: port).bodyString, "16 1")
    }
  }

  func testTheServerDoesNotCreateThreadsForConnections() throws {
    let before = settledThreadCount()
    try serve { server, port in
      let held = try (0..<30).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 30 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      let added = processThreadCount() - before
      XCTAssertLessThanOrEqual(added, 3, "\(added) more threads for 30 connections")
      held.forEach { $0.close() }
    }
  }

  func testPerConnectionThreadsCostAThreadEach() throws {
    let before = settledThreadCount()
    try withTestServer { server, port in
      let held = try (0..<30).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 30 })
      // Connections are counted when they are accepted; their threads start a moment later.
      XCTAssertTrue(eventually { processThreadCount() - before >= 30 }, "fewer than 30 threads for 30 connections")
      held.forEach { $0.close() }
    }
  }

  // MARK: - Waiting connections do not block the others

  func testSilentConnectionsDoNotBlockOtherRequests() throws {
    try serve { _, port in
      let silent = try (0..<10).map { _ in try RawClient(port: port) }
      let begin = Date()
      XCTAssertEqual(try RawClient.get("/ping", port: port, timeout: 2).status, 200)
      XCTAssertLessThan(Date().timeIntervalSince(begin), 1)
      silent.forEach { $0.close() }
    }
  }

  func testKeepAliveConnectionsTakeTurns() throws {
    try serve { _, port in
      let first = try RawClient(port: port, timeout: 2)
      let second = try RawClient(port: port, timeout: 2)
      for round in 0..<4 {
        for (name, client) in [("first", first), ("second", second)] {
          client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
          XCTAssertEqual(client.readResponse()?.status, 200, "\(name) client, round \(round)")
        }
      }
    }
  }

  func testPipelinedRequestsAreAllAnswered() throws {
    try serve { _, port in
      let client = try RawClient(port: port, timeout: 2)
      let first = RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"])
      let second = RawClient.requestText("GET", "/ping", headers: ["Connection: close"])
      client.send(first + second)
      XCTAssertEqual(client.readResponse()?.status, 200)
      XCTAssertEqual(client.readResponse()?.status, 200)
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testAConnectionThatTheClientClosedIsNoticed() throws {
    try serve { server, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.status, 200)
      XCTAssertEqual(server.openConnections, 1)
      client.close()
      XCTAssertTrue(eventually { server.openConnections == 0 }, "the closed connection is still registered")
    }
  }

  // MARK: - Timeouts and limits

  func testSilentConnectionsAreClosedAfterTheIdleTimeout() throws {
    try serve(idle: 0.4) { server, port in
      let silent = try RawClient(port: port)
      XCTAssertTrue(silent.waitForClose(timeout: 3))
      let kept = try RawClient(port: port)
      kept.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(kept.readResponse()?.status, 200)
      XCTAssertTrue(kept.waitForClose(timeout: 3), "an idle keep-alive connection was not closed")
      XCTAssertTrue(eventually { server.openConnections == 0 })
    }
  }

  func testAStalledRequestGets408AndTheServerGoesOn() throws {
    try serve(read: 0.4) { _, port in
      let stalled = try RawClient(port: port)
      stalled.send("GET /ping HTTP/1.1\r\nHost: localhost\r\n")
      XCTAssertEqual(stalled.readResponse()?.status, 408)
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
    }
  }

  func testConnectionsBeyondTheLimitGet503() throws {
    try serve(max: 3) { server, port in
      let held = try (0..<3).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 3 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 503)
      held[0].close()
      XCTAssertTrue(eventually { server.openConnections == 2 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      held.forEach { $0.close() }
    }
  }

  func testManyIdleConnectionsAreFine() throws {
    raiseFileDescriptorLimit()
    try serve { server, port in
      let held = try (0..<100).map { _ in try RawClient(port: port) }
      XCTAssertTrue(eventually { server.openConnections == 100 })
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      held.forEach { $0.close() }
    }
  }

  // MARK: - Lifecycle

  func testStopClosesTheConnectionsAndTheServerCanBeStartedAgain() throws {
    let server = NanoHTTPServer()
    server.configuration.threading = .singleThread
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    for round in 0..<5 {
      try server.start(0)
      let port = try server.port()
      let waiting = try RawClient(port: port)
      XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200, "round \(round)")
      XCTAssertTrue(eventually { server.openConnections == 1 })
      server.stop()
      XCTAssertEqual(server.state, .stopped)
      XCTAssertTrue(waiting.waitForClose(timeout: 2), "round \(round): a connection survived stop()")
      XCTAssertEqual(server.openConnections, 0)
    }
  }

  func testAHandlerMayStopTheServer() throws {
    let server = NanoHTTPServer()
    server.configuration.threading = .singleThread
    server.get["/quit"] = { [unowned server] _ in
      server.stop()
      return .ok(.text("bye"))
    }
    try server.start(0)
    let port = try server.port()
    _ = try? RawClient.get("/quit", port: port)
    XCTAssertTrue(eventually { server.state == .stopped })
  }

  // MARK: - run()

  /// Collects what happened on the thread that called `run`.
  private final class RunThread {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var id: UInt64 = 0
    private var error: Error?

    var threadID: UInt64 {
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.id
    }

    func run(_ server: NanoHTTPServer) {
      let thread = Thread {
        self.lock.lock()
        self.id = currentThreadID()
        self.lock.unlock()
        do {
          try server.run(0)
        } catch {
          self.lock.lock()
          self.error = error
          self.lock.unlock()
        }
        self.finished.signal()
      }
      thread.start()
    }
  }

  func testRunServesOnTheCallingThreadUntilTheServerIsStopped() throws {
    let log = ThreadLog()
    let server = NanoHTTPServer()
    server.configuration.threading = .singleThread
    server.get["/ping"] = { _ in log.record(); return .ok(.text("pong")) }
    let runner = RunThread()
    runner.run(server)
    XCTAssertTrue(eventually { server.operating })
    XCTAssertEqual(try RawClient.get("/ping", port: try server.port()).status, 200)
    XCTAssertEqual(log.threads, [runner.threadID], "the request was not served by the thread that called run()")
    XCTAssertEqual(runner.finished.wait(timeout: .now() + 0.3), .timedOut, "run() returned while the server runs")
    server.stop()
    XCTAssertEqual(runner.finished.wait(timeout: .now() + 3), .success, "run() did not return after stop()")
  }

  func testRunAcceptsOnTheCallingThreadWithAThreadPerConnection() throws {
    let log = ThreadLog()
    let server = NanoHTTPServer()
    server.get["/ping"] = { _ in log.record(); return .ok(.text("pong")) }
    let runner = RunThread()
    runner.run(server)
    XCTAssertTrue(eventually { server.operating })
    XCTAssertEqual(try RawClient.get("/ping", port: try server.port()).status, 200)
    XCTAssertFalse(log.threads.contains(runner.threadID))
    XCTAssertEqual(runner.finished.wait(timeout: .now() + 0.3), .timedOut)
    server.stop()
    XCTAssertEqual(runner.finished.wait(timeout: .now() + 3), .success)
  }

  func testRunOrStartOfARunningServerDoesNothing() throws {
    try serve { server, port in
      let begin = Date()
      try server.run(0)
      try server.start(0)
      XCTAssertLessThan(Date().timeIntervalSince(begin), 1)
      XCTAssertEqual(try server.port(), port)
    }
  }

  func testRunThrowsWhenTheServerCannotListen() {
    let server = NanoHTTPServer()
    server.configuration.listenAddress = .address("203.0.113.7")
    XCTAssertThrowsError(try server.run(0))
    XCTAssertEqual(server.state, .stopped)
  }
}
