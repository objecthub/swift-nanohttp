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
import os

/// A lock that costs next to nothing when nobody else holds it. The state of a server is read several
/// times for every request, by all connection threads.
final class UnfairLock {
  private let storage: UnsafeMutablePointer<os_unfair_lock>
  
  init() {
    self.storage = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    self.storage.initialize(to: os_unfair_lock())
  }
  
  deinit {
    self.storage.deinitialize(count: 1)
    self.storage.deallocate()
  }
  
  func lock() {
    os_unfair_lock_lock(self.storage)
  }
  
  func unlock() {
    os_unfair_lock_unlock(self.storage)
  }
}

/// The part of a server that deals with sockets and threads: it listens at a port, accepts
/// connections, reads the requests of each connection on a thread of its own, hands them to
/// ``dispatch(request:)`` and writes the responses. ``NanoHTTPServer`` builds routing on top of it;
/// subclass this class to use the server without routing.
///
/// The lifecycle is ``start(_:)`` and ``stop()``. Both can be called from any thread, and a server
/// can be started again after it was stopped. How the server listens and how much it accepts is set
/// with its ``configuration``; by default it listens at the loopback address only.
///
/// A connection serves one request at a time, on a thread of its own. Requests of different
/// connections are served concurrently, so code that handles requests must be thread-safe.
///
/// Requests are limited in size (see ``Configuration/limits``), and requests that exceed a limit or
/// cannot be parsed are answered by the server itself with `400`, `413`, `414` or `431`.
open class NanoHTTPServerIO {
  
  /// The states of a server.
  public enum State: Int32 {
    case starting
    case running
    case stopping
    case stopped
  }
  
  /// The network address a server listens at, which decides who can connect to it.
  public enum NanoListenAddress: Equatable {
    
    /// `127.0.0.1`: only programs on this machine can connect.
    case loopback
    
    /// All network interfaces, for IPv4 as well as IPv6 (`::`): everybody who can
    /// reach this machine can connect.
    case allInterfaces
    
    /// One address, as text: an IPv4 address (`"192.168.1.20"`, `"0.0.0.0"` for all
    /// IPv4 interfaces) or an IPv6 address (`"::1"`). Starting a server with a string
    /// that is no address, or no address of this machine, throws
    /// ``NanoSocketError/bindFailed(_:)``.
    case address(String)
  }
  
  /// How a server listens and what it accepts. Change it before ``start(_:)``: a
  /// running server keeps the configuration it was started with.
  ///
  /// ```swift
  /// let server = NanoHTTPServer()
  /// server.configuration.listenAddress = .allInterfaces   // reachable from the network
  /// server.configuration.limits.maxBodyBytes = 1024 * 1024
  /// try server.start(8080)
  /// ```
  public struct Configuration {
    /// The threads that run a server.
    public enum Threading: Equatable {
      /// A thread accepts connections, and every connection has a thread of its own. Requests of
      /// different connections are served at the same time, so handlers that share state need locks.
      /// A slow handler delays only its own connection. This is the default.
      case perConnection
      
      /// **One thread does everything**: it accepts connections, reads requests, calls the middleware
      /// and the handlers, and writes the responses, one request at a time. Handlers, middleware and
      /// everything else that runs in them need no locks, because they never run at the same time.
      /// ``NanoHTTPServerIO/start(_:)`` starts that thread (``acceptQoS`` is its priority);
      /// ``NanoHTTPServerIO/run(_:)`` uses the calling thread.
      ///
      /// Connections that wait for a request cost no thread and hold up nobody, so any number of
      /// browsers and idle keep-alive connections are fine. But everything that blocks the thread
      /// blocks the server:
      ///
      /// - A handler that takes a second delays all other requests by a second.
      /// - A request that stalls half way (the pause is limited by ``readTimeout``), and a client that
      ///   does not read its response (``writeTimeout``), hold up the server up to that long. Choose
      ///   shorter timeouts than the defaults.
      /// - A message of a WebSocket (or of another ``NanoSocketSession``) is handled by the one thread, between
      ///   other work, like a request: a closure that takes long delays everything, and a message that
      ///   stalls half way delays the others up to the ``readTimeout``. A socket session in the form of a
      ///   function (``NanoHTTPResponse/switchProtocols(_:_:)``) is different: it has the thread until it returns.
      ///
      /// ``connectionQoS`` has no effect.
      case singleThread
    }
    
    /// The `Host` headers that a server answers, see ``hostPolicy``.
    public enum HostPolicy: Equatable {
      /// Every `Host`, and requests without one. This is the default.
      case any
      
