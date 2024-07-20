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

open class HttpServer: HttpServerIO {
  
  public struct MethodRoute {
    public let method: String
    public let router: HttpRouter
    
    public subscript(path: String...) -> HttpRequestHandler? {
      get {
        return nil
      }
      set {
        for p in path {
          router.register(method, path: p, handler: newValue)
        }
      }
    }
  }
  
  public static let VERSION: String = {
    #if os(Linux)
    return "1.5.0"
    #else
    let bundle = Bundle(for: HttpServer.self)
    guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
      return "Unspecified"
    }
    return version
    #endif
  }()
  
  private let router = HttpRouter()
  public var delete: MethodRoute
  public var patch: MethodRoute
  public var head: MethodRoute
  public var post: MethodRoute
  public var get: MethodRoute
  public var put: MethodRoute
  public var notFoundHandler: HttpRequestHandler? = nil
  public var middleware: [(HttpRequest) -> HttpResponse?] = []
  
  public override init() {
    self.delete = MethodRoute(method: "DELETE", router: self.router)
    self.patch = MethodRoute(method: "PATCH", router: self.router)
    self.head = MethodRoute(method: "HEAD", router: self.router)
    self.post = MethodRoute(method: "POST", router: self.router)
    self.get = MethodRoute(method: "GET", router: self.router)
    self.put = MethodRoute(method: "PUT", router: self.router)
  }
  
  public var routes: [String] {
    return self.router.routes()
  }
  
  public subscript(path: String) -> HttpRequestHandler? {
    get {
      return nil
    }
    set {
      self.router.register(nil, path: path, handler: newValue)
    }
  }
  
  public func use(_ prefix: String, router: HttpRouter) throws {
    try self.router.merge(router, withPrefix: prefix)
  }
  
  override open func dispatch(request: HttpRequest) -> ([String: String], HttpRequestHandler) {
    for layer in middleware {
      if let response = layer(request) {
        return ([:], { _ in response })
      }
    }
    if let result = router.route(request.method, path: request.path) {
      return result
    }
    if let notFoundHandler = self.notFoundHandler {
      return ([:], notFoundHandler)
    }
    return super.dispatch(request: request)
  }
}
