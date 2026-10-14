//
//  NanoProcess.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `Process` of framework `Swifter` by Damian Kołakowski.
//
//  Copyright © 2014-2016 Damian Kołakowski. All rights reserved.
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

/// Information about the process, and a way to react to termination signals.
public class NanoProcess {
  
  /// The process identifier.
  public static var pid: Int {
    return Int(getpid())
  }
  
  /// The identifier of the calling thread.
  public static var tid: UInt64 {
    #if os(Linux)
    return UInt64(pthread_self())
    #else
    var tid: __uint64_t = 0
    pthread_threadid_np(nil, &tid)
    return UInt64(tid)
    #endif
  }
  
  /// The signals that ``watchSignals(_:)`` watches. (`SIGSTOP` is not one of them: no process can catch it.)
  static let terminationSignals: [Int32] = [SIGTERM, SIGHUP, SIGINT]
  
  /// A call of `watchSignals`: the signals it asked for, and what to call.
  private struct Registration {
    let id: Int
    let signals: Set<Int32>
    let callback: (Int32) -> Void
  }
  
  /// A signal that is watched: its dispatch source, and what the process did with the signal before.
  private struct Watched {
    let source: DispatchSourceSignal
    let previous: sig_t?
  }
  
  /// Guards the following variables.
  private static let lock = NSLock()
  private static var registrations = [Registration]()
  private static var watched = [Int32: Watched]()
  private static var lastID = 0
  
  /// The queue that the callbacks run on, one at a time.
  private static let queue = DispatchQueue(label: "NanoHTTP signals", qos: .userInitiated)
  
  /// Registers `callback` to be called with the number of the signal when the process receives `SIGTERM`, `SIGHUP`
  /// or `SIGINT` (Ctrl-C). All registered callbacks are called, in the order of registration.
  ///
  /// The callbacks run on a queue of their own, not inside the signal handler of the system, so they can do whatever
  /// is needed: stop a server (which makes ``NanoHTTPServerIO/run(_:)`` return), save state, write to a log. They run
  /// one at a time. After the first call the process no longer ends by itself when it receives one of these
  /// signals; a callback has to see to that (by stopping what the program is doing, or by calling `exit`).
  public static func watchSignals(_ callback: @escaping (Int32) -> Void) {
    _ = self.watch(self.terminationSignals, callback)
  }
  
  /// Registers `callback` for `signals` and returns the number of the registration, see ``unwatch(_:)``. The signal is
  /// ignored by the process from now on (as far as its default action goes: ending the process), and delivered to a
  /// dispatch source instead.
  @discardableResult
  static func watch(_ signals: [Int32], _ callback: @escaping (Int32) -> Void) -> Int {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    self.lastID += 1
    self.registrations.append(Registration(id: self.lastID, signals: Set(signals), callback: callback))
    for signum in signals where self.watched[signum] == nil {
      // With the default action, the signal would end the process before the source sees it.
      let previous = signal(signum, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signum, queue: self.queue)
      source.setEventHandler {
        NanoProcess.deliver(signum)
      }
      source.resume()
      self.watched[signum] = Watched(source: source, previous: previous)
    }
    return self.lastID
  }
  
  /// Takes back a registration of ``watch(_:_:)``. A signal that nobody watches any more is treated as it was before.
  static func unwatch(_ id: Int) {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    self.registrations.removeAll { $0.id == id }
    for (signum, entry) in Array(self.watched) where !self.registrations.contains(where: { $0.signals.contains(signum) }) {
      entry.source.cancel()
      signal(signum, entry.previous)
      self.watched[signum] = nil
    }
  }
  
  private static func deliver(_ signum: Int32) {
    self.lock.lock()
    let callbacks = self.registrations.filter { $0.signals.contains(signum) }.map { $0.callback }
    self.lock.unlock()
    for callback in callbacks { // not under the lock: a callback may register another one
      callback(signum)
    }
  }
}