      /// A server that listens at the loopback address only answers `localhost`, `127.0.0.1` and `[::1]`
      /// (at any port, so that a tunnel to another port works); a server that listens at other addresses
      /// answers every `Host`, because the names under which it is reached are not known.
      case automatic
      
      /// Only the given hosts: `"example.com"` (at any port), `"example.com:8080"` (at that port only),
      /// `"[::1]"`. The case of the names does not matter.
      case hosts([String])
    }
    
    /// The `Origin` headers that a server answers, see ``originPolicy``.
    public enum OriginPolicy: Equatable {
      /// Every `Origin`. This is the default.
      case any
      
      /// Only pages of the server itself: the `Origin` of a request has to be the address that the request was
      /// sent to (its `Host`). A request from the page of another site, and one from a page that has no origin
      /// (`Origin: null`: a local file, a sandboxed frame) is refused.
      case sameOrigin
      
      /// Pages of the server itself, and the pages of the given origins: `"https://app.example"`,
      /// `"http://localhost:3000"`.
      case origins([String])
    }
    
    /// Where the server listens. The default is ``NanoListenAddress/loopback``: only programs on this
    /// machine can connect. Use ``NanoListenAddress/allInterfaces`` for a server that is meant to
    /// be reached from other devices.
    public var listenAddress: NanoListenAddress = .loopback
    
    /// The largest requests the server accepts. A request that exceeds a limit is answered with
    /// `413`, `414` or `431` and the connection is closed.
    public var limits = NanoHTTPParser.Limits()
    
    /// How long a connection may wait for a request to begin: after it was accepted, and after a
    /// response when the connection is kept alive. A connection that stays silent that long is closed
    /// without an answer. `nil` (or zero) waits forever. The default is 60 seconds.
    public var idleTimeout: TimeInterval? = 60
    
    /// How long the server waits for more of a request once it has begun: the longest pause between two
    /// parts of the request that arrive. A request that stalls longer is answered with `408 Request
    /// Timeout`. It is a pause, not the total time: a request that keeps arriving, slowly, is not cut
    /// off. `nil` (or zero) waits forever. The default is 30 seconds.
    public var readTimeout: TimeInterval? = 30
    
    /// How long a write may be blocked because the peer does not read: the connection is closed when
    /// the peer takes nothing for that long. `nil` (or zero) waits forever. The default is 30 seconds.
    public var writeTimeout: TimeInterval? = 30
    
    /// How long a write to a connection that has been turned over to a session, such as a WebSocket, may be blocked
    /// because the peer does not read: a write that makes no progress for that long fails, and the session ends. It is
    /// shorter than ``writeTimeout`` because a message that is sent to many sessions (a chat, see ``NanoWebSocketHub``)
    /// must not be held up for long by one client that has stopped reading, and on a server with
    /// ``Threading/singleThread`` a client that has stopped reading holds up the whole server for that long. `nil` (or
    /// zero) waits forever. The default is 5 seconds.
    public var sessionWriteTimeout: TimeInterval? = 5
    
    /// The most connections the server serves at the same time (WebSocket sessions included). When
    /// that many are open, a new connection is answered with `503 Service Unavailable` and closed.
    /// `nil` accepts any number; every connection uses a thread and a file descriptor. The default
    /// is 128.
    public var maxConnections: Int? = 128
    
    /// Which threads run the server, see ``Threading``. The default is ``Threading/perConnection``.
    public var threading: Threading = .perConnection
    
    /// Which `Host` headers the server answers. A web page can reach a server on this machine too: with
    /// *DNS rebinding* the page's own domain is made to point to `127.0.0.1`, and the browser then sends
    /// requests to the server with that domain as `Host`, and lets the page read the answers. A server that
    /// only accepts its own names is not fooled. The default is ``HostPolicy/any``, which accepts every
    /// `Host`; ``HostPolicy/automatic`` is what a server that is used from the browser of the same machine
    /// should switch on. Requests that are refused get `403 Forbidden`.
    public var hostPolicy: HostPolicy = .any
    
    /// Which `Origin` headers the server answers, for the requests that change something (everything but
    /// `GET`, `HEAD` and `OPTIONS`) and for WebSocket handshakes. A browser sends the `Origin` of the page
    /// with them, so that a page of another site that makes the browser send a request to this server
    /// (a form that is submitted, a `fetch`, a WebSocket) can be told from the pages of the server itself.
    /// Requests without an `Origin` (from tools that are not browsers) are always served. The default is
    /// ``OriginPolicy/any``; ``OriginPolicy/sameOrigin`` refuses requests that come from pages of other
    /// sites with `403 Forbidden`.
    public var originPolicy: OriginPolicy = .any
    
    /// The priority of the thread that accepts connections.
    public var acceptQoS: QualityOfService = .userInitiated
    
