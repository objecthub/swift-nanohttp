//
//  NanoMiddleware.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 14/10/2026.
//  Copyright © 2026 Matthias Zenger. All rights reserved.
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

/// The rules of *cross-origin resource sharing* (CORS), which decide what the pages of
/// other sites may do with a server: a browser lets a page read the answer of another
/// site's server only if the answer says that the page's origin is allowed. Use it with
/// ``NanoMiddleware/cors(_:)``.
public struct NanoCORSPolicy {
  
  /// The origins whose pages may use the server:
  /// `["https://app.example", "http://localhost:3000"]`. `nil` allows every origin.
  public var allowedOrigins: [String]?
  
  /// The methods that pages may use. The default is the usual ones, without `OPTIONS`.
  public var allowedMethods: [String]
  
  /// The request headers that pages may send, besides the ones that every request may
  /// have. `nil` allows every header that the page asks about.
  public var allowedHeaders: [String]?
  
  /// The response headers that pages may read, besides the ones that every response has.
  public var exposedHeaders: [String]
  
  /// Whether pages may send cookies and other credentials with their requests, and read
  /// the answers. With credentials the answer names the origin of the page; it never says
  /// `*`.
  public var allowsCredentials: Bool
  
  /// How long a browser may remember the answer to a preflight request, in seconds. `nil`
  /// leaves it out.
  public var maxAge: TimeInterval?
  
  public init(allowedOrigins: [String]? = nil,
              allowedMethods: [String] = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"],
              allowedHeaders: [String]? = nil,
              exposedHeaders: [String] = [],
              allowsCredentials: Bool = false,
              maxAge: TimeInterval? = 600) {
    self.allowedOrigins = allowedOrigins
    self.allowedMethods = allowedMethods
    self.allowedHeaders = allowedHeaders
    self.exposedHeaders = exposedHeaders
    self.allowsCredentials = allowsCredentials
    self.maxAge = maxAge
  }
  
  /// Whether pages of the origin may use the server.
  func allows(origin: String) -> Bool {
    guard let allowed = self.allowedOrigins else {
      return true
    }
    guard let wanted = NanoRequestPolicy.origin(origin) else {
      return false // `null`
    }
    return allowed.contains { entry in
      guard let other = NanoRequestPolicy.origin(entry) else {
        return false
      }
      return other.scheme == wanted.scheme && other.authority.host == wanted.authority.host
               && other.effectivePort == wanted.effectivePort
    }
  }
}

/// Middleware for the usual jobs of a server that web pages talk to. They are values of
/// the type ``NanoHTTPMiddleware``: add them to ``NanoHTTPServer/middleware``.
///
/// ```swift
/// let server = NanoHTTPServer()
/// server.middleware.append(
///   NanoMiddleware.cors(NanoCORSPolicy(allowedOrigins: ["https://app.example"])))
/// ```
public enum NanoMiddleware {
  
  /// Refuses (`403 Forbidden`) requests whose `Host` is not one of `hosts`: `"example.com"`
  /// (at any port), `"example.com:8080"` (at that port only), `"[::1]"`. Requests without
  /// a `Host` are served. The same check as
  /// ``NanoHTTPServerIO/Configuration/HostPolicy/hosts(_:)`` does for a whole server, for
  /// the cases where the server's configuration does not fit.
  public static func hostAllowlist(_ hosts: [String]) -> NanoHTTPMiddleware {
    return { request, next in
      if let refusal = NanoRequestPolicy.hostRefusal(request,
                                                     policy: .hosts(hosts),
                                                     listenAddress: .allInterfaces) {
        throw NanoHTTPError.forbidden(refusal.message)
      }
      return try next(request)
    }
  }
  
  /// Refuses (`403 Forbidden`) requests that change something, and WebSocket handshakes,
  /// that come from a page of another site: its `Origin` has to be the address that the
  /// request was sent to, or one of `origins` (`"https://app.example"`). Requests without
  /// an `Origin` are served. The same check as
  /// ``NanoHTTPServerIO/Configuration/OriginPolicy/origins(_:)`` does for a whole server.
  public static func originAllowlist(_ origins: [String] = []) -> NanoHTTPMiddleware {
    return { request, next in
      if let refusal = NanoRequestPolicy.originRefusal(request, listed: origins) {
        throw NanoHTTPError.forbidden(refusal.message)
      }
      return try next(request)
    }
  }
  
  /// Lets the pages of other sites use the server, as the policy says. A request that has
  /// an `Origin` header is a request of a page; the middleware
  ///
  /// - answers a *preflight* request (`OPTIONS` with `Access-Control-Request-Method`,
  ///   which a browser sends before a request that is not simple) itself, with `204` and
  ///   the headers that tell the browser what is allowed, without asking the router;
  /// - adds `Access-Control-Allow-Origin` (and, if the policy has them, the headers for
  ///   credentials and exposed headers) to the response of every other request from an
  ///   allowed origin, and `Vary: Origin`;
  /// - does nothing for requests without an `Origin`, and adds no permission for origins
  ///   that are not allowed: the browser then keeps the page from reading the answer.
  ///
  /// The response of a ``NanoHTTPError`` that the handler throws gets the headers too, so
  /// that the page sees its status. Other errors become the `500` of the server, which
  /// has no CORS headers.
  ///
  /// CORS is only about what the browser lets a page *read*. The request of a page of
  /// another site reaches the server in any case: protect requests that change something
  /// with ``NanoHTTPServerIO/Configuration/originPolicy``, and list the origins that you
  /// allow here in ``NanoHTTPServerIO/Configuration/OriginPolicy/origins(_:)`` as well.
  public static func cors(_ policy: NanoCORSPolicy) -> NanoHTTPMiddleware {
    return { request, next in
      guard let origin = request.header("origin") else {
        return try next(request)
      }
      let allowed = policy.allows(origin: origin)
      // `*` is not allowed with credentials, and without it the answer depends on the origin.
      let allowOrigin = policy.allowedOrigins == nil &&
                        !policy.allowsCredentials ? "*" : origin
      if request.method == "OPTIONS", let method = request.header("access-control-request-method") {
        var headers = ["Vary": "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"]
        if allowed && policy.allowedMethods.contains(method) {
          headers["Access-Control-Allow-Origin"] = allowOrigin
          headers["Access-Control-Allow-Methods"] = policy.allowedMethods.joined(separator: ", ")
          if let wanted = policy.allowedHeaders?.joined(separator: ", ") ??
                          request.header("access-control-request-headers") {
            headers["Access-Control-Allow-Headers"] = wanted
          }
          if policy.allowsCredentials {
            headers["Access-Control-Allow-Credentials"] = "true"
          }
          if let maxAge = policy.maxAge {
            headers["Access-Control-Max-Age"] = String(Int(maxAge))
          }
        }
        return NanoHTTPResponse(statusCode: 204, headers: headers)
      }
      var response: NanoHTTPResponse
      do {
        response = try next(request)
      } catch let error as NanoHTTPError {
        response = error.response
      }
      if allowOrigin != "*" {
        response.headers["Vary"] = response.headers["Vary"].map { $0 + ", Origin" } ?? "Origin"
      }
      if allowed {
        response.headers["Access-Control-Allow-Origin"] = allowOrigin
        if policy.allowsCredentials {
          response.headers["Access-Control-Allow-Credentials"] = "true"
        }
        if !policy.exposedHeaders.isEmpty {
          response.headers["Access-Control-Expose-Headers"] =
            policy.exposedHeaders.joined(separator: ", ")
        }
      }
      return response
    }
  }
}
