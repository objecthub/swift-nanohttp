//
//  NanoHTTPError.swift
//  NanoHTTP
//
//  Copyright © 2026 Matthias Zenger. All rights reserved.
//  
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
//

import Foundation

/// An error that a handler throws to answer a request with an error status code.
///
/// ```swift
/// let items = ["1": "pen", "2": "paper"]
/// let server = NanoHTTPServer()
/// server.get["/items/:id"] = { request in
///   guard let id = request.params["id"], let item = items[id] else {
///     throw NanoHTTPError.notFound("There is no item \(request.params["id"] ?? "")")
///   }
///   return .ok(.text(item))
/// }
/// ```
///
/// The server turns the error into the response of ``response``: the status code, the headers, and the
/// message as a plain text body. Every other error that a handler throws is answered with
/// `500 Internal Server Error`, without any details (they are logged), because the description of an
/// error can tell an attacker more than it should. ``NanoHTTPServer/errorHandler`` changes how errors
/// are answered, for example to send them as JSON, and middleware can catch them.
public struct NanoHTTPError: Error, Equatable, CustomStringConvertible {
  /// The status code of the response.
  public var status: Int
  
  /// The body of the response, as plain text. `nil` for an empty body.
  public var message: String?
  
  /// The headers of the response.
  public var headers: [String: String]
  
  /// Creates an error that is answered with the status code `status`.
  public init(status: Int, message: String? = nil, headers: [String: String] = [:]) {
    self.status = status
    self.message = message
    self.headers = headers
  }
  
  /// The response that the server sends for this error.
  public var response: NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: self.status,
                            headers: self.headers,
                            body: self.message.map { .text($0) } ?? .empty)
  }
  
  public var description: String {
    let reason = self.response.reasonPhrase
    return "NanoHTTPError(\(self.status)\(reason.isEmpty ? "" : " " + reason)" +
           "\(self.message.map { ": " + $0 } ?? ""))"
  }
  
  /// `400 Bad Request`: the request is not valid.
  public static func badRequest(_ message: String? = nil,
                                headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 400, message: message, headers: headers)
  }
  
  /// `401 Unauthorized`: the client has to authenticate; `wwwAuthenticate` is the challenge (for example
  /// `Bearer` or `Basic realm="admin"`).
  public static func unauthorized(_ message: String? = nil,
                                  wwwAuthenticate: String? = nil,
                                  headers: [String: String] = [:]) -> NanoHTTPError {
    var headers = headers
    if let wwwAuthenticate {
      headers["WWW-Authenticate"] = wwwAuthenticate
    }
    return NanoHTTPError(status: 401, message: message, headers: headers)
  }
  
  /// `403 Forbidden`: the client is known, and not allowed to do this.
  public static func forbidden(_ message: String? = nil,
                               headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 403, message: message, headers: headers)
  }
  
  /// `404 Not Found`: there is no such resource.
  public static func notFound(_ message: String? = nil,
                              headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 404, message: message, headers: headers)
  }
  
  /// `405 Method Not Allowed`; `allow` lists the methods that are allowed (the `Allow` header).
  public static func methodNotAllowed(_ message: String? = nil,
                                      allow: [String] = [],
                                      headers: [String: String] = [:]) -> NanoHTTPError {
    var headers = headers
    if !allow.isEmpty {
      headers["Allow"] = allow.joined(separator: ", ")
    }
    return NanoHTTPError(status: 405, message: message, headers: headers)
  }
  
  /// `406 Not Acceptable`: the server cannot produce what the `Accept` headers ask for.
  public static func notAcceptable(_ message: String? = nil,
                                   headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 406, message: message, headers: headers)
  }
  
  /// `409 Conflict`: the request conflicts with the state of the resource.
  public static func conflict(_ message: String? = nil,
                              headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 409, message: message, headers: headers)
  }
  
  /// `413 Content Too Large`.
  public static func payloadTooLarge(_ message: String? = nil,
                                     headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 413, message: message, headers: headers)
  }
  
  /// `415 Unsupported Media Type`: the server does not accept the content type of the body.
  public static func unsupportedMediaType(_ message: String? = nil,
                                          headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 415, message: message, headers: headers)
  }
  
  /// `422 Unprocessable Content`: the request is well-formed, but its content cannot be processed.
  public static func unprocessableContent(_ message: String? = nil,
                                          headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 422, message: message, headers: headers)
  }
  
  /// `429 Too Many Requests`; `retryAfter` is the number of seconds after which the client may try again.
  public static func tooManyRequests(_ message: String? = nil,
                                     retryAfter: Int? = nil,
                                     headers: [String: String] = [:]) -> NanoHTTPError {
    var headers = headers
    if let retryAfter {
      headers["Retry-After"] = String(retryAfter)
    }
    return NanoHTTPError(status: 429, message: message, headers: headers)
  }
  
  /// `500 Internal Server Error`.
  public static func internalServerError(_ message: String? = nil,
                                         headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 500, message: message, headers: headers)
  }
  
  /// `501 Not Implemented`.
  public static func notImplemented(_ message: String? = nil,
                                    headers: [String: String] = [:]) -> NanoHTTPError {
    return NanoHTTPError(status: 501, message: message, headers: headers)
  }
  
  /// `503 Service Unavailable`; `retryAfter` is the number of seconds after which the client may try again.
  public static func serviceUnavailable(_ message: String? = nil,
                                        retryAfter: Int? = nil,
                                        headers: [String: String] = [:]) -> NanoHTTPError {
    var headers = headers
    if let retryAfter {
      headers["Retry-After"] = String(retryAfter)
    }
    return NanoHTTPError(status: 503, message: message, headers: headers)
  }
}
