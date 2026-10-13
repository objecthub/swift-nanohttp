//
//  NanoHTTPServerIO.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `HttpServerIO` of framework `Swifter` by Damian Kołakowski.
//
//  Copyright © 2014-2016 Damian Kołakowski. All rights reserved.
//  Copyright © 2024 Matthias Zenger. All rights reserved.
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
import Dispatch

public protocol NanoHTTPServerDelegate: AnyObject {
  func connectionReceived(server: NanoHTTPServerIO, socket: NanoSocket)
}

open class NanoHTTPServerIO {
  
  public enum State: Int32 {
    case starting
    case running
    case stopping
    case stopped
  }
  
  public weak var delegate: NanoHTTPServerDelegate?
  
  /// The listening socket of the current run (guarded by `stateLock`)
  private var listeningSocket = NanoSocket(socketFileDescriptor: -1)
  
  /// String representation of the IPv4 address to receive requests from.
  /// It's only used when the server is started with `forceIPv4` option set to true.
  /// Otherwise, `listenAddressIPv6` will be used.
  public var listenAddressIPv4: String?
  
  /// String representation of the IPv6 address to receive requests from.
  /// It's only used when the server is started with `forceIPv4` option set to false.
  /// Otherwise, `listenAddressIPv4` will be used.
  public var listenAddressIPv6: String?
  
  /// The largest requests this server accepts. A request that exceeds a limit is answered with
  /// `413`, `414` or `431` and the connection is closed. Set this before calling `start`.
  public var limits = NanoHTTPParser.Limits()
  
  /// Actively used sockets; mutations are synchronized
  private var sockets = Set<NanoSocket>()
  private let lock = NSLock()
  
  /// Guards `stateValue` and `listeningSocket`; the state is read by the threads that serve
  /// connections while `start` and `stop` change it.
  private let stateLock = NSLock()
  private var stateValue = State.stopped
  
  /// The state of the server.
  public private(set) var state: State {
    get {
      self.stateLock.lock()
      defer {
        self.stateLock.unlock()
      }
      return self.stateValue
    }
    set(state) {
      self.stateLock.lock()
      self.stateValue = state
      self.stateLock.unlock()
    }
  }
  
  /// Changes the state to `new` if it is `expected` right now, as one atomic step. Returns `false`
  /// without a change otherwise. This decides which of several concurrent calls of `start` or
  /// `stop` does the work.
  private func transition(from expected: State, to new: State) -> Bool {
    self.stateLock.lock()
    defer {
      self.stateLock.unlock()
    }
    guard self.stateValue == expected else {
      return false
    }
    self.stateValue = new
    return true
  }
  
  /// The listening socket of the current run.
  var socket: NanoSocket {
    self.stateLock.lock()
    defer {
      self.stateLock.unlock()
    }
    return self.listeningSocket
  }
  
  /// Is this server running?
  public var operating: Bool {
    return self.state == .running
  }
  
  /// Returns the port at which the server is listening
  public func port() throws -> Int {
    return Int(try socket.port())
  }
  
  /// Returns true if this server is forcing the usage of IPv4
  public func isIPv4() throws -> Bool {
    return try socket.isIPv4()
  }
  
  /// Returns the number of open HTTP connections
  public var openConnections: Int {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    return self.sockets.count
  }
  
  deinit {
    self.stop()
  }
  
  /// Starts to accept connections at `port` (`0` picks a free port, see `port()`). Does nothing if
  /// the server is already running or is being started or stopped by another thread.
  ///
  /// - Throws: `NanoSocketError` if the listening socket cannot be set up (for example because the
  ///     port is in use or `listenAddressIPv4`/`listenAddressIPv6` is no valid address). The
  ///     server is stopped then.
  public func start(_ port: UInt16 = 8080,
                    forceIPv4: Bool = false,
                    priority: DispatchQoS.QoSClass? = .background,
                    handlerPriority: DispatchQoS.QoSClass? = .userInitiated) throws {
    guard self.transition(from: .stopped, to: .starting) else {
      return
    }
    let address = forceIPv4 ? listenAddressIPv4 : listenAddressIPv6
    let socket: NanoSocket
    do {
      socket = try NanoSocket.tcpSocketForListen(port, forceIPv4, SOMAXCONN, address)
    } catch {
      self.state = .stopped
      throw error
    }
    self.stateLock.lock()
    self.listeningSocket = socket
    self.stateValue = .running
    self.stateLock.unlock()
    if let priority {
      DispatchQueue.global(qos: priority).async { [weak self] in
        self?.listen(priority: handlerPriority)
      }
    } else {
      self.listen(priority: handlerPriority)
    }
  }
  