    /// The priority of the threads that serve the connections.
    public var connectionQoS: QualityOfService = .userInitiated
    
    /// Receives what the server reports: a response that could not be written, a pause in accepting
    /// connections, a handler that threw an error, a WebSocket client that broke the protocol. The default
    /// is a ``NanoOSLogger``, which writes to the unified logging system (the console of Xcode, the Console
    /// app). A command-line tool that should print to its terminal uses a ``NanoConsoleLogger``; a
    /// ``NanoSilentLogger`` switches logging off.
    public var logger: NanoHTTPLogger = NanoOSLogger()
    
    /// Creates the configuration of a new server: loopback only, default limits.
    public init() {
    }
  }
  
  /// Creates a server that is not running.
  ///
  /// - Parameter configuration: How the server listens and what it accepts; it can still be changed
  ///     with ``configuration`` until the server is started.
  public init(configuration: Configuration = Configuration()) {
    self.configurationValue = configuration
    self.activeConfigurationValue = configuration
  }
  
  /// The listening socket of the current run (guarded by `stateLock`)
  private var listeningSocket = NanoSocket(socketFileDescriptor: -1)
  
  /// The configuration for the next run (guarded by `stateLock`)
  private var configurationValue: Configuration
  
  /// The configuration of the current (or last) run (guarded by `stateLock`)
  private var activeConfigurationValue: Configuration
  
  /// The threads that serve the connections of the current run, if it has threads per connection
  /// (guarded by `stateLock`)
  private var connectionPoolValue: NanoThreadPool?
  
  /// How the server listens and what it accepts. A change takes effect the next time the server is
  /// started; a server that is running keeps the configuration it was started with.
  public var configuration: Configuration {
    get {
      self.stateLock.lock()
      defer {
        self.stateLock.unlock()
      }
      return self.configurationValue
    }
    set(configuration) {
      self.stateLock.lock()
      self.configurationValue = configuration
      self.stateLock.unlock()
    }
  }
  
  /// The configuration the connections of the current run are served with.
  var activeConfiguration: Configuration {
    self.stateLock.lock()
    defer {
      self.stateLock.unlock()
    }
    return self.activeConfigurationValue
  }
  
  /// Actively used sockets; mutations are synchronized
  private var sockets = Set<NanoSocket>()
  private let lock = NSLock()
  
  /// Guards `stateValue` and `listeningSocket`; the state is read by the threads that serve
  /// connections while `start` and `stop` change it.
  private let stateLock = UnfairLock()
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
  
  /// Starts to accept connections at `port` (`0` picks a free port, see `port()`) and returns: the
  /// connections are accepted and served on threads of the server (see ``Configuration/threading``).
  /// Does nothing if the server is already running or is being started or stopped by another thread.
  ///
  /// The server starts with the current ``configuration``.
  ///
  /// - Throws: `NanoSocketError` if the listening socket cannot be set up (for example because the
  ///     port is in use, or because the listen address is no address of this machine). The server
  ///     is stopped then.
  public func start(_ port: UInt16 = 8080) throws {
    guard let configuration = try self.launch(port) else {
      return
    }
    NanoHTTPServerIO.spawn(named: "NanoHTTP accept", qos: configuration.acceptQoS) { [weak self] in
      self?.listen()
    }
  }
  
  /// Starts the server like ``start(_:)``, but accepts connections on the calling thread, and returns
  /// only when the server has been stopped (with ``stop()``, from another thread or a signal handler).
  ///
  /// With ``Configuration/threading`` set to ``Configuration/Threading/singleThread``, the calling thread
  /// is the thread that runs the whole server, handlers included.
  ///
  /// - Throws: `NanoSocketError` if the listening socket cannot be set up, as ``start(_:)``.
  public func run(_ port: UInt16 = 8080) throws {
    guard try self.launch(port) != nil else {
      return
    }
    self.listen()
  }
  
  /// Creates the listening socket and switches to the state `running`. Returns the configuration of
  /// the run, or `nil` if the server was not stopped (somebody else starts or stops it).
  private func launch(_ port: UInt16) throws -> Configuration? {
    guard self.transition(from: .stopped, to: .starting) else {
      return nil
    }
    let configuration = self.configuration
    let socket: NanoSocket
    do {
      socket = try NanoSocket.tcpSocketForListen(port, configuration.listenAddress)
    } catch {
      self.state = .stopped
      throw error
    }
    self.stateLock.lock()
    self.listeningSocket = socket
    self.activeConfigurationValue = configuration
    self.connectionPoolValue = configuration.threading == .perConnection
      ? NanoThreadPool(name: "NanoHTTP connection", qos: configuration.connectionQoS)
      : nil
    self.stateValue = .running
    self.stateLock.unlock()
    return configuration
  }
  
