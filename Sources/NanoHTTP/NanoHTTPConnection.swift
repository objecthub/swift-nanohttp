//
//  NanoHTTPConnection.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
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

/// A function that answers a request. It runs on the thread of the connection that sent the request,
/// one request at a time per connection, and many handlers run at the same time for different
/// connections (unless the server has only one thread). A handler may block (a slow handler delays only
/// its own connection) but must protect state that it shares with other handlers.
///
/// A handler can throw. A ``NanoHTTPError`` becomes the response with its status code; every other error
/// becomes `500 Internal Server Error`, see ``NanoHTTPServerIO/response(for:to:)``.
public typealias NanoHTTPRequestHandler = (NanoHTTPRequest) throws -> NanoHTTPResponse

/// A function that wraps the handling of requests, see ``NanoHTTPServer/middleware``. It receives the
/// request and `next`, which stands for the rest of the chain: the following middleware, the router and
/// the handler. Calling `next(request)` lets the request through and gives the response; a middleware
/// may change the request before, change the response afterwards, catch an error that `next` throws, or
/// answer the request itself and never call `next`.
public typealias NanoHTTPMiddleware = (NanoHTTPRequest, NanoHTTPRequestHandler) throws -> NanoHTTPResponse

/// A request that has been read from a connection, together with the handler that will answer it.
/// ``NanoHTTPServerIO/handle(connection:)`` drives the connection with it: `send(_:)` writes the
/// response and returns the connection for the next request, or `nil` when the connection has ended.
public struct NanoHTTPConnection {
  public weak var server: NanoHTTPServerIO?
  /// The parser that reads the requests of this connection.
  public let parser: NanoHTTPParser
  /// The request to answer.
  public let request: NanoHTTPRequest
  /// The handler chosen for `request`.
  public let handler: NanoHTTPRequestHandler
  /// The configuration of the run of the server that this connection belongs to. It is read once: the
  /// server's copy is guarded by a lock that all connections share.
  private let configuration: NanoHTTPServerIO.Configuration
  
  internal init?(server: NanoHTTPServerIO, socket: NanoSocket) {
    server.remember(socket: socket)
    guard server.operating else {
      // The server was stopped after this connection had been accepted but before it was
      // registered, so `stop` did not see it.
      socket.close()
      server.forget(socket: socket)
      return nil
    }
    self.server = server
    let configuration = server.activeConfiguration
    self.configuration = configuration
    socket.setSendTimeout(configuration.writeTimeout)
    let parser = NanoHTTPParser(socket: socket, limits: configuration.limits)
    self.parser = parser
    let request: NanoHTTPRequest
    do {
      request = try NanoHTTPConnection.readRequest(parser, configuration)
    } catch {
      NanoHTTPConnection.refuse(error, on: socket, configuration)
      socket.close()
      server.forget(socket: socket)
      return nil
    }
    server.delegate?.connectionReceived(server: server, socket: socket)
    request.address = try? socket.peername()
    let (params, handler) = server.dispatch(request: request)
    request.params = params
    self.request = request
    self.handler = handler
  }
  
  private init(current: NanoHTTPConnection,
               request: NanoHTTPRequest,
               handler: @escaping NanoHTTPRequestHandler) {
    self.server = current.server
    self.parser = current.parser
    self.configuration = current.configuration
    self.request = request
    self.handler = handler
  }
  
  /// The socket of the connection.
  public var socket: NanoSocket {
    return self.parser.socket
  }
  
  /// Calls the handler of the request, and returns its response. If the handler throws an error, the
  /// server decides what the response is (``NanoHTTPServerIO/response(for:to:)``): the response of a
  /// ``NanoHTTPError``, or `500 Internal Server Error`.
  public func response() -> NanoHTTPResponse {
    do {
      return try self.handler(self.request)
    } catch {
      guard let server else {
        return NanoHTTPError.internalServerError("Internal Server Error").response
      }
      return server.response(for: error, to: self.request)
    }
  }
  
