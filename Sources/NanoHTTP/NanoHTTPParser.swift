//
//  NanoHTTPParser.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `HttpParser` of framework `Swifter` by Damian Kołakowski.
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

enum HttpParserError: Error, Equatable {
  case invalidStatusLine(String)
  case negativeContentLength
}

public struct HttpParser {
  public let socket: Socket
  
  public func readHttpRequest() throws -> HttpRequest {
    let statusLine = try self.socket.readLine()
    let statusLineTokens = statusLine.components(separatedBy: " ")
    if statusLineTokens.count < 3 {
      throw HttpParserError.invalidStatusLine(statusLine)
    }
    let request = HttpRequest()
    request.method = statusLineTokens[0]
    let path = statusLineTokens[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                 ?? statusLineTokens[1]
    let urlComponents = URLComponents(string: path)
    request.path = urlComponents?.path ?? ""
    request.queryParams = urlComponents?.queryItems?.map { ($0.name, $0.value ?? "") } ?? []
    request.headers = try readHeaders()
    if let contentLength = request.headers["content-length"],
       let contentLengthValue = Int(contentLength) {
      // Prevent a buffer overflow and runtime error trying to create an
      // `UnsafeMutableBufferPointer` with a negative length.
      guard contentLengthValue >= 0 else {
        throw HttpParserError.negativeContentLength
      }
      request.body = try readBody(size: contentLengthValue)
    }
    return request
  }
  
  private func readBody(size: Int) throws -> [UInt8] {
    return try self.socket.read(length: size)
  }
  
  private func readHeaders() throws -> [String: String] {
    var headers = [String: String]()
    while case let headerLine = try self.socket.readLine(), !headerLine.isEmpty {
      let headerTokens = headerLine.split(separator: ":",
                                          maxSplits: 1,
                                          omittingEmptySubsequences: true).map(String.init)
      if let name = headerTokens.first,
         let value = headerTokens.last {
        headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
      }
    }
    return headers
  }
}
