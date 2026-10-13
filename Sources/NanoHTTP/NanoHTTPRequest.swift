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

/// An HTTP request: method, path, query, headers and body, plus the address of the client and the
/// variables of the route that matched. The server creates one for every request and hands it to
/// middleware and handlers. A request is a reference type, compared and hashed by identity.
///
/// ```swift
/// let server = NanoHTTPServer()
/// server.post["/users/:id"] = { request in
///   let id = request.params["id"] ?? ""
///   let agent = request.header("User-Agent") ?? "unknown"
///   return .ok(.text("user \(id), \(request.body.count) bytes from \(agent)"))
/// }
/// ```
public final class NanoHTTPRequest: Hashable {
  
  /// The HTTP method in the form the client sent it, normally in upper case (`"GET"`, `"POST"`).
  public var method: String
  
  /// The path of the request as the client sent it: **still percent-encoded** (`/a%20b`), without the query.
  /// The router decodes the segments it matches; decode the path yourself (`removingPercentEncoding`)
  /// if you use it for something else.
  public var path: String
  
  /// The query parameters in the order of the request, repeated names included. Names and values are
  /// **not decoded**: `?q=a%20b` gives `("q", "a%20b")` (decode with `removingPercentEncoding`; a `+` stays a `+`).
  public var queryParams: [(String, String)]
  
  /// The variables of the route that matched (`/users/:id` gives `["id": "42"]`); empty if the route has none.
  public var params: [String : String] = [:]
  
  /// HTTP request headers (keys are case insensitive)
  private var headers: [String : String] = [:]
  
  /// The body of the request, as many bytes as `Content-Length` announced (and the server's limit allowed); empty otherwise.
  public var body: [UInt8]
  
  /// The IP address of the client (`"192.168.1.20"`, `"::1"`), if it could be determined.
  public var address: String? = nil
  
  /// Free space for the application, for example for middleware to hand information to handlers.
  public var custom: [String : Any] = [:]
  
  /// Creates a request, for example to call a handler directly in a test. The names of `headers` are
  /// case-insensitive.
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
  
  /// A number that identifies this request object while it exists.
  public final var identity: UInt {
    return UInt(bitPattern: ObjectIdentifier(self))
  }
  
  /// Requests are hashed by identity.
  public final func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  /// Whether the client asked for the connection to be kept open after the response: only if the request
  /// has the header `Connection: keep-alive`. (Without it the server closes the connection after the
  /// response, although HTTP/1.1 connections are persistent by default.)
  public var supportsKeepAlive: Bool {
    if let value = self.headers["connection"] {
      return value.trimmingCharacters(in: .whitespaces).lowercased() == "keep-alive"
    }
    return false
  }
  
  /// The value of a header, or `nil`. The name is case-insensitive. If the client sent a header several
  /// times, the values are joined with `, `.
  public func header(_ headerName: String) -> String? {
    guard let headerValue = self.headers[headerName.lowercased()] else {
      return nil
    }
    return headerValue
  }
  
  /// Sets a header, replacing an existing one of the same (case-insensitive) name.
  public func setHeader(_ headerName: String, to headerValue: String) {
    self.headers[headerName.lowercased()] = headerValue
  }
  
  /// Sets all the given headers; see ``setHeader(_:to:)``.
  public func includeHeaders(_ headers: [String : String]) {
    for (key, value) in headers {
      self.setHeader(key, to: value)
    }
  }
  
  /// Removes a header; the name is case-insensitive.
  public func removeHeader(_ headerName: String) {
    self.headers.removeValue(forKey: headerName.lowercased())
  }
  
  /// The names of the headers of the request, in lower case, in no particular order.
  public var availableHeaders: [String] {
    return [String](self.headers.keys)
  }
  
