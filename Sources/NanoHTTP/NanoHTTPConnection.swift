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
  /// The connection stays open if the client asked for it with `Connection: keep-alive`, the response
  /// has a known length, and the server is still running; `dontKeepAlive` forces it to close. A response
  /// whose body is a socket session (``NanoHTTPResponse/switchProtocols(_:_:)``, WebSocket) runs the
  /// session first and ends the connection afterwards.
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
        case .invalidStatusLine, .invalidContentLength, .negativeContentLength:
          status = "400 Bad Request"
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
  
  /// A header name is a token (RFC 9110 5.6.2): letters, digits and a few punctuation characters,
  /// but no whitespace, no colon and no line break.
  private static func isValidHeaderName(_ name: String) -> Bool {
    let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
    return !name.isEmpty && name.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || punctuation.contains($0)
    }
  }
  
  /// A header value without line breaks. A carriage return or line feed would end the header and let
  /// whatever follows become a header (or the body) of the response, which is how a redirect to a
  /// location taken from a request can be turned into an injection of arbitrary headers.
  private static func sanitizedHeaderValue(_ value: String) -> String {
    guard value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) else {
      return value
    }
    // Not `Character`s: "\r\n" is a single Character that is neither "\r" nor "\n".
    return String(String.UnicodeScalarView(value.unicodeScalars.map { $0 == "\r" || $0 == "\n" || $0 == "\0" ? " " : $0 }))
  }
  
  private func respond(response: NanoHTTPResponse, keepAlive: Bool) throws -> Bool {
    guard let server else {
      return false
    }
    // Some web-socket clients (like Jetfire) expects to have header section in a single packet.
    // We can't promise that but make sure we invoke "write" only once for response header section.
    var response = response
    let length: Int?
    let write: ((NanoHTTPResponseBodyWriter) throws -> Void)?
    do {
      (length, write) = try response.body.content()
    } catch {
      // The body could not be produced (a `.json` body that is not JSON). Nothing has been sent
      // yet, so the client can still be told that the server failed.
      server.log("Unable to produce the body of the response: \(error)")
      response = NanoHTTPResponse.internalServerError(.text("Internal Server Error"))
      (length, write) = try response.body.content()
    }
    var responseHeader = String()
    responseHeader.append("HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n")
    if let length, length >= 0 {
      responseHeader.append("Content-Length: \(length)\r\n")
      if keepAlive {
        responseHeader.append("Connection: keep-alive\r\n")
      }
    }
    for (name, value) in response.allHeaders() {
      guard NanoHTTPConnection.isValidHeaderName(name) else {
        server.log("Dropped a response header with an invalid name: \(String(reflecting: name))")
        continue
      }
      responseHeader.append("\(name): \(NanoHTTPConnection.sanitizedHeaderValue(value))\r\n")
    }
    responseHeader.append("\r\n")
    try self.socket.writeUTF8(responseHeader)
    if let write {
      try write(self.socket)
    }
    return keepAlive && length != nil
  }
}
