//
//  NanoHTTPResponse.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `HttpResponse` of framework `Swifter` by Damian Kołakowski.
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

/// The answer to a request: a status code, headers and a body. Use the static functions
/// to create the common responses:
///
/// ```swift
/// let responses: [NanoHTTPResponse] = [
///   .ok(.text("Hello")),                                      // 200, text/plain
///   .ok(headers: ["Cache-Control": "no-store"], .json(["id": 7])),
///   .created(),                                               // 201
///   .movedTemporarily("/login"),                              // 307 with a Location header
///   .notFound(.text("No such item")),                         // 404
///   NanoHTTPResponse(statusCode: 418, body: "short and stout")
/// ]
/// ```
///
/// The server adds `Content-Length` (for bodies of known length), `Connection` and the
/// `Content-Type` of the body; it does not add `Date` or `Server`.
public struct NanoHTTPResponse {
  
  /// The content of a response. A string literal is a `.text` body, so `.ok("Hello")` works.
  public enum Body: ExpressibleByStringLiteral {
    
    /// No content (`Content-Length: 0`).
    case empty
    
    /// Plain text, sent as UTF-8 with the content type `text/plain; charset=utf-8`.
    case text(String)
    
    /// HTML, sent as UTF-8 with the content type `text/html; charset=utf-8`. The string
    /// is the whole document; ``htmlBody(_:)`` wraps content in the basic elements.
    case html(String)
    
    /// A JSON document, content type `application/json`. The value is a dictionary or array
    /// of Foundation values (strings, numbers, booleans, `NSNull`, nested dictionaries and
    /// arrays), which `JSONSerialization` writes, or any `Encodable` value (a model, a
    /// collection of models, a recursive enum for JSON values like the `JSON` type of the
    /// package DynamicJSON), which a `JSONEncoder` writes. To choose the settings of the
    /// encoder, use ``NanoHTTPResponse/json(_:status:headers:encoder:)``. If the value is
    /// neither, or the encoder fails, the server answers `500 Internal Server Error` and
    /// logs the reason.
    case json(Any)
    
    /// Bytes with a content type (`application/octet-stream` if none is given).
    case data(Data, contentType: String? = nil)
    
    /// A body that a function writes to the connection, for content that is not available as
    /// a whole or too large to hold in memory. Whatever the function writes is sent at once.
    /// Its length is not known, so the body is sent in chunks (`Transfer-Encoding: chunked`)
    /// and the connection can be used for the next request; an HTTP/1.0 client, which does
    /// not know chunks, gets the body up to the end of the connection. If the handler sets a
    /// `Content-Length` header, the body is sent with that length instead: the function has
    /// to write exactly that many bytes, or the connection is closed after the response.
    case custom((NanoHTTPResponseBodyWriter) throws -> Void, contentType: String? = nil)
    
    /// The connection becomes something else than HTTP, see
    /// ``NanoHTTPResponse/switchProtocols(_:_:)``.
    case socket((NanoSocket) -> Void)
    
    /// The connection becomes something else than HTTP, and the server drives a session,
    /// see ``NanoHTTPResponse/switchProtocols(_:session:)``.
    case session(NanoSocketSession)
    
    /// A string literal is a `.text` body.
    public init(stringLiteral value: String) {
      self = .text(value)
    }
    
    /// An `.html` body with a complete document around `content`:
    /// `<html><meta charset="UTF-8"><body>content</body></html>`. The content is inserted
    /// as it is: escape text that does not come from you with `String.htmlEscaped`.
    public static func htmlBody(_ content: String) -> Body {
      return .html("<html><meta charset=\"UTF-8\"><body>\(content)</body></html>")
    }
    
    /// The `Content-Type` that the body implies; `nil` for bodies without one.
    public func contentType() -> String? {
      switch self {
        case .empty:
          return nil
        case .text(_):
          return "text/plain; charset=utf-8"
        case .html(_):
          return "text/html; charset=utf-8"
        case .json(_):
          return "application/json"
        case .data(_, let contentType):
          return contentType ?? "application/octet-stream"
        case .custom(_, let contentType):
          return contentType
        case .socket(_), .session(_):
          return nil
      }
    }
    
    /// The JSON text of the value of a `.json` body: Foundation values are written by
    /// `JSONSerialization`, any other `Encodable` value by a `JSONEncoder`.
    ///
    /// - Throws: ``ResponseError/invalidObject`` for a value that is neither, or the
    ///           error of the encoder.
    static func jsonData(for object: Any) throws -> Data {
      if JSONSerialization.isValidJSONObject(object) {
        return try JSONSerialization.data(withJSONObject: object)
      }
      guard let encodable = object as? Encodable else {
        throw ResponseError.invalidObject
      }
      return try JSONEncoder().encode(encodable)
    }
    
