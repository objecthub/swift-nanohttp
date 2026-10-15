//
//  NanoHTTPServer.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `HttpServer` of framework `Swifter` by Damian Kołakowski.
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

/// An HTTP/1.1 server with routing.
///
/// Create a server, register handlers for methods and paths, and start it:
///
/// ```swift
/// let server = NanoHTTPServer()
/// server.get["/hello"] = { _ in .ok(.text("Hello, world!")) }
/// server.get["/users/:id"] = { request in .ok(.text("User \(request.params["id"] ?? "?")")) }
/// server.post["/echo"] = { request in
///   .ok(.data(Data(request.body), contentType: "application/octet-stream"))
/// }
/// try server.start(8080)
/// ```
///
/// A handler is a function from ``NanoHTTPRequest`` to ``NanoHTTPResponse``. Every
/// connection is served by its own thread, so handlers of different connections run at
/// the same time; a handler that shares state with others has to protect it.
///
/// The server is a subclass of ``NanoHTTPServerIO``, which provides the listening socket,
/// the connections and the lifecycle (``NanoHTTPServerIO/start(_:)``,
/// ``NanoHTTPServerIO/stop()``); this class adds routing, middleware and a handler for
/// unknown paths.
open class NanoHTTPServer: NanoHTTPServerIO {
  
  /// Registers handlers for one HTTP method: `server.get["/a", "/b"] = handler` registers
  /// `handler` for GET requests to both paths, `server.get["/a"] = nil` removes the
  /// handler of `/a` again. Reading the subscript always gives `nil`.
  ///
  /// Paths may contain variables, see ``NanoHTTPSegmentRouter``.
  public struct MethodRoute {
    /// The HTTP method, in upper case (`"GET"`).
    public let method: String
    /// The router that receives the registrations.
    public let router: NanoHTTPRouter
    
    /// The handler for `path`, assigned with `server.get[path] = ...`. Several paths can
    /// be given to register the same handler for all of them. Reading gives `nil`.
    public subscript(path: String...) -> NanoHTTPRequestHandler? {
      get {
        return nil
      }
      set {
        for p in path {
          self.router.register(self.method, path: p, handler: newValue)
        }
      }
    }
  }
  
  /// The router that maps methods and paths to handlers. It is created by ``initialRouter()``
  /// and can be used directly to register routes.
  public let router: NanoHTTPRouter
  /// Registers handlers for DELETE requests: `server.delete["/items/:id"] = ...`.
  public var delete: MethodRoute
  /// Registers handlers for PATCH requests: `server.patch["/items/:id"] = ...`.
  public var patch: MethodRoute
  /// Registers handlers for HEAD requests: `server.head["/items"] = ...`. A HEAD request
  /// is answered by a handler registered for HEAD, or else by the handler for GET (with
  /// the body of its response left out, as HEAD wants), or else by a handler for all
  /// methods. Registering a handler for HEAD is only needed to answer it differently from
  /// GET.
  public var head: MethodRoute
  /// Registers handlers for OPTIONS requests: `server.options["/items"] = ...`. Without
  /// one, the server answers `OPTIONS` requests itself with the methods that the path has
  /// (`Allow`).
  public var options: MethodRoute
  /// Registers handlers for POST requests: `server.post["/items"] = ...`.
  public var post: MethodRoute
  /// Registers handlers for GET requests: `server.get["/items"] = ...`.
  public var get: MethodRoute
  /// Registers handlers for PUT requests: `server.put["/items/:id"] = ...`.
  public var put: MethodRoute
  /// The handler for requests that no route matches. Without one, such requests are
  /// answered with `404 Not Found` and an empty body.
  public var notFoundHandler: NanoHTTPRequestHandler? = nil
  /// Decides how the errors of handlers and middleware are answered. It receives the
  /// error and the request and returns the response, or `nil` to leave the error to the
  /// default: the response of a ``NanoHTTPError``, or `500 Internal Server Error` for
  /// other errors (see ``NanoHTTPServerIO/response(for:to:)``). Errors that middleware
  /// catches do not get here.
  ///
  /// ```swift
  /// let server = NanoHTTPServer()
  /// server.errorHandler = { error, request in
  ///   guard let error = error as? NanoHTTPError else {
  ///     return nil // everything else: 500, as usual
  ///   }
  ///   return NanoHTTPResponse(statusCode: error.status,
  ///                           body: .json(["error": error.message ?? ""]))
  /// }
  /// ```
  ///
  /// It runs on the threads of the connections. Set it before starting the server.
  public var errorHandler: ((Error, NanoHTTPRequest) -> NanoHTTPResponse?)? = nil
  /// Functions that wrap the handling of every request, in the order of the array: the
  /// first one is the outermost. A middleware receives the request and `next`, the rest
  /// of the chain: the middleware after it, and finally the router and the handler. It
  /// lets the request through by calling `next`, and can
  ///
  /// - answer the request itself and not call `next` (a check that fails),
  /// - change the request before it calls `next` (add `request.custom["user"]`, rewrite
  ///   the path: the request is routed after the middleware has run),
  /// - change the response that `next` returns (add a header, measure how long it took), and
  /// - catch an error that `next` throws, or throw one itself.
  ///
  /// ```swift
  /// let server = NanoHTTPServer()
  /// server.middleware.append { request, next in
  ///   guard request.header("x-api-key") == "secret" else {
  ///     throw NanoHTTPError.unauthorized("API key required")
  ///   }
  ///   var response = try next(request)
  ///   response.headers["X-Served-By"] = "nano"
  ///   return response
  /// }
  /// ```
  ///
  /// Middleware sees every request, including those that no route matches. It runs before
  /// the request is routed, so the variables of the route (`request.params`) are known
  /// only after `next` has returned.
  ///
  /// Middleware runs on the threads of the connections. Configure it before starting the
  /// server.
  public var middleware: [NanoHTTPMiddleware] = []
  