  /// Runs `body` on a new thread.
  private static func spawn(named name: String, qos: QualityOfService, _ body: @escaping () -> Void) {
    let thread = Thread(block: body)
    thread.name = name
    thread.qualityOfService = qos
    thread.start()
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
    let pool = self.connectionPoolValue
    self.connectionPoolValue = nil
    self.stateLock.unlock()
    // Shutdown connected peers because they can live in 'keep-alive' or 'websocket' loops.
    self.closeAndforgetAllConnections()
    socket.close()
    pool?.close() // the threads that wait for connections end now
    self.state = .stopped
  }
  
  /// Accepts connections until the server is stopped or the listening socket fails. Runs on the
  /// accepting thread; the server calls it by itself after ``start(_:)`` and ``run(_:)``.
  ///
  /// A failed attempt to accept does not stop the server unless the listening socket itself is
  /// gone: an interrupted call or an aborted connection is simply retried, and running out of file
  /// descriptors or memory pauses accepting (with a growing delay of up to a second) until the
  /// shortage is over. Connections that arrive during the shortage can be lost, because the system
  /// discards a connection it cannot hand out.
  ///
  /// With ``Configuration/Threading/singleThread`` this thread also serves the connections.
  open func listen() {
    let listener = self.socket // the listening socket of this run
    let configuration = self.activeConfiguration
    if configuration.threading == .singleThread {
      self.serveOnOneThread(listener, configuration)
      return
    }
    // Connections get threads of their own instead of threads of the dispatch queues, which hold only a
    // few dozen blocked threads and stop running anything else when connections that wait for
    // requests use them up. The threads are reused.
    self.stateLock.lock()
    let pool = self.connectionPoolValue ?? NanoThreadPool(name: "NanoHTTP connection",
                                                           qos: configuration.connectionQoS)
    self.stateLock.unlock()
    var failures = AcceptFailures()
    var refusing = false // is the server over its limit of connections?
    acceptLoop: while self.operating {
      let outcome = listener.acceptOutcome()
      if case .accepted(let socket) = outcome {
        self.acceptSucceeded(&failures)
        if self.admit(socket, configuration, refusing: &refusing, inline: false) {
          let submitted = pool.submit { [weak self] in
            if let server = self,
               server.operating,
               let connection = NanoHTTPConnection(server: server, socket: socket) {
              server.handle(connection: connection)
            }
          }
          if !submitted { // the server has been stopped meanwhile
            socket.close()
            self.forget(socket: socket)
          }
        }
        continue
      }
      switch self.recover(from: outcome, &failures, listener: listener) {
        case .immediately:
          continue
        case .after(let seconds):
          self.pause(for: seconds)
        case .giveUp:
          break acceptLoop
      }
    }
  }
  
  /// Consecutive failures of accepting, and the pause before the next attempt.
  private struct AcceptFailures {
    var count = 0
    var delay = 0.01
  }
  
  private enum Recovery {
    case immediately
    case after(TimeInterval)
    case giveUp
  }
  
  private func acceptSucceeded(_ failures: inout AcceptFailures) {
    if failures.count > 0 {
      self.log(.info, "Accepting connections again")
    }
    failures = AcceptFailures()
  }
  
  /// Decides how to go on after an attempt to accept that did not give a connection.
  private func recover(from outcome: NanoSocket.AcceptOutcome,
                       _ failures: inout AcceptFailures,
                       listener: NanoSocket) -> Recovery {
    switch outcome {
      case .accepted, .wouldBlock:
        return .immediately
      case .transient(let reason):
        guard self.isRunning(listener) else {
          return .giveUp // `stop` closed the listening socket, which makes the accept that waits for it fail
        }
        failures.count += 1
        if failures.count == 1 {
          // Routine: a client that gave up before it was accepted (a reset connection) is no problem of the server.
          self.log(.info, "Unable to accept a connection (\(reason)); retrying")
        }
        guard failures.count > 100 else {
          return .immediately
        }
        // Failing over and over without a pause would only burn CPU.
        let delay = failures.delay
        failures.delay = min(delay * 2, 1.0)
        return .after(delay)
      case .exhausted(let reason):
        guard self.isRunning(listener) else {
          return .giveUp
        }
        failures.count += 1
        if failures.count == 1 {
          self.log(.warning, "Unable to accept a connection (\(reason)); retrying")
        }
        let delay = failures.delay
        failures.delay = min(delay * 2, 1.0)
        return .after(delay)
      case .failed:
        // The listening socket is gone: either `stop` closed it, or it failed by itself. In the
        // second case the server stops; in the first it already has been stopped, and it may even
        // have been started again, which this loop must not touch.
        self.shutDown(run: listener)
        return .giveUp
    }
  }
  
