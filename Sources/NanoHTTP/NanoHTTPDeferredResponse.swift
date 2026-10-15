//
//  NanoHTTPDeferredResponse.swift
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

/// The answer to a request that is sent later, from any thread.
///
/// ``NanoHTTPServerIO/handle(connection:)`` normally answers a request before it returns.
/// A subclass that hands its requests to other threads (a pool of workers, a queue that
/// another runtime serves, a long-running job) calls ``NanoHTTPConnection/deferResponse()``
/// instead, passes the result on, and returns. Whoever has the answer calls
/// ``send(_:dontKeepAlive:)``:
///
/// ```swift
/// // file scope
/// final class ExampleQueueServer: NanoHTTPServer {
///   let workers = DispatchQueue(label: "workers", attributes: .concurrent)
///
///   override func handle(connection: NanoHTTPConnection) {
///     let pending = connection.deferResponse()
///     // the route that matches; it may do the work itself
///     let response = connection.response()
///     self.workers.async {
///       pending.send(response)
///     }
///   }
/// }
/// ```
///
/// What the server does meanwhile, in both threading modes:
///
/// - The server **writes the answer itself**, on a thread of its own (the thread of a
///   connection, or the only thread of the server), and waits for the next request of the
///   connection there. ``send(_:dontKeepAlive:)``
///   returns at once: the thread that answers never waits for a client that is slow to
///   read the response or to send its next request. The next request of a connection that
///   is kept alive arrives in ``NanoHTTPServerIO/handle(connection:)`` again, like any
///   other request.
/// - A connection that waits for its answer is **not read and does not time out**: neither
///   the idle timeout nor the read timeout applies, and a request that the client has
///   already sent behind the first (pipelining) is not handled before the first has been
///   answered. It counts as an open connection
///   (``NanoHTTPServerIO/Configuration/maxConnections``), and it ends when the server stops.
/// - A token that is released without an answer (its owner forgot it, or failed)
///   **closes the connection** and logs a warning, so that no connection waits for ever
///   for an answer that nobody will send.
///
/// The token can be used from any thread, once: the first call of ``send(_:dontKeepAlive:)``
/// or ``close()`` counts, later calls do nothing. The answer can also be sent before
/// `handle(connection:)` has returned.
public final class NanoHTTPDeferredResponse {
  private let connection: NanoHTTPConnection
  private let lock = UnfairLock()
  private var finished = false

  init(connection: NanoHTTPConnection) {
    self.connection = connection
  }

  /// The request that waits for its answer.
  public var request: NanoHTTPRequest {
    return self.connection.request
  }

  /// The server that the request came to, unless it has been released.
  public var server: NanoHTTPServerIO? {
    return self.connection.server
  }

  /// Hands the answer to the server, which writes it and then waits for the next request
  /// of the connection. Returns at once, and can be called from any thread.
  ///
  /// The response is written as ``NanoHTTPConnection/send(_:dontKeepAlive:)`` writes it;
  /// a write that fails (the client has gone, or does not read) is logged and ends the
  /// connection. A response that switches the connection to a ``NanoSocketSession``
  /// (a WebSocket) works too.
  ///
  /// - Parameters:
  ///   - response: The answer to the request.
  ///   - dontKeepAlive: Closes the connection after the response, even if the client
  ///     would keep it.
  /// - Returns: `false` if the request has been answered or closed before, in which
  ///            case nothing happens.
  @discardableResult
  public func send(_ response: NanoHTTPResponse, dontKeepAlive: Bool = false) -> Bool {
    guard self.finish() else {
      return false
    }
    self.hand(response, dontKeepAlive: dontKeepAlive)
    return true
  }

  /// Closes the connection without an answer. Does nothing if the request has been
  /// answered or closed before; returns `false` then.
  @discardableResult
  public func close() -> Bool {
    guard self.finish() else {
      return false
    }
    self.hand(nil, dontKeepAlive: true)
    return true
  }

  /// Takes the one chance to answer.
  private func finish() -> Bool {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    if self.finished {
      return false
    }
    self.finished = true
    return true
  }

  private func hand(_ response: NanoHTTPResponse?, dontKeepAlive: Bool) {
    if let server = self.connection.server {
      server.complete(self.connection, with: response, dontKeepAlive: dontKeepAlive)
    } else {
      self.connection.close()
    }
  }

  deinit {
    if self.finish() {
      let request = self.connection.request
      self.connection.server?.log(.warning,
        "The response to \(request.method) \(request.rawPath) was released without an answer; the connection is closed")
      self.hand(nil, dontKeepAlive: true)
    }
  }
}

extension NanoHTTPConnection {

  /// Promises to answer the request later, from any thread, with the returned
  /// ``NanoHTTPDeferredResponse``. Call it in ``NanoHTTPServerIO/handle(connection:)``
  /// (and nowhere else), before it returns; the connection is not answered when `handle`
  /// returns. Calling it again for the same request returns the same token.
  ///
  /// See ``NanoHTTPDeferredResponse`` for what the server does with a connection that
  /// waits for its answer.
  public func deferResponse() -> NanoHTTPDeferredResponse {
    if let pending = self.request.deferral {
      return pending
    }
    self.server?.prepareDeferral()
    let pending = NanoHTTPDeferredResponse(connection: self)
    self.request.deferral = pending
    self.request.isDeferred = true
    return pending
  }
}