  /// Writes `response`, then waits for the next request of the connection.
  ///
  /// The connection stays open if the client wants that (HTTP/1.1 connections are persistent unless the
  /// request has `Connection: close`; HTTP/1.0 connections close unless it has `Connection: keep-alive`), the
  /// end of the response is known (a length, chunks, or no body), and the server is still running;
  /// `dontKeepAlive` forces it to close. The response says `Connection: close` if the connection is going to be
  /// closed. A response to a `HEAD` request has no body. A response whose body is a socket session
  /// (``NanoHTTPResponse/switchProtocols(_:_:)``, WebSocket) runs the session first and ends the connection
  /// afterwards.
  ///
  /// - Returns: The connection with the next request, or `nil` if the connection has ended (it is
  ///     closed then). A request that cannot be read is answered with `400`, `408`, `413`, `414` or
  ///     `431`. A server with only one thread does not wait for the next request here: it gets `nil`
  ///     for a connection that stays open, and waits for the request itself.
  public func send(_ response: NanoHTTPResponse,
                   dontKeepAlive: Bool = false) -> NanoHTTPConnection? {
    guard let server else {
      self.close()
      return nil
    }
    var keepConnection = request.supportsKeepAlive
    let operating = server.operating
    do {
      keepConnection = try operating &&
                         self.respond(response: response,
                                      keepAlive: keepConnection && !dontKeepAlive)
    } catch {
      server.log("Failed to send response: \(error)")
      keepConnection = false // the client has a response that is cut off
    }
    if let session = response.eventSession() {
      // A WebSocket may be silent for hours: the server waits for the next message without a limit, and the
      // session reads what has begun to arrive with the read timeout.
      socket.setReceiveTimeout(self.configuration.readTimeout)
      server.delegate?.connectionReceived(server: server, socket: socket)
      if self.configuration.threading == .singleThread {
        // The server waits for the socket together with all other sockets, and calls the session when there
        // is something to read: this thread has more to do than to wait for one session.
        server.adopt(session: session, on: socket)
        session.start(socket: socket, drainTimeout: 0.1)
        return nil
      }
      self.run(session: session, on: server)
    } else if let session = response.socketSession() {
      // The session decides how long it waits for data: a WebSocket may be silent for hours.
      socket.setReceiveTimeout(nil)
      if self.configuration.threading == .singleThread {
        server.log("A socket session in the form of a function runs on the only thread of the server; nothing else is served until it returns (a NanoSocketSession does not have this problem)")
      }
      server.delegate?.connectionReceived(server: server, socket: socket)
      session(socket)
    }
    if keepConnection && !dontKeepAlive && server.operating {
      if self.configuration.threading == .singleThread {
        // The only thread must not wait for the next request: the server does, together with all
        // other connections, and calls `handle(connection:)` again when it has arrived.
        return nil
      }
      do {
        let request = try NanoHTTPConnection.readRequest(parser, self.configuration)
        request.address = try? socket.peername()
        let (params, handler) = server.dispatch(request: request)
        request.params = params
        return NanoHTTPConnection(current: self, request: request, handler: handler)
      } catch {
        NanoHTTPConnection.refuse(error, on: socket, self.configuration)
      }
    }
    self.close()
    return nil
  }
  
  /// Drives a session on the thread of the connection, until it ends: waits for the socket, and calls the
  /// session when there is something to read. The wait ends after the read timeout (the receive timeout of the
  /// socket) without anything to read, and then goes on: a session may be silent for as long as it likes.
  private func run(session: NanoSocketSession, on server: NanoHTTPServerIO) {
    session.start(socket: self.socket, drainTimeout: 1)
    while server.operating {
      guard let dataIsThere = try? self.socket.awaitData() else {
        break // the socket has been closed
      }
      if dataIsThere && !session.receive() {
        break
      }
    }
    session.end()
  }
  