  /// Creates the router of a new server: a ``NanoHTTPSegmentRouter``. Override in a
  /// subclass to use a different ``NanoHTTPRouter``.
  open class func initialRouter() -> NanoHTTPRouter {
    return NanoHTTPSegmentRouter()
  }
  
  /// Creates a server that is not running yet; see ``NanoHTTPServerIO/start(_:)``.
  ///
  /// - Parameter configuration: How the server listens and what it accepts.
  public override init(configuration: Configuration = Configuration()) {
    self.router = Swift.type(of: self).initialRouter()
    self.delete = MethodRoute(method: "DELETE", router: self.router)
    self.patch = MethodRoute(method: "PATCH", router: self.router)
    self.head = MethodRoute(method: "HEAD", router: self.router)
    self.options = MethodRoute(method: "OPTIONS", router: self.router)
    self.post = MethodRoute(method: "POST", router: self.router)
    self.get = MethodRoute(method: "GET", router: self.router)
    self.put = MethodRoute(method: "PUT", router: self.router)
    super.init(configuration: configuration)
  }
  
  /// The registered route patterns (`/users/:id`, `/files/::path`), for diagnostics or an
  /// index page. The methods are not part of the result.
  public var routes: [String] {
    return self.router.routes()
  }
  
  /// Registers a handler for one or more paths and for *all* HTTP methods:
  /// `server["/status"] = ...`. A handler registered for a specific method (`server.get[...]`)
  /// takes precedence over it. Reading gives `nil`.
  public subscript(path: String...) -> NanoHTTPRequestHandler? {
    get {
      return nil
    }
    set {
      for p in path {
        self.router.register(nil, path: p, handler: newValue)
      }
    }
  }
  
  /// Mounts the routes of another router below `prefix`, so that a group of routes can be
  /// developed on its own (`try server.use("/api/v1", router: api)`).
  ///
  /// The routes are copied: changes of `router` after this call are not seen by the server.
  ///
  /// - Throws: ``NanoHTTPRouterError`` if the router of the server cannot merge `router`.
  public func use(_ prefix: String, router: NanoHTTPSegmentRouter) throws {
    try self.router.merge(router, withPrefix: prefix)
  }
  
  /// Finds the handler for a request. Without middleware: the route that matches the
  /// method and path, else ``notFoundHandler``, else a `404`. With middleware, the
  /// handler is the chain of the middleware around that: the router is asked when the
  /// last middleware calls `next`. Returns the variables of the route (`request.params`;
  /// they are set by the chain when there is middleware) and the handler.
  override open func dispatch(request: NanoHTTPRequest) -> ([String: String], NanoHTTPRequestHandler) {
    let layers = self.middleware
    guard !layers.isEmpty else {
      return self.route(request)
    }
    var chain: NanoHTTPRequestHandler = { request in
      let (params, handler) = self.route(request)
      request.params = params
      return try handler(request)
    }
    for layer in layers.reversed() {
      let next = chain
      chain = { request in try layer(request, next) }
    }
    return ([:], chain)
  }
  
  /// The router; else, if the path has routes for other methods, the answer that the
  /// server gives itself (`204` with `Allow` to `OPTIONS`, `405` with `Allow` to the
  /// others); else the not-found handler, and finally the `404` of ``NanoHTTPServerIO``.
  private func route(_ request: NanoHTTPRequest) -> ([String: String], NanoHTTPRequestHandler) {
    if let result = router.route(request.method, path: request.rawPath) {
      return result
    }
    let allowed = router.allowedMethods(path: request.rawPath)
    if !allowed.isEmpty {
      let allow = allowed.joined(separator: ", ")
      if request.method == "OPTIONS" {
        return ([:], { _ in NanoHTTPResponse(statusCode: 204, headers: ["Allow": allow]) })
      }
      return ([:], { _ in .methodNotAllowed(headers: ["Allow": allow]) })
    }
    if let notFoundHandler = self.notFoundHandler {
      return ([:], notFoundHandler)
    }
    return super.dispatch(request: request)
  }
  
  /// The response for an error of a handler or middleware: the ``errorHandler`` decides,
  /// and if there is none or it returns `nil`, the default of
  /// ``NanoHTTPServerIO/response(for:to:)`` applies.
  override open func response(for error: Error, to request: NanoHTTPRequest) -> NanoHTTPResponse {
    if let response = self.errorHandler?(error, request) {
      return response
    }
    return super.response(for: error, to: request)
  }
}
