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

public typealias HttpRequestHandler = (HttpRequest) -> HttpResponse

public struct HttpConnection {
  public weak var server: HttpServerIO?
  public let parser: HttpParser
  public let request: HttpRequest
  public let handler: HttpRequestHandler
  
  internal init?(server: HttpServerIO, socket: Socket) {
    server.remember(socket: socket)
    self.server = server
    self.parser = HttpParser(socket: socket)
    guard let request = try? self.parser.readHttpRequest() else {
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
  
  private init(current: HttpConnection,
               request: HttpRequest,
               handler: @escaping HttpRequestHandler) {
    self.server = current.server
    self.parser = current.parser
    self.request = request
    self.handler = handler
  }
  
  public var socket: Socket {
    return self.parser.socket
  }
  
  public func send(_ response: HttpResponse) -> HttpConnection? {
    guard let server else {
      self.close()
      return nil
    }
    var keepConnection = request.supportsKeepAlive
    do {
      if server.operating {
        keepConnection = try self.respond(response: response, keepAlive: keepConnection)
      }
    } catch {
      server.log("Failed to send response: \(error)")
    }
    if let session = response.socketSession() {
      server.delegate?.connectionReceived(server: server, socket: socket)
      session(socket)
    }
    if keepConnection, server.operating, let request = try? parser.readHttpRequest() {
      let request = request
      request.address = try? socket.peername()
      let (params, handler) = server.dispatch(request: request)
      request.params = params
      return HttpConnection(current: self, request: request, handler: handler)
    }
    self.close()
    return nil
  }
  
  public func close() {
    self.socket.close()
    self.server?.forget(socket: self.socket)
  }
  
  private func respond(response: HttpResponse, keepAlive: Bool) throws -> Bool {
    guard let server, server.operating else {
      return false
    }
    // Some web-socket clients (like Jetfire) expects to have header section in a single packet.
    // We can't promise that but make sure we invoke "write" only once for response header section.
    var responseHeader = String()
    responseHeader.append("HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n")
    let content = response.content()
    if content.length >= 0 {
      responseHeader.append("Content-Length: \(content.length)\r\n")
    }
    if keepAlive && content.length != -1 {
      responseHeader.append("Connection: keep-alive\r\n")
    }
    for (name, value) in response.headers() {
      responseHeader.append("\(name): \(value)\r\n")
    }
    responseHeader.append("\r\n")
    try self.socket.writeUTF8(responseHeader)
    if let writeClosure = content.write {
      let context = InnerWriteContext(socket: socket)
      try writeClosure(context)
    }
    return keepAlive && content.length != -1
  }
  
  private struct InnerWriteContext: HttpResponseBodyWriter {
    let socket: Socket
    
    func write(_ file: String.File) throws {
      try socket.writeFile(file)
    }
    
    func write(_ data: [UInt8]) throws {
      try write(ArraySlice(data))
    }
    
    func write(_ data: ArraySlice<UInt8>) throws {
      try socket.writeUInt8(data)
    }
    
    func write(_ data: Data) throws {
      try socket.writeData(data)
    }
  }
}