    /// The length of the body (`nil` if unknown) and a function that writes it. Throws if
    /// the body cannot be produced, which only happens for `.json` with something that
    /// cannot be written as JSON.
    func content() throws -> (Int?, ((NanoHTTPResponseBodyWriter) throws -> Void)?) {
      switch self {
        case .empty:
          return (0, nil)
        case .text(let body):
          let data = [UInt8](body.utf8)
          return (data.count, { try $0.write(data) })
        case .html(let html):
          let data = [UInt8](html.utf8)
          return (data.count, { try $0.write(data) })
        case .json(let object):
          let data = try Body.jsonData(for: object)
          return (data.count, { try $0.write(data) })
        case .data(let data, _):
          return (data.count, { try $0.write(data) })
        case .custom(let content, _):
          return (nil, content)
        case .socket(_), .session(_):
          return (nil, nil)
      }
    }
  }
  
  /// Errors that occur when the body of a response is produced.
  public enum ResponseError: Error {
    /// The value of a `.json` body is neither Foundation JSON nor `Encodable`.
    case invalidObject
  }
  
  /// The HTTP status code (`200`, `404`, ...). The reason phrase is derived from it,
  /// see ``reasonPhrase``.
  public var statusCode: Int
  
  /// The headers of the response, besides the ones that the server writes itself
  /// (`Content-Length`, `Connection`) and the `Content-Type` of the body, see
  /// ``allHeaders()``. A header name must be a valid token; line breaks in values
  /// are replaced by spaces.
  public var headers: [String : String]
  
  /// The body of the response.
  public var body: Body
  
  /// The cookies that the response asks the client to store. The server writes one
  /// `Set-Cookie` header for each of them (the dictionary ``headers`` cannot hold
  /// several headers of the same name), after the other headers; a header `Set-Cookie`
  /// in ``headers`` is still sent too. See ``NanoHTTPCookie`` for what a cookie that
  /// is sent looks like, and what makes the server leave one out. ``allHeaders()``
  /// does not have the cookies.
  public var cookies: [NanoHTTPCookie]
  
  /// Creates a response with any status code.
  public init(statusCode: Int, headers: [String : String] = [:], body: Body = .empty) {
    self.init(statusCode: statusCode, headers: headers, body: body, cookies: [])
  }
  
