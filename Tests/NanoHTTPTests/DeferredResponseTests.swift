//
//  DeferredResponseTests.swift
//  NanoHTTPTests
//
//  A server whose `handle(connection:)` hands requests to other threads (a worker pool, a queue) answers them
//  later, from those threads, with `NanoHTTPDeferredResponse`. The tests run with threads per connection and with
//  one thread: the answer is written by the server, the caller never waits for the client, nothing times out while
//  an answer is pending, and the connection serves the next request afterwards.
//

import XCTest
@testable import NanoHTTP

private typealias Threading = NanoHTTPServerIO.Configuration.Threading

private let modes: [Threading] = [.perConnection, .singleThread]

/// A value that several threads read and write.
private final class Locked<T> {
  private let lock = NSLock()
  private var value: T

  init(_ value: T) {
    self.value = value
  }

  func with<R>(_ body: (inout T) -> R) -> R {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    return body(&self.value)
  }

  var current: T {
    return self.with { $0 }
  }
}

/// A server that hands every request to `strategy` instead of answering it.
private final class DeferringServer: NanoHTTPServer {
  var strategy: (NanoHTTPConnection, NanoHTTPDeferredResponse) -> Void = { _, _ in }
  let handled = Locked(0)

  override func handle(connection: NanoHTTPConnection) {
    self.handled.with { $0 += 1 }
    let pending = connection.deferResponse()
    self.strategy(connection, pending)
  }
}

/// Runs `body` with a started server for the threading mode.
private func serve(_ threading: Threading,
                   configure: (DeferringServer) -> Void = { _ in },
                   strategy: @escaping (NanoHTTPConnection, NanoHTTPDeferredResponse) -> Void,
                   _ body: (DeferringServer, Int) throws -> Void) throws {
  let server = DeferringServer()
  server.configuration.threading = threading
  server.get["/ping"] = { _ in .ok(.text("pong")) }
  server.get["/slow"] = { _ in .ok(.text("slow")) }
  server.get["/echo/:n"] = { request in .ok(.text(request.params["n"] ?? "?")) }
  server.get["/big"] = { _ in .ok(.data(Data(repeating: 0x61, count: 8 * 1024 * 1024))) }
  configure(server)
  server.strategy = strategy
  try server.start(0)
  defer {
    server.stop()
  }
  try body(server, try server.port())
}

/// Answers from another thread after `delay` seconds, with what the routes say.
private func answerLater(_ delay: TimeInterval,
                         _ connection: NanoHTTPConnection,
                         _ pending: NanoHTTPDeferredResponse) {
  let response = connection.response()
  DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
    pending.send(response)
  }
}

private func text(_ response: RawResponse?) -> String {
  return String(decoding: response?.body ?? [], as: UTF8.self)
}

private let keepAlive = ["Connection: keep-alive"]

final class DeferredResponseTests: XCTestCase {

