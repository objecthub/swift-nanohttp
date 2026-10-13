//
//  NanoThreadPool.swift
//  NanoHTTP
//
//  Copyright © 2026 Matthias Zenger. All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  * Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
//
//  * Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
//  * Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software without
//    specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
//  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
//  ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import Foundation

/// Runs pieces of work on threads that are reused.
///
/// The server serves every connection on a thread of its own. Creating a thread costs far more than
/// handing work to one that is waiting, and most connections last only for one request, so a thread that
/// has finished its connection waits for the next one for a while before it ends. A new thread is created
/// only if no waiting thread is available, so work never waits for another piece of work to finish (a
/// connection can block its thread for as long as it lives, and there can be many of them): this is no
/// limit on the number of threads, unlike the dispatch queues, which stop starting work when too many
/// of their threads are blocked.
final class NanoThreadPool {
  private let name: String
  private let qos: QualityOfService
  private let idleLifetime: TimeInterval
  private let maxIdleThreads: Int
  
  /// Guards everything below; the threads wait on it for work.
  private let condition = NSCondition()
  /// Work that no thread has taken yet.
  private var pending = [() -> Void]()
  private var pendingHead = 0
  /// The number of threads that wait for work.
  private var idle = 0
  /// The number of threads that exist (running work, or waiting).
  private var threads = 0
  private var closed = false
  
  /// - Parameters:
  ///   - name: The name of the threads.
  ///   - qos: Their quality of service.
  ///   - idleLifetime: How long a thread waits for work before it ends, in seconds.
  ///   - maxIdleThreads: How many threads at most wait for work; others end when they have nothing to do.
  init(name: String, qos: QualityOfService, idleLifetime: TimeInterval = 10, maxIdleThreads: Int = 32) {
    self.name = name
    self.qos = qos
    self.idleLifetime = idleLifetime
    self.maxIdleThreads = maxIdleThreads
  }
  
  /// The number of threads that exist right now.
  var threadCount: Int {
    self.condition.lock()
    defer {
      self.condition.unlock()
    }
    return self.threads
  }
  
  /// The number of threads that wait for work.
  var idleThreadCount: Int {
    self.condition.lock()
    defer {
      self.condition.unlock()
    }
    return self.idle
  }
  
  /// Runs `work` on a waiting thread, or on a new thread if all threads are busy. Work that is submitted
  /// after `close()` is not run; this returns `false` then.
  @discardableResult
  func submit(_ work: @escaping () -> Void) -> Bool {
    self.condition.lock()
    if self.closed {
      self.condition.unlock()
      return false
    }
    self.pending.append(work)
    // Threads that have been woken up have not taken their work yet, and still count as waiting.
    let needsThread = self.pending.count - self.pendingHead > self.idle
    if needsThread {
      self.threads += 1
    }
    self.condition.unlock()
    if !needsThread {
      // After unlocking: a thread that is woken up while this thread still holds the lock would
      // block on the lock at once, and has to be woken a second time.
      self.condition.signal()
    }
    if needsThread {
      let thread = Thread { [self] in
        self.serve()
      }
      thread.name = self.name
      thread.qualityOfService = self.qos
      thread.start()
    }
    return true
  }
  
  /// Ends the waiting threads at once and the others when their work is done. Work that has not been
  /// taken by a thread is dropped.
  func close() {
    self.condition.lock()
    self.closed = true
    self.pending.removeAll()
    self.pendingHead = 0
    self.condition.broadcast()
    self.condition.unlock()
  }
  
  /// The loop of a thread: take work, run it, and wait for more.
  private func serve() {
    self.condition.lock()
    while true {
      if self.pendingHead < self.pending.count {
        let work = self.pending[self.pendingHead]
        self.pendingHead += 1
        if self.pendingHead == self.pending.count {
          self.pending.removeAll(keepingCapacity: true)
          self.pendingHead = 0
        }
        self.condition.unlock()
        work()
        self.condition.lock()
        continue
      }
      if self.closed || self.idle >= self.maxIdleThreads {
        break
      }
      self.idle += 1
      let woken = self.condition.wait(until: Date(timeIntervalSinceNow: self.idleLifetime))
      self.idle -= 1
      if !woken && self.pendingHead >= self.pending.count {
        break // nothing came for a long time
      }
    }
    self.threads -= 1
    self.condition.unlock()
  }
}