  /// Registers an accepted connection with the server and counts it. If the server has too many
  /// connections already, the client is told so and `false` is returned.
  private func admit(_ socket: NanoSocket,
                     _ configuration: Configuration,
                     refusing: inout Bool,
                     inline: Bool) -> Bool {
    // Count the connection now, not when its thread has started: a burst of connections must not get
    // past the limit before the first of them is registered.
    self.remember(socket: socket)
    guard let limit = configuration.maxConnections, self.openConnections > limit else {
      refusing = false
      return true
    }
    self.forget(socket: socket)
    if !refusing {
      refusing = true
      self.log(.warning, "There are \(limit) open connections; refusing new ones until some are closed")
    }
    let refuse = {
      NanoHTTPConnection.reject("503 Service Unavailable", headers: "Retry-After: 1\r\n", on: socket,
                                drainTimeout: inline ? 0.05 : 0.5, drainLimit: 64 * 1024)
    }
    if inline {
      refuse() // the server has no other thread
    } else {
      // Telling the client takes a while (it may still be sending); not on the accepting thread.
      DispatchQueue.global(qos: .utility).async(execute: refuse)
    }
    return false
  }
  
  /// A connection of a single-thread server that waits for its next request, or a session that waits for its
  /// next message.
  private struct Waiting {
    let socket: NanoSocket
    /// When the connection is closed if it has not sent a request by then (uptime in nanoseconds).
    var deadline: UInt64?
    /// The session that the connection has been turned over to, if it is not a connection that sends requests.
    var session: NanoSocketSession?
    /// Has the connection ended during this round of the loop?
    var finished = false
    /// Does the connection wait for an answer that another thread sends (``NanoHTTPDeferredResponse``)? It is
    /// not polled then, and has no deadline.
    var suspended = false
  }
  
  /// What happened to a connection that the single thread has served.
  private enum Served {
    case closed
    case waiting
    case session(NanoSocketSession)
    /// The answer has been promised for later: the connection is left alone until it comes.
    case deferred
  }
  
  /// The session that a response has just turned a connection over to, until the loop of the single thread
  /// has taken it over. Only used by the one thread.
  private var adoptedSession: (socket: NanoSocket, session: NanoSocketSession)?
  
  /// Called by a connection of a server with one thread when its response switches to a session: the loop
  /// waits for the socket and calls the session.
  func adopt(session: NanoSocketSession, on socket: NanoSocket) {
    self.adoptedSession = (socket, session)
  }
  
  private static func uptime() -> UInt64 {
    return DispatchTime.now().uptimeNanoseconds
  }
  
  /// Is `listener` the listening socket of the run that is going on right now?
  private func isRunning(_ listener: NanoSocket) -> Bool {
    self.stateLock.lock()
    defer {
      self.stateLock.unlock()
    }
    return self.stateValue == .running && self.listeningSocket === listener
  }
  