  /// Thrown when a connection that was expected to send a request stayed silent.
  private struct IdleTimeout: Error {
  }
  
  /// Waits for the next request and reads it. The wait for its first byte is limited by the idle
  /// timeout (a connection that stays silent is simply closed); once it has begun, a pause longer
  /// than the read timeout is an error (answered with `408`).
  private static func readRequest(_ parser: NanoHTTPParser,
                                  _ configuration: NanoHTTPServerIO.Configuration) throws -> NanoHTTPRequest {
    let socket = parser.socket
    // A server with one thread has waited for all its connections together, and calls only for the
    // connection that has something to read. Otherwise this thread waits, for the idle timeout.
    if configuration.threading != .singleThread,
       try !socket.waitUntilReadable(timeout: configuration.idleTimeout) {
      throw IdleTimeout()
    }
    socket.setReceiveTimeout(configuration.readTimeout)
    return try parser.readHttpRequest()
  }
  
  /// Answers a request that could not be read. Only errors caused by the request itself get a
  /// response (400, 408, 413, 414 or 431); if the connection failed, was idle for too long or the
  /// peer went away, there is nobody to answer. The caller closes the connection afterwards.
  private static func refuse(_ error: Error, on socket: NanoSocket,
                             _ configuration: NanoHTTPServerIO.Configuration) {
    let status: String
    if let error = error as? NanoHTTPParserError {
      switch error {
        case .requestLineTooLong:
          status = "414 URI Too Long"
        case .headerLineTooLong, .headersTooLarge:
          status = "431 Request Header Fields Too Large"
        case .bodyTooLarge:
          status = "413 Content Too Large"
        case .invalidStatusLine, .invalidContentLength, .negativeContentLength, .conflictingFraming, .invalidChunk:
          status = "400 Bad Request"
        case .unsupportedVersion:
          status = "505 HTTP Version Not Supported"
        case .unsupportedTransferEncoding:
          status = "501 Not Implemented"
        case .expectationFailed:
          status = "417 Expectation Failed"
      }
    } else if let error = error as? NanoSocketError, case .timedOut = error {
      status = "408 Request Timeout"
    } else {
      return
    }
    // A thread that serves one connection can afford to wait for the client to finish; the only thread
    // of a server cannot.
    NanoHTTPConnection.reject(status, on: socket,
                              drainTimeout: configuration.threading == .singleThread ? 0.1 : 1)
  }
  
  /// Answers with an empty response that ends the connection, and closes the socket.
  ///
  /// The client may still be sending the rest of the refused request; see `closeAfterDraining`.
  static func reject(_ status: String,
                     headers: String = "",
                     on socket: NanoSocket,
                     drainTimeout: TimeInterval = 1,
                     drainLimit: Int = 4 * 1024 * 1024) {
    try? socket.writeUTF8("HTTP/1.1 \(status)\r\nConnection: close\r\n\(headers)Content-Length: 0\r\n\r\n")
    socket.closeAfterDraining(timeout: drainTimeout, limit: drainLimit)
  }
  
  /// Closes the connection and removes it from the server.
  public func close() {
    self.socket.close()
    self.server?.forget(socket: self.socket)
  }
  