  func testAnAnswerFromAnotherThreadReachesTheClient() throws {
    for threading in modes {
      let begin = Date()
      try serve(threading, strategy: { answerLater(0.3, $0, $1) }) { _, port in
        let response = try RawClient.get("/ping", port: port)
        XCTAssertEqual(response.status, 200, "\(threading)")
        XCTAssertEqual(text(response), "pong", "\(threading)")
      }
      XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(begin), 0.3, "\(threading): it was answered later")
    }
  }

  func testTheAnswerMayBeSentBeforeHandleReturns() throws {
    for threading in modes {
      try serve(threading, strategy: { connection, pending in pending.send(connection.response()) }) { server, port in
        let client = try RawClient(port: port)
        for _ in 0..<3 {
          client.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
          XCTAssertEqual(text(client.readResponse()), "pong", "\(threading)")
        }
        XCTAssertEqual(server.handled.current, 3, "\(threading)")
      }
    }
  }

  func testSendReturnsAtOnceAndDoesNotWaitForTheNextRequest() throws {
    for threading in modes {
      let durations = Locked([TimeInterval]())
      try serve(threading, strategy: { connection, pending in
        let response = connection.response()
        DispatchQueue.global().async {
          let begin = Date()
          pending.send(response)
          durations.with { $0.append(Date().timeIntervalSince(begin)) }
        }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        XCTAssertEqual(text(client.readResponse()), "pong", "\(threading)")
        // The client stays silent: a send that waited for its next request would not have returned yet.
        XCTAssertTrue(eventually { !durations.current.isEmpty }, "\(threading)")
        XCTAssertLessThan(durations.current.first ?? 99, 0.5, "\(threading)")
      }
    }
  }

  func testTheConnectionServesTheNextRequestAfterTheAnswer() throws {
    for threading in modes {
      try serve(threading, strategy: { answerLater(0.05, $0, $1) }) { server, port in
        let client = try RawClient(port: port)
        for index in 1...3 {
          client.send(RawClient.requestText("GET", "/echo/\(index)", headers: keepAlive))
          XCTAssertEqual(text(client.readResponse()), "\(index)", "\(threading)")
        }
        XCTAssertEqual(server.handled.current, 3, "\(threading)")
        XCTAssertEqual(server.openConnections, 1, "\(threading): one connection served all three")
      }
    }
  }

  func testNothingTimesOutWhileAnAnswerIsPendingAndTheIdleTimeoutAppliesAfterwards() throws {
    for threading in modes {
      try serve(threading,
                configure: { $0.configuration.idleTimeout = 0.3 },
                strategy: { answerLater(1.0, $0, $1) }) { _, port in
        let client = try RawClient(port: port, timeout: 5)
        client.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        let response = client.readResponse()
        XCTAssertEqual(response?.status, 200, "\(threading): the connection was not closed while it waited")
        XCTAssertEqual(text(response), "pong", "\(threading)")
        XCTAssertTrue(client.waitForClose(timeout: 3), "\(threading): idle again, so closed after the idle timeout")
      }
    }
  }

  func testATokenThatIsDroppedWithoutAnAnswerClosesTheConnection() throws {
    for threading in modes {
      let logger = CapturingLogger()
      try serve(threading,
                configure: { $0.configuration.logger = logger },
                strategy: { _, _ in }) { server, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        XCTAssertTrue(client.waitForClose(timeout: 3), "\(threading)")
        XCTAssertTrue(logger.waitFor("without an answer", level: .warning), "\(threading): \(logger.messages)")
        XCTAssertTrue(eventually { server.openConnections == 0 }, "\(threading)")
      }
    }
  }

  func testDontKeepAliveEndsTheConnectionAfterTheAnswer() throws {
    for threading in modes {
      try serve(threading, strategy: { connection, pending in
        let response = connection.response()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
          pending.send(response, dontKeepAlive: true)
        }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        let response = client.readResponse()
        XCTAssertEqual(text(response), "pong", "\(threading)")
        XCTAssertEqual(response?.header("Connection"), "close", "\(threading)")
        XCTAssertTrue(client.waitForClose(timeout: 3), "\(threading)")
      }
    }
  }

  func testAnAnswerIsSentOnlyOnce() throws {
    for threading in modes {
      let results = Locked([Bool]())
      try serve(threading, strategy: { connection, pending in
        let response = connection.response()
        DispatchQueue.global().async {
          let first = pending.send(response)
          let second = pending.send(response)
          let third = pending.send(response, dontKeepAlive: true)
          results.with { $0 = [first, second, third] }
        }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        XCTAssertEqual(text(client.readResponse()), "pong", "\(threading)")
        XCTAssertTrue(eventually { !results.current.isEmpty }, "\(threading)")
        XCTAssertEqual(results.current, [true, false, false], "\(threading)")
        XCTAssertEqual(client.readToEnd(timeout: 0.3), [], "\(threading): nothing more was sent, the connection stays open")
      }
    }
  }

  func testStoppingTheServerEndsThePendingConnections() throws {
    for threading in modes {
      let tokens = Locked([NanoHTTPDeferredResponse]())
      try serve(threading, strategy: { _, pending in tokens.with { $0.append(pending) } }) { server, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        XCTAssertTrue(eventually { tokens.current.count == 1 }, "\(threading)")
        server.stop()
        XCTAssertTrue(client.waitForClose(timeout: 3), "\(threading)")
        // A late answer does nothing, and does not crash.
        tokens.current.first?.send(.ok(.text("late")))
        XCTAssertEqual(server.openConnections, 0, "\(threading)")
      }
    }
  }

  func testARequestThatIsPipelinedWaitsForTheAnswerOfTheFirst() throws {
    for threading in modes {
      let events = Locked([String]())
      try serve(threading, strategy: { connection, pending in
        let path = connection.request.path
        events.with { $0.append("handle \(path)") }
        let response = connection.response()
        DispatchQueue.global().asyncAfter(deadline: .now() + (path == "/slow" ? 0.4 : 0)) {
          events.with { $0.append("send \(path)") }
          pending.send(response)
        }
      }) { _, port in
        let client = try RawClient(port: port, timeout: 5)
        client.send(RawClient.requestText("GET", "/slow", headers: keepAlive) +
                    RawClient.requestText("GET", "/ping", headers: keepAlive))
        XCTAssertEqual(text(client.readResponse()), "slow", "\(threading)")
        XCTAssertEqual(text(client.readResponse()), "pong", "\(threading)")
        XCTAssertEqual(events.current, ["handle /slow", "send /slow", "handle /ping", "send /ping"], "\(threading)")
      }
    }
  }

  func testOtherConnectionsAreServedWhileAnAnswerIsPending() throws {
    for threading in modes {
      try serve(threading, strategy: { connection, pending in
        answerLater(connection.request.path == "/slow" ? 1.5 : 0, connection, pending)
      }) { _, port in
        let slow = try RawClient(port: port, timeout: 5)
        slow.send(RawClient.requestText("GET", "/slow", headers: keepAlive))
        let begin = Date()
        for _ in 0..<5 {
          XCTAssertEqual(text(try RawClient.get("/ping", port: port, timeout: 1)), "pong", "\(threading)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(begin), 1.0, "\(threading): the server did not wait for the slow answer")
        XCTAssertEqual(text(slow.readResponse()), "slow", "\(threading)")
      }
    }
  }

  func testManyPendingAnswersFromSeveralThreads() throws {
    for threading in modes {
      let queues = (0..<4).map { DispatchQueue(label: "answers \($0)") }
      try serve(threading, strategy: { connection, pending in
        let response = connection.response()
        let n = Int(connection.request.params["n"] ?? "0") ?? 0
        queues[n % queues.count].asyncAfter(deadline: .now() + Double(n % 7) * 0.03) {
          pending.send(response)
        }
      }) { _, port in
        let clients = try (0..<30).map { _ in try RawClient(port: port, timeout: 10) }
        for (index, client) in clients.enumerated() {
          client.send(RawClient.requestText("GET", "/echo/\(index)", headers: keepAlive))
        }
        for (index, client) in clients.enumerated().reversed() {
          XCTAssertEqual(text(client.readResponse()), "\(index)", "\(threading)")
        }
        // The second round, on the same connections.
        for (index, client) in clients.enumerated() {
          client.send(RawClient.requestText("GET", "/echo/\(index + 100)", headers: keepAlive))
        }
        for (index, client) in clients.enumerated() {
          XCTAssertEqual(text(client.readResponse()), "\(index + 100)", "\(threading)")
        }
      }
    }
  }

  func testPendingConnectionsCountForTheConnectionLimit() throws {
    for threading in modes {
      let tokens = Locked([(NanoHTTPConnection, NanoHTTPDeferredResponse)]())
      try serve(threading,
                configure: { $0.configuration.maxConnections = 2 },
                strategy: { connection, pending in tokens.with { $0.append((connection, pending)) } }) { server, port in
        let first = try RawClient(port: port)
        let second = try RawClient(port: port)
        first.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        second.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        XCTAssertTrue(eventually { tokens.current.count == 2 }, "\(threading)")
        XCTAssertEqual(try RawClient.get("/ping", port: port).status, 503, "\(threading)")
        for (connection, pending) in tokens.current {
          pending.send(connection.response())
        }
        XCTAssertEqual(text(first.readResponse()), "pong", "\(threading)")
        XCTAssertEqual(text(second.readResponse()), "pong", "\(threading)")
      }
    }
  }

  func testTheAnswerToAHeadRequestHasNoBody() throws {
    for threading in modes {
      try serve(threading, strategy: { answerLater(0.1, $0, $1) }) { _, port in
        let response = try RawClient.request("HEAD", "/ping", port: port)
        XCTAssertEqual(response.status, 200, "\(threading)")
        XCTAssertEqual(response.header("Content-Length"), "4", "\(threading)")
        XCTAssertEqual(response.body, [], "\(threading)")
      }
    }
  }

  func testAClientThatDoesNotReadDoesNotHoldUpTheThreadThatAnswers() throws {
    for threading in modes {
      let logger = CapturingLogger()
      let durations = Locked([TimeInterval]())
      try serve(threading,
                configure: {
                  $0.configuration.logger = logger
                  $0.configuration.writeTimeout = 0.5
                },
                strategy: { connection, pending in
        let response = connection.response()
        DispatchQueue.global().async {
          let begin = Date()
          pending.send(response)
          durations.with { $0.append(Date().timeIntervalSince(begin)) }
        }
      }) { _, port in
        // A response of 8 MB to a client that never reads: the write fails after the write timeout.
        let client = try RawClient(port: port, receiveBuffer: 4096)
        client.send(RawClient.requestText("GET", "/big", headers: keepAlive))
        XCTAssertTrue(eventually { !durations.current.isEmpty }, "\(threading)")
        XCTAssertLessThan(durations.current.first ?? 99, 0.3, "\(threading): the answering thread did not wait for the client")
        XCTAssertTrue(logger.waitFor("Failed to send response", level: .info, timeout: 10), "\(threading): \(logger.messages)")
        client.close()
      }
    }
  }

  /// Answers every line with the same line in upper case, until it receives "bye".
  private final class ShoutingSession: NanoSocketSession {
    private var socket: NanoSocket?

    func start(socket: NanoSocket, drainTimeout: TimeInterval, logger: NanoHTTPLogger) {
      self.socket = socket
      try? socket.writeUTF8("HELLO\n")
    }

    func receive() -> Bool {
      guard let socket, let line = try? socket.readLine() else {
        return false
      }
      try? socket.writeUTF8(line.uppercased() + "\n")
      return line != "bye"
    }

    func end() {
      self.socket = nil
    }
  }

  /// One line that ends with a line feed (`RawClient.readLine` waits for a carriage return as well).
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
  
  func testTheDeferredAnswerCanSwitchTheConnectionToASession() throws {
    for threading in modes {
      try serve(threading, strategy: { _, pending in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
          pending.send(.switchProtocols(["Upgrade": "shout", "Connection": "Upgrade"], session: ShoutingSession()))
        }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/shout", headers: ["Upgrade: shout", "Connection: Upgrade"]))
        XCTAssertEqual(client.readResponse()?.status, 101, "\(threading)")
        XCTAssertEqual(line(client), "HELLO", "\(threading)")
        client.send("abc\n")
        XCTAssertEqual(line(client), "ABC", "\(threading)")
        client.send("bye\n")
        XCTAssertEqual(line(client), "BYE", "\(threading)")
      }
    }
  }

  func testAnAnswerFromTheRequestHandlerPathStillWorksWithoutDeferring() throws {
    // A server that does not defer is not affected by any of this.
    for threading in modes {
      let server = NanoHTTPServer()
      server.configuration.threading = threading
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      try server.start(0)
      defer {
        server.stop()
      }
      let client = try RawClient(port: try server.port())
      for _ in 0..<3 {
        client.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
        XCTAssertEqual(text(client.readResponse()), "pong", "\(threading)")
      }
    }
  }
}


// MARK: - The example of the documentation: a worker pool behind one network thread

// The class is the example of the article "Middleware and Extending" (``ExampleWorkerPoolServer``), as it is
// written there; these tests run it.
private final class WorkerPoolServer: NanoHTTPServer {
  private struct Job {
    let connection: NanoHTTPConnection
    let pending: NanoHTTPDeferredResponse
  }

  private let workerCount: Int
  private let capacity: Int
  private let condition = NSCondition()
  private var queue = [Job]()                 // guarded by `condition`, like `run`
  private var run = 0                         // the number of the current run of the server; 0 if none
  private var runs = 0

  init(workers: Int = 3, capacity: Int = 100) {
    self.workerCount = workers
    self.capacity = capacity
    var configuration = Configuration()
    configuration.threading = .singleThread
    super.init(configuration: configuration)
  }

  /// Runs on the one thread of the server (the calling thread of `run`), and returns when the server stops.
  override func listen() {
    self.condition.lock()
    self.runs += 1
    let run = self.runs
    self.run = run
    self.condition.unlock()
    for index in 0..<self.workerCount {
      let worker = Thread { [self] in self.work(run) }
      worker.name = "Test worker \(index)"
      worker.start()
    }
    super.listen()
    // The server has stopped: the workers of this run end, and the requests that nobody has taken are given up. (A
    // server that is started again right away has begun its next run already, and the queue is that run's.)
    var abandoned = [Job]()
    self.condition.lock()
    if self.run == run {
      self.run = 0
      abandoned = self.queue
      self.queue.removeAll()
    }
    self.condition.broadcast()
    self.condition.unlock()
    for job in abandoned {
      job.pending.close()
    }
  }

  /// Called on the one thread for every request that arrives, also for the next request of a kept-alive connection.
  override func handle(connection: NanoHTTPConnection) {
    self.condition.lock()
    let accepted = self.queue.count < self.capacity
    if accepted {
      self.queue.append(Job(connection: connection, pending: connection.deferResponse()))
      self.condition.signal()
    }
    self.condition.unlock()
    if !accepted {
      // Too many requests are waiting: refuse this one at once, and close its connection.
      let busy = NanoHTTPResponse(statusCode: 503, headers: ["Retry-After": "1"], body: .text("busy"))
      _ = connection.send(busy, dontKeepAlive: true)
    }
  }

  private func work(_ run: Int) {
    while let job = self.nextJob(run) {
      // Runs the middleware and the route, and turns errors into responses as usual. `send` returns at once:
      // the one thread of the server writes the response.
      job.pending.send(job.connection.response())
    }
  }

  private func nextJob(_ run: Int) -> Job? {
    self.condition.lock()
    defer {
      self.condition.unlock()
    }
    while self.queue.isEmpty && self.run == run {
      self.condition.wait()
    }
    return self.run == run ? self.queue.removeFirst() : nil
  }
}

final class WorkerPoolExampleTests: XCTestCase {
  
  private func serve(workers: Int = 3,
                      capacity: Int = 100,
                      routes: (WorkerPoolServer) -> Void,
                      _ body: (WorkerPoolServer, Int) throws -> Void) throws {
    let server = WorkerPoolServer(workers: workers, capacity: capacity)
    routes(server)
    try server.start(0)
    defer {
      server.stop()
    }
    try body(server, try server.port())
  }
  
  func testTheHandlersRunOnTheWorkersAtTheSameTime() throws {
    let threads = Locked(Set<String>())
    try serve(routes: { server in
      server.get["/work/:n"] = { request in
        threads.with { _ = $0.insert(Thread.current.name ?? "?") }
        Thread.sleep(forTimeInterval: 0.3)
        return .ok(.text(request.params["n"] ?? "?"))
      }
    }) { _, port in
      let clients = try (0..<9).map { _ in try RawClient(port: port, timeout: 10) }
      let begin = Date()
      for (index, client) in clients.enumerated() {
        client.send(RawClient.requestText("GET", "/work/\(index)", headers: keepAlive))
      }
      for (index, client) in clients.enumerated() {
        XCTAssertEqual(text(client.readResponse()), "\(index)")
      }
      XCTAssertLessThan(Date().timeIntervalSince(begin), 2.0, "9 requests of 0.3 s on 3 workers: about 1 s, not 2.7 s")
      XCTAssertTrue(threads.current.allSatisfy { $0.hasPrefix("Test worker") }, "\(threads.current)")
      XCTAssertGreaterThan(threads.current.count, 1)
    }
  }
  
  func testAConnectionThatIsKeptAliveSendsItsNextRequestsThroughTheQueueToo() throws {
    try serve(routes: { server in
      server.get["/echo/:n"] = { request in .ok(.text(request.params["n"] ?? "?")) }
    }) { _, port in
      let client = try RawClient(port: port)
      for index in 1...5 {
        client.send(RawClient.requestText("GET", "/echo/\(index)", headers: keepAlive))
        XCTAssertEqual(text(client.readResponse()), "\(index)")
      }
    }
  }
  
  func testARequestThatFindsTheQueueFullIsRefusedWith503() throws {
    let started = Locked(0)
    try serve(workers: 1, capacity: 1, routes: { server in
      server.get["/slow/:n"] = { request in
        started.with { $0 += 1 }
        Thread.sleep(forTimeInterval: 1.0)
        return .ok(.text(request.params["n"] ?? "?"))
      }
    }) { _, port in
      let first = try RawClient(port: port, timeout: 10)
      first.send(RawClient.requestText("GET", "/slow/1", headers: keepAlive))
      XCTAssertTrue(eventually { started.current == 1 }, "the worker has taken the first request")
      let second = try RawClient(port: port, timeout: 10)
      second.send(RawClient.requestText("GET", "/slow/2", headers: keepAlive))
      usleep(300_000) // it waits in the queue
      let refused = try RawClient(port: port)
      refused.send(RawClient.requestText("GET", "/slow/3", headers: keepAlive))
      let response = refused.readResponse()
      XCTAssertEqual(response?.status, 503)
      XCTAssertEqual(response?.header("Retry-After"), "1")
      XCTAssertTrue(refused.waitForClose(timeout: 2), "the connection of a refused request is closed")
      XCTAssertEqual(text(first.readResponse()), "1")
      XCTAssertEqual(text(second.readResponse()), "2")
    }
  }
  
  func testTheOtherConnectionsAreServedWhileAllWorkersAreBusy() throws {
    try serve(workers: 1, capacity: 10, routes: { server in
      server.get["/slow"] = { _ in
        Thread.sleep(forTimeInterval: 0.8)
        return .ok(.text("slow"))
      }
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }) { server, port in
      let busy = try RawClient(port: port, timeout: 10)
      busy.send(RawClient.requestText("GET", "/slow", headers: keepAlive))
      usleep(100_000)
      // The network thread is not held up: a connection is accepted, and a request that has to wait for the worker is
      // taken (its answer comes after the slow one).
      let waiting = try RawClient(port: port, timeout: 10)
      waiting.send(RawClient.requestText("GET", "/ping", headers: keepAlive))
      XCTAssertTrue(eventually { server.openConnections == 2 })
      XCTAssertEqual(text(busy.readResponse()), "slow")
      XCTAssertEqual(text(waiting.readResponse()), "pong")
    }
  }
  
  func testTheServerCanBeStoppedAndStartedAgain() throws {
    let server = WorkerPoolServer(workers: 2, capacity: 10)
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    for _ in 0..<3 {
      try server.start(0)
      XCTAssertEqual(text(try RawClient.get("/ping", port: try server.port())), "pong")
      server.stop()
      XCTAssertTrue(eventually { !server.operating })
    }
  }
}