  /// Creates a response with any status code, and cookies.
  public init(statusCode: Int,
              headers: [String : String] = [:],
              body: Body = .empty,
              cookies: [NanoHTTPCookie]) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
    self.cookies = cookies
  }
  
  /// Adds a cookie to the response, replacing the cookie that has the same name, path and
  /// domain.
  public mutating func setCookie(_ cookie: NanoHTTPCookie) {
    if let index = self.cookies.firstIndex(where: {
      $0.name == cookie.name && $0.path == cookie.path && $0.domain == cookie.domain
    }) {
      self.cookies[index] = cookie
    } else {
      self.cookies.append(cookie)
    }
  }
  
  /// Asks the client to delete the cookie with this name. The path and domain have to be the
  /// ones that the cookie was set with.
  public mutating func deleteCookie(named name: String, path: String? = "/", domain: String? = nil) {
    self.setCookie(NanoHTTPCookie.expired(name: name, path: path, domain: domain))
  }
  
  /// A response with a JSON body that encodes `value`, which is the way to answer with a
  /// model.
  ///
  /// ```swift
  /// // file scope
  /// struct ExampleProduct: Encodable {
  ///   let id: Int
  ///   let name: String
  /// }
  /// ```
  ///
  /// ```swift
  /// let server = NanoHTTPServer()
  /// server.get["/products/:id"] = { request in
  ///   try .json(ExampleProduct(id: 7, name: "Lamp"))   // {"id":7,"name":"Lamp"}
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - value: What to encode.
  ///   - status: The status code of the response.
  ///   - headers: The headers of the response.
  ///   - encoder: The encoder to use, for dates or a pretty-printed form, for example.
  /// - Throws: The error of the encoder, which the server answers with
  ///           `500 Internal Server Error` and logs, like any error that a handler throws.
  public static func json<T: Encodable>(_ value: T,
                                        status: Int = 200,
                                        headers: [String : String] = [:],
                                        encoder: JSONEncoder = JSONEncoder()) throws -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: status,
                            headers: headers,
                            body: .data(try encoder.encode(value), contentType: "application/json"))
  }
  
  /// A `200 OK` response.
  public static func ok(headers: [String : String] = [:], _ body: Body) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 200, headers: headers, body: body)
  }
  
  /// A `201 Created` response without a body.
  public static func created() -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 201)
  }
  
  /// A `202 Accepted` response without a body.
  public static func accepted() -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 202)
  }
  
  /// A `101 Switching Protocols` response. After the response was sent, `socketSession`
  /// runs on the thread of the connection and owns the socket until it returns; the
  /// connection is closed afterwards.
  ///
  /// On a server that has only one thread, nothing else is served while `socketSession`
  /// runs. Use ``switchProtocols(_:session:)`` for a session that the server can drive
  /// between other work.
  public static func switchProtocols(_ headers: [String : String],
                                     _ socketSession: @escaping (NanoSocket) -> Void) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 101, headers: headers, body: .socket(socketSession))
  }
  
  /// A `101 Switching Protocols` response for a session that the server drives. After the
  /// response was sent, the server calls the functions of `session` when the socket has
  /// something to read, see ``NanoSocketSession``. Unlike the other variant, this does
  /// not hold the thread of a server that has only one thread: this is how the handler of
  /// ``NanoWebSocket`` upgrades a connection.
  public static func switchProtocols(_ headers: [String : String],
                                     session: NanoSocketSession) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 101, headers: headers, body: .session(session))
  }
  
  /// A `301 Moved Permanently` response that points to `location`.
  public static func movedPermanently(_ location: String,
                                      _ headers: [String : String] = [:]) -> NanoHTTPResponse {
    var headers = headers
    headers["Location"] = location
    return NanoHTTPResponse(statusCode: 301, headers: headers)
  }
  
  /// A `307 Temporary Redirect` response that points to `location` (the method of the
  /// request is kept).
  public static func movedTemporarily(_ location: String,
                                      _ headers: [String : String] = [:]) -> NanoHTTPResponse {
    var headers = headers
    headers["Location"] = location
    return NanoHTTPResponse(statusCode: 307, headers: headers)
  }
  
  /// A `303 See Other` response that points to `location`: the client fetches it with `GET`,
  /// whatever the method of the request was. This is how to answer a form that was posted
  /// (the post/redirect/get pattern).
  public static func seeOther(_ location: String,
                              _ headers: [String : String] = [:]) -> NanoHTTPResponse {
    var headers = headers
    headers["Location"] = location
    return NanoHTTPResponse(statusCode: 303, headers: headers)
  }
  
  /// A `307 Temporary Redirect` response that points to `location` (the method and the body
  /// of the request are kept). The same as ``movedTemporarily(_:_:)``.
  public static func temporaryRedirect(_ location: String,
                                       _ headers: [String : String] = [:]) -> NanoHTTPResponse {
    return NanoHTTPResponse.movedTemporarily(location, headers)
  }
  
  /// A `308 Permanent Redirect` response that points to `location` (the method and the body
  /// of the request are kept, unlike with ``movedPermanently(_:_:)``).
  public static func permanentRedirect(_ location: String,
                                       _ headers: [String : String] = [:]) -> NanoHTTPResponse {
    var headers = headers
    headers["Location"] = location
    return NanoHTTPResponse(statusCode: 308, headers: headers)
  }
  
  /// A `204 No Content` response: the request succeeded and there is nothing to send back.
  public static func noContent(headers: [String : String] = [:]) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 204, headers: headers)
  }
  
  /// A `304 Not Modified` response: the copy of the client is current. Send the `ETag`
  /// (and `Last-Modified`) that the response with the content would have.
  public static func notModified(headers: [String : String] = [:]) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 304, headers: headers)
  }
  
  /// A `400 Bad Request` response.
  public static func badRequest(headers: [String : String] = [:],
                                _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 400, headers: headers, body: body)
  }
  
  /// A `401 Unauthorized` response. Add a `WWW-Authenticate` header if the client can
  /// authenticate.
  public static func unauthorized(headers: [String : String] = [:],
                                  _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 401, headers: headers, body: body)
  }
  
  /// A `403 Forbidden` response.
  public static func forbidden(headers: [String : String] = [:],
                               _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 403, headers: headers, body: body)
  }
  
  /// A `404 Not Found` response.
  public static func notFound(headers: [String : String] = [:],
                              _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 404, headers: headers, body: body)
  }
  
  /// A `405 Method Not Allowed` response. Add an `Allow` header with the methods that are
  /// allowed.
  public static func methodNotAllowed(headers: [String : String] = [:],
                                      _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 405, headers: headers, body: body)
  }
  /// A `406 Not Acceptable` response.
  public static func notAcceptable(headers: [String : String] = [:],
                                   _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 406, headers: headers, body: body)
  }
  
  /// A `409 Conflict` response.
  public static func conflict(headers: [String : String] = [:],
                              _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 409, headers: headers, body: body)
  }
  
  /// A `413 Content Too Large` response.
  public static func payloadTooLarge(headers: [String : String] = [:],
                                     _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 413, headers: headers, body: body)
  }
  
  /// A `415 Unsupported Media Type` response.
  public static func unsupportedMediaType(headers: [String : String] = [:],
                                          _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 415, headers: headers, body: body)
  }
  
  /// A `422 Unprocessable Content` response: the request is well-formed, but its content
  /// is not acceptable (a field that is missing, a value that is out of range).
  public static func unprocessableContent(headers: [String : String] = [:],
                                          _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 422, headers: headers, body: body)
  }
  
  /// A `429 Too Many Requests` response.
  public static func tooManyRequests(headers: [String : String] = [:],
                                     _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 429, headers: headers, body: body)
  }
  
  /// A `500 Internal Server Error` response.
  public static func internalServerError(headers: [String : String] = [:],
                                         _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 500, headers: headers, body: body)
  }
  
  /// A `501 Not Implemented` response.
  public static func notImplemented(headers: [String : String] = [:],
                                    _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 501, headers: headers, body: body)
  }
  
  /// A `503 Service Unavailable` response. Add a `Retry-After` header (seconds) if the
  /// client can try again later.
  public static func serviceUnavailable(headers: [String : String] = [:],
                                        _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 503, headers: headers, body: body)
  }
  
  /// A response whose body is written by `writer`, see ``Body/custom(_:contentType:)``.
  /// The writer receives an object it writes bytes, data or files to:
  ///
  /// ```swift
  /// let response: NanoHTTPResponse = .custom(200, contentType: "text/plain") { writer in
  ///   for line in 1...3 { try writer.write(Array("line \(line)\n".utf8)) }
  /// }
  /// ```
  public static func custom(_ statusCode: Int,
                            headers: [String : String] = [:],
                            contentType: String? = nil,
                            writer: @escaping (NanoHTTPResponseBodyWriter) throws -> Void) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: statusCode,
                            headers: headers,
                            body: .custom(writer, contentType: contentType))
  }
  
  /// The standard reason phrase of the status code (RFC 9110), or an empty string for a
  /// code that has none. (`HTTPURLResponse.localizedString` is not suitable: it is
  /// localized and lower case, and calls 200 "no error".)
  public var reasonPhrase: String {
    return NanoHTTPResponse.reasonPhrases[self.statusCode] ?? ""
  }
  
  private static let reasonPhrases: [Int: String] = [
    100: "Continue", 101: "Switching Protocols", 102: "Processing", 103: "Early Hints",
    200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
    204: "No Content", 205: "Reset Content", 206: "Partial Content", 207: "Multi-Status",
    208: "Already Reported", 226: "IM Used",
    300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other",
    304: "Not Modified", 305: "Use Proxy", 307: "Temporary Redirect", 308: "Permanent Redirect",
    400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden",
    404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
    407: "Proxy Authentication Required", 408: "Request Timeout", 409: "Conflict", 410: "Gone",
    411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large",
    414: "URI Too Long", 415: "Unsupported Media Type", 416: "Range Not Satisfiable",
    417: "Expectation Failed", 418: "I'm a Teapot", 421: "Misdirected Request",
    422: "Unprocessable Content", 423: "Locked", 424: "Failed Dependency", 425: "Too Early",
    426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests",
    431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
    500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
    503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
    506: "Variant Also Negotiates", 507: "Insufficient Storage", 508: "Loop Detected",
    510: "Not Extended", 511: "Network Authentication Required"
  ]
  
  /// The headers that are sent: ``headers`` plus the `Content-Type` of the body, which
  /// replaces a header of that exact name.
  public func allHeaders() -> [String : String] {
    var headers = self.headers
    if let contentType = self.body.contentType() {
      headers["Content-Type"] = contentType
    }
    return headers
  }
  
  func eventSession() -> NanoSocketSession? {
    switch self.body {
      case .session(let session):
        return session
      default:
        return nil
    }
  }
  
  func socketSession() -> ((NanoSocket) -> Void)? {
    switch self.body {
      case .socket(let handler):
        return handler
      default:
        return nil
    }
  }
}
