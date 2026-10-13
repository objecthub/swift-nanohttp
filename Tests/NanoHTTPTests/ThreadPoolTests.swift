//
//  ThreadPoolTests.swift
//  NanoHTTPTests
//
//  A server with a thread per connection reuses its threads: creating a thread for every connection
//  cost about 50 µs of CPU time each, which is more than serving a small request. The pool never
//  limits the number of threads (a connection can block its thread for as long as it lives).
//

import XCTest
import Darwin
@testable import NanoHTTP

private final class Counter {
  private let lock = NSLock()
  private var value = 0
  private var ids = Set<UInt64>()

  func increment() {
    self.lock.lock()
    self.value += 1
    self.lock.unlock()
  }

  func record() {
    let id = currentThreadID()
    self.lock.lock()
    self.value += 1
    self.ids.insert(id)
    self.lock.unlock()
  }

  var count: Int {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.value
  }

  var threads: Set<UInt64> {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.ids
  }
}

final class ThreadPoolTests: XCTestCase {

  func testWorkRunsOnAThreadWithTheNameAndPriorityOfThePool() {
    let pool = NanoThreadPool(name: "test pool", qos: .utility)
    defer { pool.close() }
    let done = DispatchSemaphore(value: 0)
    var name: String?
    var qos: QualityOfService?
    pool.submit {
      name = Thread.current.name
      qos = Thread.current.qualityOfService
      done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    XCTAssertEqual(name, "test pool")
    XCTAssertEqual(qos, .utility)
  }

  func testSequentialWorkReusesTheThread() {
    let pool = NanoThreadPool(name: "test pool", qos: .userInitiated)
    defer { pool.close() }
    let counter = Counter()
    for round in 0..<30 {
      pool.submit { counter.record() }
      XCTAssertTrue(eventually { counter.count == round + 1 && pool.idleThreadCount == 1 }, "round \(round)")
    }
    XCTAssertEqual(counter.threads.count, 1, "the work ran on \(counter.threads.count) threads")
    XCTAssertEqual(pool.threadCount, 1)
  }

  /// Work that blocks must not keep other work from running: there is no limit for the number of threads.
  func testBlockedWorkNeverDelaysOtherWork() {
    let pool = NanoThreadPool(name: "test pool", qos: .userInitiated)
    defer { pool.close() }
    let release = DispatchSemaphore(value: 0)
    let started = Counter()
    for _ in 0..<100 {
      pool.submit {
        started.increment()
        release.wait()
      }
    }
    XCTAssertTrue(eventually { started.count == 100 }, "only \(started.count) of 100 blocked pieces of work started")
    XCTAssertEqual(pool.threadCount, 100)
    let finished = DispatchSemaphore(value: 0)
    pool.submit { finished.signal() }
    XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
    for _ in 0..<100 { release.signal() }
  }

  func testIdleThreadsEndAfterTheirLifetime() {
    let pool = NanoThreadPool(name: "test pool", qos: .userInitiated, idleLifetime: 0.2)
    defer { pool.close() }
    let done = Counter()
    for _ in 0..<5 {
      pool.submit { usleep(50_000); done.increment() }
    }
    XCTAssertTrue(eventually { done.count == 5 })
    XCTAssertTrue(eventually(timeout: 3) { pool.threadCount == 0 }, "\(pool.threadCount) idle threads remain")
  }

  func testOnlyAFewThreadsWaitForWork() {
    let pool = NanoThreadPool(name: "test pool", qos: .userInitiated, idleLifetime: 30, maxIdleThreads: 2)
    defer { pool.close() }
    let release = DispatchSemaphore(value: 0)
    let started = Counter()
    for _ in 0..<8 {
      pool.submit { started.increment(); release.wait() }
    }
    XCTAssertTrue(eventually { started.count == 8 })
    for _ in 0..<8 { release.signal() }
    XCTAssertTrue(eventually { pool.threadCount <= 2 }, "\(pool.threadCount) threads wait for work")
    XCTAssertLessThanOrEqual(pool.idleThreadCount, 2)
  }

  func testCloseEndsTheWaitingThreadsAtOnceAndRefusesWork() {
    let pool = NanoThreadPool(name: "test pool", qos: .userInitiated, idleLifetime: 60)
    let done = Counter()
    for _ in 0..<4 {
      pool.submit { usleep(20_000); done.increment() }
    }
    XCTAssertTrue(eventually { done.count == 4 && pool.idleThreadCount > 0 })
    pool.close()
    XCTAssertTrue(eventually(timeout: 2) { pool.threadCount == 0 }, "\(pool.threadCount) threads outlive close()")
    XCTAssertFalse(pool.submit { done.increment() })
    usleep(100_000)
    XCTAssertEqual(done.count, 4)
  }

  func testWorkThatIsRunningWhenThePoolIsClosedFinishes() {
    let pool = NanoThreadPool(name: "test pool", qos: .userInitiated)
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    pool.submit { started.signal(); release.wait(); done.signal() }
    XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
    pool.close()
    release.signal()
    XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    XCTAssertTrue(eventually { pool.threadCount == 0 })
  }

  func testEveryPieceOfWorkRunsExactlyOnce() {
    let pool = NanoThreadPool(name: "test pool", qos: .userInitiated, idleLifetime: 0.05)
    defer { pool.close() }
    let counter = Counter()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      for index in 0..<500 {
        pool.submit { counter.increment() }
        if index % 50 == 0 {
          usleep(60_000) // let threads time out now and then
        }
      }
    }
    XCTAssertTrue(eventually(timeout: 10) { counter.count == 4000 }, "\(counter.count) of 4000 pieces of work ran")
    usleep(200_000)
    XCTAssertEqual(counter.count, 4000, "some work ran twice")
  }
}

