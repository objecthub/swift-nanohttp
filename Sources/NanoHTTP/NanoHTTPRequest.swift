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
  
  /// The version of the protocol that the client speaks, as it is in the request line: `"HTTP/1.1"` or
  /// `"HTTP/1.0"`.
  public var httpVersion: String
  
  /// The path of the request as the client sent it, still percent-encoded (`/a%20b/%C3%A9`), without the query.
  /// The router matches this, one segment at a time, so that an encoded slash (`%2F`) stays inside its
  /// segment. Use ``path`` to read the path; set `rawPath` (for example in middleware) to route the request
  /// to another path.
  public var rawPath: String
  
  /// The path of the request, **decoded**: `/a%20b/%C3%A9` is `/a b/é`. A `+` stays a `+`, and `%2F` is a `/`
  /// that cannot be told from a separator any more (``rawPath`` can). Text that is not valid percent-encoding
  /// is kept as it is, and bytes that are not valid UTF-8 become U+FFFD.
  ///
  /// The decoded path can contain anything, line breaks and NUL characters included (`%0A`, `%00`): do not
  /// write it to a log or into HTML as it is (`htmlEscaped`), and do not use it as a file path without
  /// checking it (see `NanoFiles.share(directory:)`). It is decoded **once**: decoding it again turns `%252e%252e`
  /// into `..`.
  ///
  /// Setting the path percent-encodes it into ``rawPath``.
  public var path: String {
    get {
      return self.rawPath.percentDecoded()
    }
    set(path) {
      self.rawPath = path.percentEncodedAsPath
    }
  }
  
  /// The query of the request as the client sent it, still percent-encoded, without the `?`: `q=a%20b&r=1`.
  /// `nil` if the target has no `?`. It is not changed when ``queryParams`` is.
  public var rawQuery: String?
  
  /// The query parameters in the order of the request, repeated names included. Names and values are
  /// **decoded**: `?q=a%20b+c` gives `("q", "a b c")`; `+` is a space, and `%2B` is a plus. A parameter
  /// without `=` has an empty value. See ``query(_:)`` and ``queries(_:)``.
  public var queryParams: [(String, String)]
  
  /// The variables of the route that matched (`/users/:id` gives `["id": "42"]`); empty if the route has none.
  /// Their values are **decoded**, also those of path variables (`/files/::path`), which are the decoded
  /// segments joined with `/`.
  public var params: [String : String] = [:]
  
  /// HTTP request headers (keys are case insensitive)
  private var headers: [String : String] = [:]
  
  /// The body of the request, as many bytes as `Content-Length` announced (and the server's limit allowed); empty otherwise.
  public var body: [UInt8]
  
  /// The IP address of the client (`"192.168.1.20"`, `"::1"`), if it could be determined.
  public var address: String? = nil
  
  /// Free space for the application, for example for middleware to hand information to handlers.
  public var custom: [String : Any] = [:]

  /// Has the answer been promised for later (``NanoHTTPConnection/deferResponse()``)? The server of one thread looks
  /// at it after `handle(connection:)` has returned: a connection that waits for its answer is not read.
  var isDeferred = false

  /// The token of the deferred answer. Weak: the token holds the connection, which holds this request.
  weak var deferral: NanoHTTPDeferredResponse? = nil
  
  /// The bounds for `parseMultiPartFormData()`: the most parts, and the most bytes for the headers of a part. The
  /// parser sets them from the limits of the server.
  var multipartLimits: (parts: Int, headerBytes: Int) = (1000, 16 * 1024)

  /// Creates a request, for example to call a handler directly in a test. `path` and the names and values of
  /// `queryParams` are decoded text, as the properties of the same names (`"/a b"`, not `"/a%20b"`); the
  /// names of `headers` are case-insensitive.
  public init(method: String,
              path: String,
              queryParams: [(String, String)] = [],
              headers: [String : String] = [:],
              body: [UInt8] = [],
              httpVersion: String = "HTTP/1.1") {
    self.method = method
    self.httpVersion = httpVersion
    self.rawPath = path.percentEncodedAsPath
    self.queryParams = queryParams
    self.rawQuery = queryParams.isEmpty
      ? nil
      : queryParams.map { $0.0.percentEncodedAsQueryComponent + "=" + $0.1.percentEncodedAsQueryComponent }
                   .joined(separator: "&")
    self.body = body
    self.setHeaders(headers)
  }
  
  /// Creates a request from the path and the query as they are in the target of a request line, still
  /// percent-encoded (`"/a%20b"`, `"q=a%20b"`). The parser creates requests this way.
  public init(method: String,
              rawPath: String,
              rawQuery: String?,
              headers: [String : String] = [:],
              body: [UInt8] = [],
              httpVersion: String = "HTTP/1.1") {
    self.method = method
    self.httpVersion = httpVersion
    self.rawPath = rawPath
    self.rawQuery = rawQuery
    self.queryParams = rawQuery.map { NanoHTTPRequest.parseQuery($0) } ?? []
    self.body = body
    self.setHeaders(headers)
  }
  
  private func setHeaders(_ headers: [String : String]) {
    for (key, value) in headers {
      self.headers[key.lowercased()] = value
    }
  }
  
  /// The names and values of a query string or of an `application/x-www-form-urlencoded` body, decoded:
  /// pairs are separated by `&`, a name ends at the first `=`, a pair without `=` has an empty value,
  /// empty pairs are skipped.
  static func parseQuery<S: StringProtocol>(_ text: S) -> [(String, String)] {
    return text.split(separator: "&", omittingEmptySubsequences: true).map { pair -> (String, String) in
      guard let separator = pair.firstIndex(of: "=") else {
        return (String(pair).percentDecoded(plusAsSpace: true), "")
      }
      return (String(pair[pair.startIndex..<separator]).percentDecoded(plusAsSpace: true),
              String(pair[pair.index(after: separator)...]).percentDecoded(plusAsSpace: true))
    }
  }
  
  /// The value of the first query parameter with this name (names are case-sensitive), or `nil`. An empty
  /// string if the parameter has no value (`?debug`).
  public func query(_ name: String) -> String? {
    return self.queryParams.first { $0.0 == name }?.1
  }
  
  /// The values of all query parameters with this name, in the order of the request.
  public func queries(_ name: String) -> [String] {
    return self.queryParams.filter { $0.0 == name }.map { $0.1 }
  }
  
  /// A number that identifies this request object while it exists.
  public final var identity: UInt {
    return UInt(bitPattern: ObjectIdentifier(self))
  }
  
  /// Requests are hashed by identity.
  public final func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  /// Whether the client wants the connection to be kept open after the response: HTTP/1.1 connections are
  /// persistent unless the request has `Connection: close`; HTTP/1.0 connections are closed unless the
  /// request has `Connection: keep-alive`.
  public var supportsKeepAlive: Bool {
    if self.hasTokenForHeader("connection", token: "close") {
      return false
    }
    return self.httpVersion != "HTTP/1.0" || self.hasTokenForHeader("connection", token: "keep-alive")
  }
  
  /// Whether the request says `Connection: keep-alive`, which a response confirms.
  var asksForKeepAlive: Bool {
    return self.hasTokenForHeader("connection", token: "keep-alive")
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
    // The name ends at the first "=", so a value may contain "=" (base64 padding, for example). A
    // pair without "=" is a name with an empty value.
    return NanoHTTPRequest.parseQuery(utf8String)
  }
  
  // MARK: - The body as text and as JSON
  
  /// The body as text, in the charset of the `Content-Type` header (`text/plain; charset=iso-8859-1`), or
  /// in UTF-8 if the header has none or names a charset that is not known. `nil` if the bytes are not
  /// valid text in that charset. An empty body is the empty string.
  public var bodyString: String? {
    return String(bytes: self.body, encoding: self.bodyEncoding)
  }
  
  /// The encoding that the `Content-Type` header names with its `charset` parameter.
  private var bodyEncoding: String.Encoding {
    guard let contentType = self.headers["content-type"] else {
      return .utf8
    }
    for parameter in contentType.split(separator: ";").dropFirst() {
      let pair = parameter.split(separator: "=", maxSplits: 1)
      guard pair.count == 2,
            pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else {
        continue
      }
      let name = pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
      if encoding != kCFStringEncodingInvalidId {
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
      }
    }
    return .utf8
  }
  
  /// Decodes the body as JSON into a value of type `T`.
  ///
  /// ```swift
  /// struct Person: Decodable { let name: String; let age: Int }
  /// let server = NanoHTTPServer()
  /// server.post["/people"] = { request in
  ///   let person = try request.json(Person.self)
  ///   return .ok(.text("\(person.name) is \(person.age)"))
  /// }
  /// ```
  ///
  /// The `Content-Type` is not looked at. A body that is empty, is not JSON, or does not fit `T` makes this
  /// throw ``NanoHTTPError/badRequest(_:headers:)`` with a message that tells the client what is wrong
  /// (`The key 'age' is missing`), so that a handler that does not catch the error answers `400`.
  ///
  /// - Parameters:
  ///   - type: The type to decode; it can be inferred from the context.
  ///   - decoder: The decoder to use, for another strategy for keys or dates.
  public func json<T: Decodable>(_ type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
    guard !self.body.isEmpty else {
      throw NanoHTTPError.badRequest("The request body is empty, JSON was expected")
    }
    do {
      return try decoder.decode(type, from: Data(self.body))
    } catch let error as DecodingError {
      throw NanoHTTPError.badRequest(NanoHTTPRequest.describe(error))
    } catch {
      throw NanoHTTPError.badRequest("The request body is not valid JSON")
    }
  }
  
  /// Parses the body as JSON of any shape: dictionaries, arrays, strings, numbers, booleans and `NSNull`.
  /// Throws ``NanoHTTPError/badRequest(_:headers:)`` if the body is empty or not valid JSON.
  public func jsonObject() throws -> Any {
    guard !self.body.isEmpty else {
      throw NanoHTTPError.badRequest("The request body is empty, JSON was expected")
    }
    do {
      return try JSONSerialization.jsonObject(with: Data(self.body), options: [.fragmentsAllowed])
    } catch {
      throw NanoHTTPError.badRequest("The request body is not valid JSON")
    }
  }
  
  /// What is wrong with a body that does not decode, in a sentence for the client: where, and what.
  private static func describe(_ error: DecodingError) -> String {
    func location(_ path: [CodingKey]) -> String {
      return path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
    switch error {
      case .keyNotFound(let key, let context):
        return "The key '\(location(context.codingPath + [key]))' is missing"
      case .typeMismatch(let type, let context):
        return "The value of '\(location(context.codingPath))' has the wrong type, \(type) was expected"
      case .valueNotFound(let type, let context):
        return "The value of '\(location(context.codingPath))' is missing, \(type) was expected"
      case .dataCorrupted(let context):
        return context.codingPath.isEmpty
          ? "The request body is not valid JSON"
          : "The value of '\(location(context.codingPath))' is not valid"
      @unknown default:
        return "The request body is not valid JSON"
    }
  }
  
  /// One part of a `multipart/form-data` body (an uploaded file or a form field): its headers and its
  /// content. See ``NanoHTTPRequest/parseMultiPartFormData()``.
  public struct MultiPart {
    /// The headers of the part, with names in lower case.
    public let headers: [String : String]
    /// The content of the part.
    public let body: [UInt8]
    
    /// The name of the form field (`name="..."` of `Content-Disposition`), without quotes. A name that is given in
    /// the extended form (`name*=UTF-8''...`) takes precedence.
    public var name: String? {
      return self.contentDispositionParameter("name")
    }
    
    /// The file name of an upload (`filename="..."` of `Content-Disposition`), without quotes; `nil` for ordinary
    /// fields. The extended form (`filename*=UTF-8''%E2%82%AC.txt`) takes precedence if it is there. The name is
    /// what the client sent: do not use it as a path without checking it (it can hold `/` and `..`).
    public var fileName: String? {
      return self.contentDispositionParameter("filename")
    }
    
    private func contentDispositionParameter(_ name: String) -> String? {
      guard let header = self.headers["content-disposition"] else {
        return nil
      }
      let parameters = NanoHeaderParameters(header)
      if let extended = parameters[name + "*"], let decoded = NanoHeaderParameters.decodeExtended(extended) {
        return decoded
      }
      return parameters[name]
    }
  }
  
  /// Requests are equal if they are the same object.
  public static func ==(lhs: NanoHTTPRequest, rhs: NanoHTTPRequest) -> Bool {
    return lhs === rhs
  }
}