  /// Writes the response and tells whether the connection can be kept open.
  ///
  /// How the body ends decides: a body in memory has a length, and is written with the head of the response in one
  /// piece (one system call; the client gets the response in one segment). A body that a function writes has the
  /// length that its `Content-Length` header declares (and that is checked), or is sent in chunks, or, for an
  /// HTTP/1.0 client, which does not know chunks, ends with the connection. The connection is kept if the client
  /// wants that and the end of the response is known.
  private func respond(response: NanoHTTPResponse, keepAlive: Bool) throws -> Bool {
    guard let server else {
      return false
    }
    var response = response
    var inline: NanoHTTPInlineBody?
    do {
      inline = try response.body.inline()
    } catch {
      // The body could not be produced (a `.json` body that is not JSON). Nothing has been sent
      // yet, so the client can still be told that the server failed.
      server.log("Unable to produce the body of the response: \(error)")
      response = NanoHTTPResponse.internalServerError(.text("Internal Server Error"))
      inline = try response.body.inline()
    }
    let status = response.statusCode
    // The responses that have no body, whatever the handler said; and the responses to HEAD, which are
    // those to GET without the body (their headers, `Content-Length` included, say what GET would get).
    let isHead = self.request.method == "HEAD"
    let bodyAllowed = !((100..<200).contains(status) || status == 204 || status == 304)
    let framing: NanoHTTPResponseSerializer.Framing
    if !bodyAllowed {
      framing = .none
    } else if let inline {
      framing = .length(inline.count)
    } else if case .custom(_, _) = response.body {
      if let declared = NanoHTTPConnection.declaredLength(of: response) {
        framing = .length(declared)
      } else if isHead {
        framing = .none // the length is not known, and there is no body that chunks could be for
      } else {
        framing = self.request.httpVersion == "HTTP/1.0" ? .untilClose : .chunked
      }
    } else {
      framing = .none // the connection is switched to another protocol
    }
    // The end of the response is known if it has a length or chunks, or cannot have a body.
    let endIsKnown: Bool
    switch framing {
      case .length, .chunked:
        endIsKnown = true
      case .none:
        endIsKnown = status == 204 || status == 304 || (isHead && status != 101)
      case .untilClose:
        endIsKnown = false
    }
    var keeping = keepAlive && endIsKnown
    // What the head says about the connection: `Connection: close` if it is going to be closed, and
    // `Connection: keep-alive` if the client asked for that explicitly (HTTP/1.1 connections are persistent anyway).
    let connection: NanoHTTPResponseSerializer.Connection
    if keeping {
      connection = self.request.asksForKeepAlive ? .keepAlive : .unspecified
    } else {
      connection = status == 101 ? .unspecified : .close
    }
    var message = NanoHTTPResponseSerializer.head(response,
                                                  framing: framing,
                                                  connection: connection,
                                                  date: (100..<200).contains(status) ? nil : NanoHTTPDate.string(),
                                                  dropped: { server.log("Dropped a response header with an invalid name: \(String(reflecting: $0))") })
    if isHead && status != 101 {
      try self.socket.writeUInt8(message) // the head only
    } else if let inline, bodyAllowed {
      if message.count + inline.count <= NanoHTTPConnection.coalescingLimit {
        inline.append(to: &message)
        try self.socket.writeUInt8(message)
      } else {
        try self.socket.writeUInt8(message)
        var body = [UInt8]()
        body.reserveCapacity(inline.count)
        inline.append(to: &body)
        try self.socket.writeUInt8(body)
      }
    } else {
      try self.socket.writeUInt8(message)
      if bodyAllowed, case .custom(let write, _) = response.body {
        switch framing {
          case .length(let length):
            let writer = LengthLimitedBodyWriter(socket: self.socket, length: length)
            try write(writer)
            if !writer.isComplete {
              server.log("The body of a response has \(writer.overflowed ? "more" : "fewer") bytes than the \(length) of its Content-Length; the connection is closed")
              keeping = false
            }
          case .chunked:
            let writer = ChunkedBodyWriter(socket: self.socket)
            try write(writer)
            try writer.finish()
          default:
            try write(self.socket)
        }
      }
    }
    return keeping
  }
  
  /// The length that the handler declares with a `Content-Length` header, if it is a number.
  private static func declaredLength(of response: NanoHTTPResponse) -> Int? {
    for (name, value) in response.headers where name.lowercased() == "content-length" {
      if let length = Int(value.trimmingCharacters(in: .whitespaces)), length >= 0 {
        return length
      }
    }
    return nil
  }
  
  /// Heads and bodies up to this size are written together, in one system call.
  private static let coalescingLimit = 64 * 1024
}
