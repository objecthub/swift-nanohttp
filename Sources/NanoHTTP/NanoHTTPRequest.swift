//
//  NanoHTTPRequest.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `HttpRequest` of framework `Swifter` by Damian Kołakowski.
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

public final class NanoHTTPRequest: Hashable {
  
  /// The HTTP method
  public var method: String
  
  /// The request path
  public var path: String
  
  /// Sequence of query parameters
  public var queryParams: [(String, String)]
  
  /// Variables extracted by the router while matching the path with registered handlers
  public var params: [String : String] = [:]
  
  /// HTTP request headers (keys are case insensitive)
  private var headers: [String : String] = [:]
  
  /// HTTP request body
  public var body: [UInt8]
  
  /// Client (IP) address
  public var address: String? = nil
  
  /// Custom dictionary for middleware handlers to communicate/pass information
  public var custom: [String : Any] = [:]
  
  /// Initializer
  public init(method: String,
              path: String,
              queryParams: [(String, String)] = [],
              headers: [String : String] = [:],
              body: [UInt8] = []) {
    self.method = method
    self.path = path
    self.queryParams = queryParams
    self.headers = [:]
    self.body = body
    for (key, value) in headers {
      self.headers[key.lowercased()] = value
    }
  }
  
  public final var identity: UInt {
    return UInt(bitPattern: ObjectIdentifier(self))
  }
  
  public final func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  public var supportsKeepAlive: Bool {
    if let value = self.headers["connection"] {
      return value.trimmingCharacters(in: .whitespaces).lowercased() == "keep-alive"
    }
    return false
  }
  
  public func header(_ headerName: String) -> String? {
    guard let headerValue = self.headers[headerName.lowercased()] else {
      return nil
    }
    return headerValue
  }
  
  public func setHeader(_ headerName: String, to headerValue: String) {
    self.headers[headerName.lowercased()] = headerValue
  }
  
  public func includeHeaders(_ headers: [String : String]) {
    for (key, value) in headers {
      self.setHeader(key, to: value)
    }
  }
  
  public func removeHeader(_ headerName: String) {
    self.headers.removeValue(forKey: headerName.lowercased())
  }
  
  public var availableHeaders: [String] {
    return [String](self.headers.keys)
  }
  
  public func hasTokenForHeader(_ headerName: String, token: String) -> Bool {
    guard let headerValue = self.header(headerName) else {
      return false
    }
    return headerValue.components(separatedBy: ",")
                      .filter { $0.trimmingCharacters(in: .whitespaces).lowercased() == token }
                      .count > 0
  }
  
  public func parseUrlencodedForm() -> [(String, String)] {
    guard let contentTypeHeader = headers["content-type"] else {
      return []
    }
    let contentTypeHeaderTokens = contentTypeHeader
                                    .components(separatedBy: ";")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
    guard contentTypeHeaderTokens.first == "application/x-www-form-urlencoded" else {
      return []
    }
    guard let utf8String = String(bytes: body, encoding: .utf8) else {
      // Consider to throw an exception here (examine the encoding from headers).
      return []
    }
    return utf8String.components(separatedBy: "&").map { param -> (String, String) in
      let tokens = param.components(separatedBy: "=")
      guard tokens.count == 2,
            let name = tokens.first?.removingPercentEncoding,
            let value = tokens.last?.removingPercentEncoding else {
        return ("", "")
      }
      return (name.replacingOccurrences(of: "+", with: " "),
              value.replacingOccurrences(of: "+", with: " "))
    }
  }
  
  public struct MultiPart {
    public let headers: [String : String]
    public let body: [UInt8]
    
    public var name: String? {
      return valueFor("content-disposition", parameter: "name")?.unquote()
    }
    
    public var fileName: String? {
      return valueFor("content-disposition", parameter: "filename")?.unquote()
    }
    
    private func valueFor(_ headerName: String, parameter: String) -> String? {
      return headers.reduce([String]()) { (combined, header: (key: String, value: String)) -> [String] in
        guard header.key == headerName else {
          return combined
        }
        let headerValueParams = header.value.components(separatedBy: ";").map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        return headerValueParams.reduce(combined, { (results, token) -> [String] in
          let parameterTokens = token.components(separatedBy: "=")
          if parameterTokens.first == parameter, let value = parameterTokens.last {
            return results + [value]
          }
          return results
        })
      }.first
    }
  }
  
  public func parseMultiPartFormData() -> [MultiPart] {
    guard let contentTypeHeader = headers["content-type"] else {
      return []
    }
    let contentTypeHeaderTokens = contentTypeHeader
                                    .components(separatedBy: ";")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let contentType = contentTypeHeaderTokens.first,
          contentType == "multipart/form-data" else {
      return []
    }
    var boundary: String?
    contentTypeHeaderTokens.forEach({
      let tokens = $0.components(separatedBy: "=")
      if let key = tokens.first, key == "boundary" && tokens.count == 2 {
        boundary = tokens.last
      }
    })
    if let boundary = boundary, boundary.utf8.count > 0 {
      return parseMultiPartFormData(body, boundary: "--\(boundary)")
    }
    return []
  }
  
  private func parseMultiPartFormData(_ data: [UInt8], boundary: String) -> [MultiPart] {
    var generator = data.makeIterator()
    var result = [MultiPart]()
    while let part = nextMultiPart(&generator, boundary: boundary, isFirst: result.isEmpty) {
      result.append(part)
    }
    return result
  }
  
  private func nextMultiPart(_ generator: inout IndexingIterator<[UInt8]>,
                             boundary: String,
                             isFirst: Bool) -> MultiPart? {
    if isFirst {
      guard nextUTF8MultiPartLine(&generator) == boundary else {
        return nil
      }
    } else {
      _ = nextUTF8MultiPartLine(&generator)
    }
    var headers = [String: String]()
    while let line = nextUTF8MultiPartLine(&generator), !line.isEmpty {
      let tokens = line.components(separatedBy: ":")
      if let name = tokens.first, let value = tokens.last, tokens.count == 2 {
        headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
      }
    }
    guard let body = nextMultiPartBody(&generator, boundary: boundary) else {
      return nil
    }
    return MultiPart(headers: headers, body: body)
  }
  
  private func nextUTF8MultiPartLine(_ generator: inout IndexingIterator<[UInt8]>) -> String? {
    var temp = [UInt8]()
    while let value = generator.next() {
      if value > NanoHTTPRequest.CR {
        temp.append(value)
      }
      if value == NanoHTTPRequest.NL {
        break
      }
    }
    return String(bytes: temp, encoding: String.Encoding.utf8)
  }
  
  static let CR = UInt8(13)
  static let NL = UInt8(10)
  
  private func nextMultiPartBody(_ generator: inout IndexingIterator<[UInt8]>,
                                 boundary: String) -> [UInt8]? {
    var body = [UInt8]()
    let boundaryArray = [UInt8](boundary.utf8)
    var matchOffset = 0
    while let x = generator.next() {
      matchOffset = x == boundaryArray[matchOffset] ? matchOffset + 1 : 0
      body.append(x)
      if matchOffset == boundaryArray.count {
        body.removeSubrange(body.count-matchOffset ..< body.count)
        if body.last == NanoHTTPRequest.NL {
          body.removeLast()
          if body.last == NanoHTTPRequest.CR {
            body.removeLast()
          }
        }
        return body
      }
    }
    return nil
  }
  
  public static func ==(lhs: NanoHTTPRequest, rhs: NanoHTTPRequest) -> Bool {
    return lhs === rhs
  }
}
