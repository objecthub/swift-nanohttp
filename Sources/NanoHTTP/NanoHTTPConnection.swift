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

public typealias NanoHTTPRequestHandler = (NanoHTTPRequest) -> NanoHTTPResponse

public struct NanoHTTPConnection {
  public weak var server: NanoHTTPServerIO?
  public let parser: NanoHTTPParser
  public let request: NanoHTTPRequest
  public let handler: NanoHTTPRequestHandler
  
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
    let parser = NanoHTTPParser(socket: socket, limits: server.limits)
    self.parser = parser
    let request: NanoHTTPRequest
    do {
      request = try parser.readHttpRequest()
    } catch {
      NanoHTTPConnection.refuse(error, on: socket)
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
    self.request = request
    self.handler = handler
  }
  
  public var socket: NanoSocket {
    return self.parser.socket
  }
  
  public func send(_ response: NanoHTTPResponse,
                   dontKeepAlive: Bool = false) -> NanoHTTPConnection? {
    guard let server else {
      self.close()
      return nil
    }
    var keepConnection = request.supportsKeepAlive
    do {
      keepConnection = try server.operating &&
                         self.respond(response: response,
                                      keepAlive: keepConnection && !dontKeepAlive && server.operating)
    } catch {
      server.log("Failed to send response: \(error)")
    }
    if let session = response.socketSession() {
      server.delegate?.connectionReceived(server: server, socket: socket)
      session(socket)
    }
    if keepConnection && !dontKeepAlive && server.operating {
      do {
        let request = try parser.readHttpRequest()
        request.address = try? socket.peername()
        let (params, handler) = server.dispatch(request: request)
        request.params = params
        return NanoHTTPConnection(current: self, request: request, handler: handler)
      } catch {
        NanoHTTPConnection.refuse(error, on: socket)
      }
    }
    self.close()
    return nil
  }
  
  /// Answers a request that could not be read. Only errors caused by the request itself get a
  /// response (400, 413, 414 or 431); if the connection failed or the peer went away, there is
  /// nobody to answer. The caller closes the connection afterwards.
  private static func refuse(_ error: Error, on socket: NanoSocket) {
    guard let error = error as? NanoHTTPParserError else {
      return
    }
    let status: String
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
    try? socket.writeUTF8("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
    // The client may still be sending the rest of the refused request; see `closeAfterDraining`.
    socket.closeAfterDraining()
  }
  
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
    guard let server, server.operating else {
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