  /// The loop of a server that has only one thread, ``Configuration/Threading/singleThread``: it waits
  /// for the listening socket and every connection together, and serves one request at a time.
  /// A connection that has not sent anything is not read, so it holds up nobody; it is closed when the
  /// idle timeout has passed. Once a connection has sent the beginning of a request, the thread reads
  /// the rest of it and answers it, which a client that stalls can delay for up to the read timeout.
  private func serveOnOneThread(_ listener: NanoSocket, _ configuration: Configuration) {
    // A connection that is gone before it is accepted must not make `accept` wait.
    listener.setNonBlocking(true)
    var waiting = [Waiting]()
    defer {
      // The server has stopped: the sessions are over, and are told so.
      for entry in waiting where entry.session != nil && !entry.finished {
        entry.session?.end()
        entry.socket.close()
        self.forget(socket: entry.socket)
      }
      self.endDeferral()
    }
    var failures = AcceptFailures()
    var refusing = false
    var acceptAgainAt: UInt64 = 0 // when to look at the listening socket again after a shortage
    // What `poll` waits for: the listening socket first, then the pipe that other threads write to when they have
    // an answer for the loop (`-1` until a request has been deferred), then the sockets of `waiting`, in their
    // order. Connections that wait for their answer are not polled (`-1`). It is built again only when connections
    // have come or gone, not for every message.
    let listenerDescriptor = listener.socketFileDescriptor
    var wakeupDescriptor: Int32 = -1
    var pollers = [pollfd]()
    var rebuild = true
    func deadline() -> UInt64? {
      guard let idle = configuration.idleTimeout, idle > 0 else {
        return nil
      }
      return NanoHTTPServerIO.uptime() + UInt64(idle * 1_000_000_000)
    }
    while self.isRunning(listener) {
      let begin = NanoHTTPServerIO.uptime()
      let accepting = begin >= acceptAgainAt
      // At most a tenth of a second, so that a stop is noticed, and not longer than the next deadline.
      var wait = 100_000_000 as UInt64 // nanoseconds
      for entry in waiting where !entry.suspended {
        if let due = entry.deadline {
          wait = min(wait, due > begin ? due - begin : 0)
        }
        if entry.socket.hasBufferedData {
          wait = 0 // a request or a message has been read ahead: it is waiting for us, not for the system
        }
      }
      if !accepting {
        wait = min(wait, acceptAgainAt - begin)
      }
      if rebuild {
        pollers = [pollfd(fd: listenerDescriptor, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeupDescriptor, events: Int16(POLLIN), revents: 0)]
        pollers.append(contentsOf: waiting.map {
          pollfd(fd: $0.suspended ? -1 : $0.socket.socketFileDescriptor, events: Int16(POLLIN), revents: 0)
        })
        rebuild = false
      }
      pollers[0].fd = accepting ? listenerDescriptor : -1 // a negative descriptor is ignored
      // The sockets can be closed by other threads meanwhile (`stop`): at worst `poll` reports a socket that
      // has nothing to read, and the read that follows fails.
      let result = poll(&pollers, nfds_t(pollers.count), Int32(min(UInt64(Int32.max), (wait + 999_999) / 1_000_000)))
      var removed = false
      // The answers that other threads have handed over: the loop writes them, and goes on waiting for the next
      // request of those connections.
      if result > 0 && pollers[1].revents != 0 {
        self.drainWakeup(wakeupDescriptor)
        for completion in self.takeCompletions() {
          let socket = completion.connection.socket
          guard let index = waiting.firstIndex(where: { $0.socket === socket }) else {
            completion.connection.close() // the connection has gone meanwhile
            continue
          }
          _ = completion.connection.send(completion.response, dontKeepAlive: completion.dontKeepAlive) // nil: one thread
          switch self.outcome(of: socket) {
            case .closed:
              waiting[index].finished = true
              removed = true
            case .waiting, .deferred:
              waiting[index].suspended = false
              waiting[index].deadline = deadline()
              if !rebuild {
                pollers[index + 2].fd = socket.socketFileDescriptor
                pollers[index + 2].revents = 0
              }
            case .session(let session):
              waiting[index].suspended = false
              waiting[index].session = session
              waiting[index].deadline = nil
              if !rebuild {
                pollers[index + 2].fd = socket.socketFileDescriptor
                pollers[index + 2].revents = 0
              }
          }
        }
      }
      var index = 0
      while index < waiting.count && self.isRunning(listener) {
        let socket = waiting[index].socket
        if waiting[index].finished {
          // ended above
        } else if waiting[index].suspended {
          if socket.isClosed { // whoever owns the answer has ended the connection
            waiting[index].finished = true
            removed = true
          }
        } else if (result > 0 && pollers[index + 2].revents != 0) || socket.hasBufferedData || socket.isClosed {
          if let session = waiting[index].session {
            if !session.receive() {
              session.end()
              socket.close()
              self.forget(socket: socket)
              waiting[index].finished = true
              removed = true
            }
          } else {
            switch self.serve(socket) {
              case .closed:
                waiting[index].finished = true
                removed = true
              case .waiting:
                waiting[index].deadline = deadline()
              case .session(let session):
                waiting[index].session = session
                waiting[index].deadline = nil
              case .deferred:
                waiting[index].suspended = true
                waiting[index].deadline = nil
                let descriptor = self.wakeupReadDescriptor()
                if descriptor != wakeupDescriptor {
                  wakeupDescriptor = descriptor
                  rebuild = true
                }
                if !rebuild {
                  pollers[index + 2].fd = -1
                }
            }
          }
        } else if let due = waiting[index].deadline, NanoHTTPServerIO.uptime() >= due {
          socket.close() // sent nothing for too long
          self.forget(socket: socket)
          waiting[index].finished = true
          removed = true
        }
        index += 1
      }
      if removed {
        waiting.removeAll { $0.finished }
        rebuild = true
      }
      guard accepting && result > 0 && pollers[0].revents != 0 && self.isRunning(listener) else {
        continue
      }
      acceptNew: for _ in 0..<64 {
        let outcome = listener.acceptOutcome()
        switch outcome {
          case .accepted(let socket):
            self.acceptSucceeded(&failures)
            if self.admit(socket, configuration, refusing: &refusing, inline: true) {
              waiting.append(Waiting(socket: socket, deadline: deadline(), session: nil))
              rebuild = true
            }
          case .wouldBlock:
            break acceptNew // nothing more to accept
          default:
            switch self.recover(from: outcome, &failures, listener: listener) {
              case .immediately:
                continue
              case .after(let seconds):
                acceptAgainAt = NanoHTTPServerIO.uptime() + UInt64(seconds * 1_000_000_000)
                break acceptNew
              case .giveUp:
                return
            }
        }
      }
    }
  }
  
