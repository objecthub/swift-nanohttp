//
//  NanoProcessTests.swift
//  NanoHTTPTests
//
//  Reacting to signals (finding S8): the callbacks of `NanoProcess.watchSignals` run on a queue of their own and not
//  inside the signal handler of the system, so they may take locks, allocate memory and stop a server; registrations
//  are independent of each other; the list of callbacks can change while signals arrive. The tests use `SIGUSR1` and
//  `SIGUSR2`: a process that is told to terminate is not what a test wants.
//

import XCTest
@testable import NanoHTTP

private final class Recorder {
  private let lock = NSLock()
  private var entries = [String]()

  func add(_ entry: String) {
    self.lock.lock()
    self.entries.append(entry)
    self.lock.unlock()
  }

  var current: [String] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.entries
  }
}

final class NanoProcessTests: XCTestCase {

  private var registrations = [Int]()

  override func tearDown() {
    self.registrations.forEach { NanoProcess.unwatch($0) }
    self.registrations.removeAll()
    super.tearDown()
  }

  private func watch(_ signals: [Int32], _ callback: @escaping (Int32) -> Void) {
    self.registrations.append(NanoProcess.watch(signals, callback))
  }

  /// What the process does with the signal: `0` is the default action, `1` ignoring it, anything else a handler.
  private func disposition(of signum: Int32) -> Int {
    var action = sigaction()
    sigaction(signum, nil, &action)
    return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
  }

  func testTheTerminationSignalsAreTheOnesThatCanBeCaught() {
    XCTAssertEqual(Set(NanoProcess.terminationSignals), [SIGTERM, SIGHUP, SIGINT])
    XCTAssertFalse(NanoProcess.terminationSignals.contains(SIGSTOP), "nobody can catch SIGSTOP")
  }

  func testACallbackReceivesTheSignal() {
    let received = expectation(description: "the signal")
    let numbers = Recorder()
    self.watch([SIGUSR1]) { signum in
      numbers.add("\(signum)")
      received.fulfill()
    }
    XCTAssertEqual(kill(getpid(), SIGUSR1), 0)
    wait(for: [received], timeout: 5)
    XCTAssertEqual(numbers.current, ["\(SIGUSR1)"])
  }

  func testTheCallbackDoesNotRunOnTheThreadThatWasInterrupted() {
    let caller = Thread.current
    let ran = expectation(description: "the callback")
    let place = Recorder()
    self.watch([SIGUSR1]) { _ in
      place.add(Thread.current == caller ? "same thread" : "other thread")
      ran.fulfill()
    }
    XCTAssertEqual(kill(getpid(), SIGUSR1), 0)
    wait(for: [ran], timeout: 5)
    XCTAssertEqual(place.current, ["other thread"])
  }

  func testACallbackMayTakeALockThatTheInterruptedThreadHolds() {
    // Inside a signal handler on that thread, this would be a deadlock; and the code of a handler may not take locks.
    let lock = NSLock()
    let entered = DispatchSemaphore(value: 0)
    let finished = expectation(description: "the callback has the lock")
    self.watch([SIGUSR1]) { _ in
      entered.signal()
      lock.lock()
      lock.unlock()
      finished.fulfill()
    }
    lock.lock()
    XCTAssertEqual(kill(getpid(), SIGUSR1), 0)
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the callback ran while this thread held the lock")
    lock.unlock()
    wait(for: [finished], timeout: 5)
  }

  func testRegistrationsAreCalledInOrderAndOnlyForTheirSignals() {
    let order = Recorder()
    let first = expectation(description: "SIGUSR1 reached A and B")
    first.expectedFulfillmentCount = 2
    let second = expectation(description: "SIGUSR2 reached B and C")
    second.expectedFulfillmentCount = 2
    self.watch([SIGUSR1]) { _ in                 // A
      order.add("A")
      first.fulfill()
    }
    self.watch([SIGUSR1, SIGUSR2]) { signum in   // B
      if signum == SIGUSR1 {
        order.add("B1")
        first.fulfill()
      } else {
        order.add("B2")
        second.fulfill()
      }
    }
    self.watch([SIGUSR2]) { _ in                 // C
      order.add("C")
      second.fulfill()
    }
    XCTAssertEqual(kill(getpid(), SIGUSR1), 0)
    wait(for: [first], timeout: 5)
    XCTAssertEqual(order.current, ["A", "B1"], "A does not hear SIGUSR2, C does not hear SIGUSR1")
    XCTAssertEqual(kill(getpid(), SIGUSR2), 0)
    wait(for: [second], timeout: 5)
    XCTAssertEqual(order.current, ["A", "B1", "B2", "C"])
  }
  
  func testACallbackMayRegisterAnotherOne() {
    let nested = expectation(description: "the second callback")
    self.watch([SIGUSR1]) { [weak self] _ in
      self?.watch([SIGUSR2]) { _ in nested.fulfill() }
      XCTAssertEqual(kill(getpid(), SIGUSR2), 0)
    }
    XCTAssertEqual(kill(getpid(), SIGUSR1), 0)
    wait(for: [nested], timeout: 5)
  }

  func testTheSignalIsIgnoredWhileItIsWatchedAndIsTreatedAsBeforeAfterwards() {
    let before = self.disposition(of: SIGUSR2)
    let id = NanoProcess.watch([SIGUSR2]) { _ in }
    XCTAssertEqual(self.disposition(of: SIGUSR2), 1, "the dispatch source gets the signal, not the default action")
    let other = NanoProcess.watch([SIGUSR2]) { _ in }
    NanoProcess.unwatch(id)
    XCTAssertEqual(self.disposition(of: SIGUSR2), 1, "somebody still watches it")
    NanoProcess.unwatch(other)
    XCTAssertEqual(self.disposition(of: SIGUSR2), before, "nobody does")
  }

  func testRegistrationsCanChangeWhileSignalsArrive() {
    let count = Recorder()
    self.watch([SIGUSR1]) { _ in count.add("x") }
    let churn = DispatchGroup()
    for _ in 0..<4 {
      DispatchQueue.global().async(group: churn) {
        for _ in 0..<100 {
          let id = NanoProcess.watch([SIGUSR1, SIGUSR2]) { _ in }
          NanoProcess.unwatch(id)
        }
      }
    }
    for _ in 0..<200 {
      kill(getpid(), SIGUSR1)
      usleep(500)
    }
    XCTAssertEqual(churn.wait(timeout: .now() + 20), .success)
    XCTAssertTrue(eventually { !count.current.isEmpty }, "signals were delivered")
  }

  func testStoppingAServerFromACallbackEndsRun() throws {
    let server = NanoHTTPServer()
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    self.watch([SIGUSR1]) { _ in server.stop() }
    let ended = expectation(description: "run returned")
    let thread = Thread {
      try? server.run(0)
      ended.fulfill()
    }
    thread.start()
    XCTAssertTrue(eventually { server.operating })
    XCTAssertEqual(try RawClient.get("/ping", port: try server.port()).status, 200)
    XCTAssertEqual(kill(getpid(), SIGUSR1), 0)
    wait(for: [ended], timeout: 5)
    XCTAssertFalse(server.operating)
  }
}