  /// Stops the server: the listening socket and all open connections are closed. Does nothing if
  /// the server is not running; if several threads call `stop` at the same time, one of them does
  /// the work.
  open func stop() {
    self.shutDown(run: nil)
  }
  
  /// Stops the server if it is running. If `listener` is given, only the run that uses this
  /// listening socket is stopped. Whether the server is running that run, and the switch to the
  /// state `stopping`, is decided in one atomic step: an accept loop of an earlier run that is
  /// late to notice that it is over must not stop a server that has been started again.
  func shutDown(run listener: NanoSocket?) {
    self.stateLock.lock()
    guard self.stateValue == .running, listener == nil || self.listeningSocket === listener else {
      self.stateLock.unlock()
      return
    }
    self.stateValue = .stopping
    let socket = self.listeningSocket
    self.stateLock.unlock()
    // Shutdown connected peers because they can live in 'keep-alive' or 'websocket' loops.
    self.closeAndforgetAllConnections()
    socket.close()
    self.state = .stopped
  }
  
  /// Accepts connections until the server is stopped or the listening socket fails.
  ///
  /// A failed attempt to accept does not stop the server unless the listening socket itself is
  /// gone: an interrupted call or an aborted connection is simply retried, and running out of file
  /// descriptors or memory pauses accepting (with a growing delay of up to a second) until the
  /// shortage is over. Connections that arrive during the shortage can be lost, because the system
  /// discards a connection it cannot hand out.
  open func listen(priority: DispatchQoS.QoSClass?) {
    let listener = self.socket // the listening socket of this run
    var failures = 0 // consecutive failed attempts
    var delay = 0.01
    acceptLoop: while self.operating {
      switch listener.acceptOutcome() {
        case .accepted(let socket):
          if failures > 0 {
            self.log("Accepting connections again")
          }
          failures = 0
          delay = 0.01
          if let priority {
            DispatchQueue.global(qos: priority).async { [weak self] in
              if let server = self,
                 server.operating,
                 let connection = NanoHTTPConnection(server: server, socket: socket) {
                server.handle(connection: connection)
              }
            }
          } else if self.operating, let connection = NanoHTTPConnection(server: self, socket: socket) {
            self.handle(connection: connection)
          }
        case .transient(let reason):
          failures += 1
          if failures == 1 {
            self.log("Unable to accept a connection (\(reason)); retrying")
          }
          if failures > 100 {
            // Failing over and over without a pause would only burn CPU.
            self.pause(for: delay)
            delay = min(delay * 2, 1.0)
          }
        case .exhausted(let reason):
          failures += 1
          if failures == 1 {
            self.log("Unable to accept a connection (\(reason)); retrying")
          }
          self.pause(for: delay)
          delay = min(delay * 2, 1.0)
        case .failed:
          // The listening socket is gone: either `stop` closed it, or it failed by itself. In the
          // second case the server stops; in the first it already has been stopped, and it may even
          // have been started again, which this loop must not touch.
          self.shutDown(run: listener)
          break acceptLoop
      }
    }
  }
  
  /// Waits for `seconds`, but wakes up early when the server stops operating.
  private func pause(for seconds: TimeInterval) {
    let end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    while self.operating && DispatchTime.now().uptimeNanoseconds < end {
      Thread.sleep(forTimeInterval: 0.02)
    }
  }
  
  open func dispatch(request: NanoHTTPRequest) -> ([String: String], NanoHTTPRequestHandler) {
    return ([:], { _ in NanoHTTPResponse.notFound() })
  }
  
  open func handle(connection: NanoHTTPConnection) {
    var connection = connection
    while let next = connection.send(connection.handler(connection.request)) {
      connection = next
    }
  }
  
  open func log(_ str: String) {
    print(str)
  }
  
  public func remember(socket: NanoSocket) {
    self.lock.lock()
    self.sockets.insert(socket)
    self.lock.unlock()
  }
  
  public func forget(socket: NanoSocket) {
    self.lock.lock()
    self.sockets.remove(socket)
    self.lock.unlock()
  }
  
  /// Closes all open connections. Connections that are waiting for a request or a message are
  /// ended; a connection that is in the middle of a response fails to write it.
  public func closeAndforgetAllConnections() {
    self.lock.lock()
    let connections = self.sockets
    self.sockets.removeAll(keepingCapacity: true)
    self.lock.unlock()
    // Closing may wait for operations that are still running; do not hold the lock meanwhile.
    for socket in connections {
      socket.close()
    }
  }
}