  /// Reads the request that has arrived on `socket` and answers it. Tells whether the
  /// connection stays open to wait for its next request, or has been turned over to a session.
  private func serve(_ socket: NanoSocket) -> Served {
    var deferred = false
    if let connection = NanoHTTPConnection(server: self, socket: socket) {
      self.handle(connection: connection)
      deferred = connection.request.isDeferred
    }
    if deferred && !socket.isClosed {
      return .deferred
    }
    return self.outcome(of: socket)
  }
  
  /// What has become of a connection after its response has been sent: it has ended,
  /// waits for its next request, or has been turned over to a session.
  private func outcome(of socket: NanoSocket) -> Served {
    if let adopted = self.adoptedSession {
      self.adoptedSession = nil
      if adopted.socket === socket && !socket.isClosed {
        return .session(adopted.session)
      }
      adopted.session.end() // its connection did not survive its start
    }
    return socket.isClosed ? .closed : .waiting
  }
  
  /// The response for a request whose handler (or middleware) threw `error`.
  ///
  /// A ``NanoHTTPError`` is answered with its status code, headers and message. Every
  /// other error is answered with `500 Internal Server Error` and no details, which are
  /// logged with the method and path of the request: the description of an error
  /// (a database error, a file path) is nothing for the client. Override to answer errors
  /// differently; ``NanoHTTPServer/errorHandler`` does that without subclassing.
  ///
  /// Called on the thread of the connection.
  open func response(for error: Error, to request: NanoHTTPRequest) -> NanoHTTPResponse {
    if let error = error as? NanoHTTPError {
      return error.response
    }
    self.log(.error, "\(request.method) \(request.rawPath) failed: \(error)")
    return NanoHTTPError.internalServerError("Internal Server Error").response
  }
  
  /// Waits for `seconds`, but wakes up early when the server stops operating.
  private func pause(for seconds: TimeInterval) {
    let end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    while self.operating && DispatchTime.now().uptimeNanoseconds < end {
      Thread.sleep(forTimeInterval: 0.02)
    }
  }
  
  /// Chooses the handler for a request and returns it with the variables that the request's route
  /// defined (see `NanoHTTPRequest.params`). The implementation of this class answers every request
  /// with `404 Not Found`; ``NanoHTTPServer`` overrides it to route.
  ///
  /// Called on the thread of the connection.
  open func dispatch(request: NanoHTTPRequest) -> ([String: String], NanoHTTPRequestHandler) {
    return ([:], { _ in NanoHTTPResponse.notFound() })
  }
  
  /// Serves a connection: calls the handler of its first request, sends the response and, as long as
  /// the connection is kept alive, does the same for the following requests. Returns when the
  /// connection has ended. Runs on the thread of the connection.
  ///
  /// A server with ``Configuration/Threading/singleThread`` calls it for every request that arrives:
  /// it returns after the response has been sent, and the connection, if it is kept alive, is left open
  /// for the server to wait for the next request.
  ///
  /// Override to wrap the handling (to measure the time of requests, for example) and call `super`. An
  /// override that does not call `super` can answer later, from another thread, instead: it calls
  /// ``NanoHTTPConnection/deferResponse()``, passes the result on and returns. The server calls it again for
  /// the next request of the connection after the answer has been sent (see ``NanoHTTPDeferredResponse``).
  open func handle(connection: NanoHTTPConnection) {
    var connection = connection
    while let next = connection.send(connection.response()) {
      connection = next
    }
  }
  
  // MARK: - Deferred responses
  
  /// An answer that another thread has handed over to the loop of a server with one thread, which writes it.
  private struct Completion {
    let connection: NanoHTTPConnection
    let response: NanoHTTPResponse
    let dontKeepAlive: Bool
  }
  
  /// Guards `completions` and `wakeup`.
  private let completionLock = NSLock()
  private var completions = [Completion]()
  /// The pipe that wakes the loop of a server with one thread when it has an answer to write: threads write a
  /// byte to `write`, the loop polls `read`. Created by the first deferred response of a run.
  private var wakeup: (read: Int32, write: Int32)? = nil
  
