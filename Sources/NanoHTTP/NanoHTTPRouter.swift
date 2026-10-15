//
//  NanoHTTPRouter.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 23/07/2024.
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

/// Maps methods and paths to handlers. ``NanoHTTPServer`` uses a ``NanoHTTPSegmentRouter``
/// unless `initialRouter()` is overridden. A router has to be safe to use from several
/// threads: routes are looked up on the threads of the connections, and may be registered
/// while the server is running.
public protocol NanoHTTPRouter {
  
  /// Registers `handler` for requests with `method` (`nil`: every method) to `path`.
  /// A `nil` handler removes a registration. A registration for a specific method
  /// wins over one for every method.
  func register(_ method: String?, path: String, handler: NanoHTTPRequestHandler?)
  
  /// Adds the routes of `router` below `prefix`. Throws
  /// `NanoHTTPRouterError.incompatibleRouterForMerge` if the router does not know how
  /// to merge routers of the type of `router`.
  func merge(_ router: NanoHTTPRouter, withPrefix prefix: String) throws
  
  /// The handler for a request and the variables its route defined (`request.params`),
  /// or `nil` if no route matches. `path` is the path of the request as the client
  /// sent it (percent-encoded).
  func route(_ method: String, path: String) -> ([String: String], NanoHTTPRequestHandler)?
  
  /// Like ``route(_:path:)``, and the values of the variables also as the client sent them
  /// (`rawParams`, which the server sets as `request.rawParams`): still percent-encoded,
  /// not decoded, so that `a%2Fb` can be told from `a/b`. The names are those of `params`.
  /// The server calls this function, not ``route(_:path:)``.
  ///
  /// The default implementation calls ``route(_:path:)`` and has no raw values (an empty
  /// `rawParams`), so that a router that does not offer them still works. A router that
  /// decodes the values itself should take the raw ones from the same segments, at the
  /// same time: deriving them afterwards goes wrong where the search backtracks (see
  /// ``NanoHTTPSegmentRouter``, where a path variable has the raw segments, joined with
  /// `/`, that its decoded value is made of).
  func routeWithRawParams(_ method: String, path: String)
    -> (params: [String: String],
        rawParams: [String: String],
        handler: NanoHTTPRequestHandler)?
  
  /// The registered route patterns; the methods are not part of them.
  func routes() -> [String]
  
  /// The methods that a request for `path` (percent-encoded, as in ``route(_:path:)``)
  /// can have, because there are routes for them: the server answers a request that no
  /// route matches with `405 Method Not Allowed` and this list as its `Allow` header, and
  /// an `OPTIONS` request with it. Empty if no route matches the path with any method;
  /// for the path `*` the methods of all routes. The default implementation gives no
  /// methods, so that a router that does not offer this has requests without a route
  /// answered with `404`.
  func allowedMethods(path: String) -> [String]
}

extension NanoHTTPRouter {
  public func allowedMethods(path: String) -> [String] {
    return []
  }
  
  public func routeWithRawParams(_ method: String, path: String)
    -> (params: [String: String],
        rawParams: [String: String],
        handler: NanoHTTPRequestHandler)? {
    guard let (params, handler) = self.route(method, path: path) else {
      return nil
    }
    return (params, [:], handler)
  }
}

/// Errors of routers.
public enum NanoHTTPRouterError: Error {
  
  /// Routers could not be merged.
  case unableToMerge
  
  /// The router does not support merging with a router of this type.
  case incompatibleRouterForMerge
}