  /// Whether the value of a header that is a comma-separated list (`Connection: keep-alive, Upgrade`)
  /// contains `token`. The list items are compared case-insensitively, so `token` has to be given in
  /// lower case.
  public func hasTokenForHeader(_ headerName: String, token: String) -> Bool {
    guard let headerValue = self.header(headerName) else {
      return false
    }
    return headerValue.components(separatedBy: ",")
                      .filter { $0.trimmingCharacters(in: .whitespaces).lowercased() == token }
                      .count > 0
  }
  
  /// The fields of an `application/x-www-form-urlencoded` body (the encoding of an HTML form), in
  /// the order in which they appear; repeated names are kept. Names and values are decoded: `+`
  /// is a space, `%XX` a byte of UTF-8 text. A field without `=` is a name with an empty value.
  /// Returns an empty array if the request has another content type or the body is not UTF-8.
  public func parseUrlencodedForm() -> [(String, String)] {
    guard let contentTypeHeader = headers["content-type"] else {
      return []
    }
    let contentTypeHeaderTokens = contentTypeHeader
                                    .components(separatedBy: ";")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
    guard contentTypeHeaderTokens.first?.lowercased() == "application/x-www-form-urlencoded" else {
      return []
    }
    guard let utf8String = String(bytes: body, encoding: .utf8) else {
      // Consider to throw an exception here (examine the encoding from headers).
      return []
    }
    return utf8String.split(separator: "&", omittingEmptySubsequences: true).map { pair -> (String, String) in
      // The name ends at the first "=", so a value may contain "=" (base64 padding, for example). A
      // pair without "=" is a name with an empty value.
      guard let separator = pair.firstIndex(of: "=") else {
        return (String(pair).formDecoded(), "")
      }
      return (String(pair[pair.startIndex..<separator]).formDecoded(),
              String(pair[pair.index(after: separator)...]).formDecoded())
    }
  }
  
  /// One part of a `multipart/form-data` body (an uploaded file or a form field): its headers and its
  /// content. See ``NanoHTTPRequest/parseMultiPartFormData()``.
  public struct MultiPart {
    /// The headers of the part, with names in lower case.
    public let headers: [String : String]
    /// The content of the part.
    public let body: [UInt8]
    
    /// The name of the form field (`name="..."` of `Content-Disposition`), without quotes.
    public var name: String? {
      return valueFor("content-disposition", parameter: "name")?.unquote()
    }
    
    /// The file name of an upload (`filename="..."` of `Content-Disposition`), without quotes; `nil` for ordinary fields.
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
  
  /// The parts of a `multipart/form-data` body (a form with file uploads), in order. Returns an empty
  /// array if the request has another content type or the body is malformed. The whole body is in
  /// memory, see ``NanoHTTPParser/Limits/maxBodyBytes``.
  ///
  /// Limitations: names and file names that contain `;`, `=` or `:`, and quoted boundaries, are not
  /// parsed correctly.
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
  
  /// Requests are equal if they are the same object.
  public static func ==(lhs: NanoHTTPRequest, rhs: NanoHTTPRequest) -> Bool {
    return lhs === rhs
  }
}

extension String {
  /// Decodes one name or value of an `application/x-www-form-urlencoded` body: `+` is a space
  /// (decided before the percent sequences are decoded, so that `%2B` stays a plus), `%XX` is the
  /// byte `XX`, and the bytes are read as UTF-8. A `%` that is not followed by two hexadecimal
  /// digits is kept as it is.
  func formDecoded() -> String {
    let input = Array(self.utf8)
    var bytes = [UInt8]()
    bytes.reserveCapacity(input.count)
    func hexValue(_ digit: UInt8) -> UInt8? {
      switch digit {
        case 48...57: return digit - 48
        case 65...70: return digit - 55
        case 97...102: return digit - 87
        default: return nil
      }
    }
    var index = 0
    while index < input.count {
      let byte = input[index]
      if byte == 43 { // "+"
        bytes.append(32)
        index += 1
      } else if byte == 37, index + 2 < input.count,
                let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
        bytes.append(high << 4 | low)
        index += 3
      } else {
        bytes.append(byte)
        index += 1
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