// MARK: - In a server

final class ConnectionThreadReuseTests: XCTestCase {

  func testSequentialConnectionsAreServedByFewThreads() throws {
    let threads = Counter()
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in threads.record(); return .ok(.text("pong")) }
    }) { _, port in
      for _ in 0..<60 {
        XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
      }
      XCTAssertEqual(threads.count, 60)
      XCTAssertLessThanOrEqual(threads.threads.count, 4, "\(threads.threads.count) threads for 60 sequential connections")
    }
  }

  func testStoppingTheServerEndsTheThreadsOfItsConnections() throws {
    let before = settledThreadCount()
    let server = NanoHTTPServer()
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    try server.start(0)
    let port = try server.port()
    // Twelve connections that stay open at the same time: twelve threads.
    let clients = try (0..<12).map { _ in try RawClient(port: port) }
    for client in clients {
      client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.status, 200)
    }
    XCTAssertGreaterThanOrEqual(processThreadCount() - before, 12)
    server.stop()
    XCTAssertTrue(eventually(timeout: 3) { processThreadCount() <= before + 2 },
                  "\(processThreadCount() - before) threads are left after stop()")
  }

  func testConnectionsAreServedConcurrentlyBeyondTheNumberOfIdleThreads() throws {
    let release = DispatchSemaphore(value: 0)
    let started = Counter()
    try withTestServer(configure: { server in
      server.get["/block"] = { _ in
        started.increment()
        release.wait()
        return .ok(.text("done"))
      }
    }) { _, port in
      let clients = try (0..<40).map { _ in try RawClient(port: port, timeout: 10) }
      clients.forEach { $0.send(RawClient.requestText("GET", "/block", headers: ["Connection: close"])) }
      XCTAssertTrue(eventually { started.count == 40 }, "only \(started.count) of 40 blocked requests started")
      for _ in 0..<40 { release.signal() }
      for client in clients {
        XCTAssertEqual(client.readResponse()?.status, 200)
      }
    }
  }
}