  /// Called by ``NanoHTTPConnection/deferResponse()``: a server with one thread needs its wake-up pipe before
  /// the answer can come.
  func prepareDeferral() {
    guard self.activeConfiguration.threading == .singleThread else {
      return
    }
    self.completionLock.lock()
    defer {
      self.completionLock.unlock()
    }
    guard self.wakeup == nil else {
      return
    }
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
      self.log(.error, "Unable to create the pipe for deferred responses: \(String(cString: strerror(errno)))")
      return
    }
    for descriptor in descriptors {
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    self.wakeup = (descriptors[0], descriptors[1])
  }
  
  /// Takes over the answer of a deferred response (or, if `response` is `nil`, the end of its connection) from
  /// any thread. A server with threads per connection writes it on a thread of its pool, which then waits for the
  /// next request, as it would have after the first one; a server with one thread has its loop write it.
  func complete(_ connection: NanoHTTPConnection, with response: NanoHTTPResponse?, dontKeepAlive: Bool) {
    guard self.operating else {
      connection.close()
      return
    }
    if self.activeConfiguration.threading == .singleThread {
      if let response {
        self.completionLock.lock()
        self.completions.append(Completion(connection: connection, response: response, dontKeepAlive: dontKeepAlive))
        self.completionLock.unlock()
      } else {
        connection.close() // the loop finds the closed socket
      }
      self.wakeLoop()
      return
    }
    guard let response else {
      connection.close()
      return
    }
    self.stateLock.lock()
    let pool = self.connectionPoolValue
    self.stateLock.unlock()
    let submitted = pool?.submit { [weak self] in
      guard let server = self else {
        connection.close()
        return
      }
      if let next = connection.send(response, dontKeepAlive: dontKeepAlive) {
        server.handle(connection: next)
      }
    } ?? false
    if !submitted { // the server has been stopped meanwhile
      connection.close()
    }
  }
  
  /// Wakes the loop of a server with one thread.
  private func wakeLoop() {
    self.completionLock.lock()
    defer {
      self.completionLock.unlock()
    }
    if let wakeup = self.wakeup {
      var byte: UInt8 = 1
      _ = write(wakeup.write, &byte, 1) // a full pipe means that the loop has been woken already
    }
  }
  
  /// The descriptor that the loop polls for wake-ups, or `-1`.
  private func wakeupReadDescriptor() -> Int32 {
    self.completionLock.lock()
    defer {
      self.completionLock.unlock()
    }
    return self.wakeup?.read ?? -1
  }
  
  /// Reads what has been written to the pipe, so that it is quiet again.
  private func drainWakeup(_ descriptor: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64)
    while descriptor >= 0 && read(descriptor, &buffer, buffer.count) > 0 {}
  }
  
  private func takeCompletions() -> [Completion] {
    self.completionLock.lock()
    defer {
      self.completionLock.unlock()
    }
    let taken = self.completions
    self.completions.removeAll(keepingCapacity: true)
    return taken
  }
  
  /// The loop of a server with one thread has ended: the pipe is closed, and the answers that nobody has
  /// written any more end their connections.
  private func endDeferral() {
    self.completionLock.lock()
    let wakeup = self.wakeup
    self.wakeup = nil
    let abandoned = self.completions
    self.completions.removeAll()
    self.completionLock.unlock()
    if let wakeup {
      close(wakeup.read)
      close(wakeup.write)
    }
    for completion in abandoned {
      completion.connection.close()
    }
  }
  
  /// The logger of the server: the one of ``Configuration/logger`` of the run that is going on, or, if the
  /// server is not running, the one that the next run will use.
  public var logger: NanoHTTPLogger {
    self.stateLock.lock()
    defer {
      self.stateLock.unlock()
    }
    return self.stateValue == .stopped ? self.configurationValue.logger : self.activeConfigurationValue.logger
  }
  
  /// Logs a message with the ``logger`` of the server. The server reports problems that nobody else
  /// can see (a response that could not be written, a pause in accepting connections, a response header
  /// that was dropped); your own code can use it too. May be called from any thread. The message is only
  /// built if the logger wants it.
  public func log(_ level: NanoLogLevel, _ message: @autoclosure () -> String) {
    self.logger.log(level, message())
  }
  
  /// Logs a message of the level ``NanoLogLevel/info``.
  public func log(_ message: String) {
    self.logger.log(.info, message)
  }
  
  /// Registers an open connection so that ``stop()`` and ``closeAndforgetAllConnections()`` can close
  /// it. Connections that the server creates are registered automatically; this is for subclasses that
  /// do their own connection handling.
  public func remember(socket: NanoSocket) {
    self.lock.lock()
    self.sockets.insert(socket)
    self.lock.unlock()
  }
  
  /// Unregisters a connection that has ended; see ``remember(socket:)``.
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
