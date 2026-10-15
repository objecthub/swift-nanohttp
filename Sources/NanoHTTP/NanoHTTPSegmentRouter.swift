//
//  NanoHTTPSegmentRouter.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
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

/// Class `NanoHTTPSegmentRouter` implements the `NanoHTTPRouter` protocol. Routing is
/// based on path segments that are matched in sequence. There are two differnt types of
/// placeholders that can be used: _variables_ (with `*` being an anonymous variable) and
/// _path variables_ (with `**` being an anonymous path variable). A variable matches one
/// full path segment and its value is being url-decoded: `/users/:id` answers `/users/7`,
/// but not `/users`. A path variable matches a (potentially empty) sequence of path
/// segments and its value is the url-decoded segments joined with `/`: `/files/::path`
/// answers `/files/a/b` and `/files`. The values are also available as the client sent
/// them, still percent-encoded (``routeWithRawParams(_:path:)``).
open class NanoHTTPSegmentRouter: NanoHTTPRouter {
  
  /// What a lookup finds: the variables of the route, decoded and as sent by the client
  /// (the same names), and the handler.
  fileprivate typealias Match = (params: [String : String],
                                 rawParams: [String : String],
                                 handler: NanoHTTPRequestHandler)
  
  /// The segments of the path of a request, decoded and as the client sent them.
  fileprivate struct PathSegments {
    
    /// The segments as the client sent them, still percent-encoded.
    let raw: [String]
    
    /// The same segments, percent-decoded.
    let decoded: [String]
    
    /// Has a segment a percent-escape? If not, `decoded` and `raw` are the same, and so are
    /// the values of the variables: the search then does not build the raw ones.
    let isEncoded: Bool
    
    var count: Int {
      return self.decoded.count
    }
  }
  
  /// The children of a segment that are variables, in the order in which they were
  /// registered: when several of them match, the first one wins, so that routing does
  /// not depend on the order of a dictionary.
  fileprivate struct Children {
    var items: [(key: String?, segment: Segment)] = []
    
    mutating func next(for key: String?) -> Segment {
      if let found = self.items.first(where: { $0.key == key }) {
        return found.segment
      }
      let result = Segment()
      self.items.append((key, result))
      return result
    }
    
    mutating func merge(with other: Children) {
      for (key, otherNext) in other.items {
        if let found = self.items.first(where: { $0.key == key }) {
          found.segment.merge(with: otherNext)
        } else {
          self.items.append((key, otherNext.copy()))
        }
      }
    }
    
    func copy() -> Children {
      return Children(items: self.items.map { ($0.key, $0.segment.copy()) })
    }
  }
  
  /// The routes below a segment as they were when a snapshot of the router was made.
  /// Nothing in it ever changes, so any number of threads can match against it at the
  /// same time without waiting for each other.
  fileprivate final class FrozenSegment {
    let pathChildren: [String : FrozenSegment]
    let variableChildren: [(key: String?, segment: FrozenSegment)]
    let pathVariableChildren: [(key: String?, segment: FrozenSegment)]
    let handler: NanoHTTPRequestHandler?
    
    init(pathChildren: [String : FrozenSegment],
         variableChildren: [(key: String?, segment: FrozenSegment)],
         pathVariableChildren: [(key: String?, segment: FrozenSegment)],
         handler: NanoHTTPRequestHandler?) {
      self.pathChildren = pathChildren
      self.variableChildren = variableChildren
      self.pathVariableChildren = pathVariableChildren
      self.handler = handler
    }
    
    /// Finds the handler for the segments of a path from `index` on, with the variables
    /// of the route as they are in the decoded segments and as the client sent them. Fixed
    /// segments are tried first, then variables and then path variables, each in the order
    /// of their registration; the search backtracks. Both values of a variable are taken
    /// from the segments at the same indices, here, where the search has settled on them.
    /// The raw values are left out if `path` has no escapes (`isEncoded`): they are the
    /// decoded ones then.
    ///
    /// A variable (`:name`, `*`) matches exactly one segment, and a path with no segment
    /// left does not match it: `/users/:id` does not answer `/users`. A path variable
    /// (`::name`, `**`) matches any number of segments, none included: `/files/::path`
    /// answers `/files`, with an empty value.
    func match(path: PathSegments, index: Int) -> Match? {
      guard index < path.count else {
        // All the path has been matched already: if there is a handler, return it
        if let handler = self.handler {
          return ([:], [:], handler)
        }
        // Otherwise a path variable may stand for the empty rest of the path
        for (variable, next) in self.pathVariableChildren {
          if var result = next.match(path: path, index: index) {
            if let variable {
              result.params[variable] = ""
              if path.isEncoded {
                result.rawParams[variable] = ""
              }
            }
            return result
          }
        }
        return nil
      }
      // There is at least one more component from the current path (the segments are
      // decoded already)...
      let component = path.decoded[index]
      if let next = self.pathChildren[component],
         let result = next.match(path: path, index: index + 1) {
        return result
      }
      for (variable, next) in self.variableChildren {
        if var result = next.match(path: path, index: index + 1) {
          if let variable {
            result.params[variable] = component
            if path.isEncoded {
              result.rawParams[variable] = path.raw[index]
            }
          }
          return result
        }
      }
      for (variable, next) in self.pathVariableChildren {
        for i in index...path.count {
          if var result = next.match(path: path, index: i) {
            if let variable {
              result.params[variable] = path.decoded[index..<i].joined(separator: "/")
              if path.isEncoded {
                result.rawParams[variable] = path.raw[index..<i].joined(separator: "/")
              }
            }
            return result
          }
        }
      }
      return nil
    }
  }
  
  /// Represents a single segment of a path
  fileprivate class Segment: CustomDebugStringConvertible {
    
    /// The fixed child segments that form the route
    var pathChildren: [String : Segment] = [:]
    
    /// The variable child segments that form the route
    var variableChildren = Children()
    
    /// Path variables potentially replacing sequences of segments
    var pathVariableChildren = Children()
    
    /// The closure to handle the route
    var handler: NanoHTTPRequestHandler?
    
    func copy() -> Segment {
      let result = Segment()
      for (selector, next) in self.pathChildren {
        result.pathChildren[selector] = next.copy()
      }
      result.variableChildren = self.variableChildren.copy()
      result.pathVariableChildren = self.pathVariableChildren.copy()
      result.handler = self.handler
      return result
    }
    
    func routes(prefix: String = "") -> [String] {
      var result = [String]()
      if self.handler != nil {
        result.append(prefix)
      }
      for (key, child) in self.pathChildren {
        result.append(contentsOf: child.routes(prefix: prefix + "/" + key))
      }
      for (key, child) in self.variableChildren.items {
        if let key {
          result.append(contentsOf: child.routes(prefix: prefix + "/:" + key))
        } else {
          result.append(contentsOf: child.routes(prefix: prefix + "/*"))
        }
      }
      for (key, child) in self.pathVariableChildren.items {
        if let key {
          result.append(contentsOf: child.routes(prefix: prefix + "/::" + key))
        } else {
          result.append(contentsOf: child.routes(prefix: prefix + "/**"))
        }
      }
      return result
    }
    
    func insert(selectors: [String]) -> Segment {
      var iterator = selectors.makeIterator()
      return self.insert(generator: &iterator)
    }
    
    private func insert(generator: inout IndexingIterator<[String]>) -> Segment {
      guard let s = generator.next() else {
        return self
      }
      if s == "*" {
        return self.variableChildren.next(for: nil).insert(generator: &generator)
      } else if s == "**" {
        return self.pathVariableChildren.next(for: nil).insert(generator: &generator)
      } else if s.hasPrefix("::") && s.count > 2 {
        let variable = String(s.suffix(from: s.index(s.startIndex, offsetBy: 2)))
        return self.pathVariableChildren.next(for: variable).insert(generator: &generator)
      } else if s.first == ":" && s.count > 1 {
        let variable = String(s.suffix(from: s.index(s.startIndex, offsetBy: 1)))
        return self.variableChildren.next(for: variable).insert(generator: &generator)
      }
      return self.pathChildren.next(for: s).insert(generator: &generator)
    }
    
    func merge(with other: Segment) {
      self.pathChildren.merge(with: other.pathChildren)
      self.variableChildren.merge(with: other.variableChildren)
      self.pathVariableChildren.merge(with: other.pathVariableChildren)
      self.handler = other.handler ?? self.handler
    }
    
    /// An immutable copy of this segment and everything below it, for matching.
    func frozen() -> FrozenSegment {
      return FrozenSegment(
        pathChildren: self.pathChildren.mapValues { $0.frozen() },
        variableChildren: self.variableChildren.items.map { ($0.key, $0.segment.frozen()) },
        pathVariableChildren: self.pathVariableChildren.items.map { ($0.key, $0.segment.frozen()) },
        handler: self.handler)
    }
    
    var debugDescription: String {
      var res = "Segment(path = \(self.pathChildren.keys), " +
                "var = \(self.variableChildren.items.map { $0.key }), " +
                "pathvar = \(self.pathVariableChildren.items.map { $0.key })"
      if self.handler != nil {
        res += ", handler"
      }
      return res + ")"
    }
  }
  
  /// The routes, by method (`nil`: all methods). Changed by `register` and `merge`, under
  /// `lock`.
  private var root: [String? : Segment] = [:]
  
  /// A copy of `root` that is never changed, which requests are matched against, so that the
  /// threads that serve them do not wait for each other (matching takes about as long as
  /// waiting for a lock does). Made when it is needed after the routes have changed (guarded
  /// by `lock`).
  private var snapshotValue: [String? : FrozenSegment]?
  
  private let lock = UnfairLock()
  
  /// The routes as they are now, in a form that threads can read at the same time.
  private func snapshot() -> [String? : FrozenSegment] {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    if let snapshot = self.snapshotValue {
      return snapshot
    }
    let snapshot = self.root.mapValues { $0.frozen() }
    self.snapshotValue = snapshot
    return snapshot
  }
  
  /// Creates a router without routes.
  public init() {
  }
  
  /// The registered route patterns, written like the paths they were registered with
  /// (`/users/:id`, `/files/::path`, `/a/*/b/**`). The order is not defined.
  open func routes() -> [String] {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    var routes = [String]()
    for (_, child) in self.root {
      routes.append(contentsOf: child.routes())
    }
    return routes
  }
  
  /// Registers a handler for `path`. `method` is the HTTP method in upper case, or
  /// `nil` for all methods. `path` is a sequence of segments separated by `/`; empty
  /// segments are ignored, and everything after a `?` is ignored. A `nil` handler
  /// removes the registration.
  open func register(_ method: String?, path: String, handler: NanoHTTPRequestHandler?) {
    let selectors = self.selectors(from: path)
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    self.root.next(for: method).insert(selectors: selectors).handler = handler
    self.snapshotValue = nil
  }
  
  /// Copies the routes of another segment router below `prefix` (`/api/v1`). The
  /// routes of `router` that already exist at the same path are replaced.
  ///
  /// - Throws: `NanoHTTPRouterError.incompatibleRouterForMerge` if `router` is not a
  ///           ``NanoHTTPSegmentRouter``.
  open func merge(_ router: NanoHTTPRouter, withPrefix prefix: String) throws {
    guard let router = router as? NanoHTTPSegmentRouter else {
      throw NanoHTTPRouterError.incompatibleRouterForMerge
    }
    let selectors = self.selectors(from: prefix)
    // not `router.root`: another thread may change it meanwhile
    let routes = router.copiedRoutes()
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    for (method, initial) in routes {
      self.root.next(for: method).insert(selectors: selectors).merge(with: initial)
    }
    self.snapshotValue = nil
  }
  
  /// A copy of the routes that can be changed.
  private func copiedRoutes() -> [String? : Segment] {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    return self.root.mapValues { $0.copy() }
  }
  
  /// Finds the handler for a request. Fixed segments win over variables, and the search
  /// backtracks: `/a/b/c` and `/a/:x/d` both match `/a/b/d`. A route for `method` is tried
  /// before a route for all methods. A `HEAD` request that has no route of its own is
  /// answered by the route for `GET`, before the route for all methods is tried.
  ///
  /// `path` is the path as the client sent it, percent-encoded: it is split into segments
  /// first, and every segment is decoded then (an encoded slash stays inside its segment).
  /// The decoded segments are compared with the fixed segments of the routes and are the
  /// values of the variables; a path variable (`::name`, `**`) gets its decoded segments
  /// joined with `/`. A path with a segment that is not valid percent-encoded UTF-8
  /// matches no route.
  ///
  /// The server asks ``routeWithRawParams(_:path:)``, which this calls: a subclass that
  /// changes how requests are routed overrides that one, and `route` follows.
  open func route(_ method: String, path: String) -> ([String: String], NanoHTTPRequestHandler)? {
    guard let match = self.routeWithRawParams(method, path: path) else {
      return nil
    }
    return (match.params, match.handler)
  }
  
  /// Finds the handler for a request like ``route(_:path:)`` does, and returns the variables
  /// of the route twice: as `params` (decoded) and as `rawParams`, the values as the client
  /// sent them, still percent-encoded (`a%2Fb`, not `a/b`; a `+` stays a `+`). A variable
  /// (`:name`) has its raw segment as its raw value, and a path variable (`::name`) its raw
  /// segments joined with `/`; empty segments are left out, a path variable that matches no
  /// segment has `""`, and the query is not part of a value. Both have the same names: the
  /// anonymous `*` and `**` have no entry in either. They are taken from the same segments,
  /// also where the search backtracks (`/files/::path/edit`).
  ///
  /// ``NanoHTTPServer`` calls this to set `request.params` and `request.rawParams`. A
  /// subclass that overrides ``route(_:path:)`` has to override this function too, or the
  /// server does not see the change.
  open func routeWithRawParams(_ method: String, path: String)
    -> (params: [String: String],
        rawParams: [String: String],
        handler: NanoHTTPRequestHandler)? {
    guard let segments = self.pathSegments(of: path) else {
      return nil
    }
    let routes = self.snapshot()
    let found: Match?
    if method == "HEAD" {
      found = routes["HEAD"]?.match(path: segments, index: 0) ??
              routes["GET"]?.match(path: segments, index: 0) ??
              routes[nil]?.match(path: segments, index: 0)
    } else {
      found = routes[method]?.match(path: segments, index: 0) ??
              routes[nil]?.match(path: segments, index: 0)
    }
    guard var match = found, !segments.isEncoded else {
      return found
    }
    // Without escapes the values as sent are the decoded ones, and share their storage
    match.rawParams = match.params
    return match
  }
  
  /// The methods of the routes that match `path`, in the usual order (`GET`, `HEAD`,
  /// `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`) followed by the others in alphabetical
  /// order. `HEAD` is included where there is a route for `GET` (it answers `HEAD`
  /// requests), and `OPTIONS` always (the server answers it itself). The path
  /// `*` has the methods of all routes.
  open func allowedMethods(path: String) -> [String] {
    var methods = Set<String>()
    let routes = self.snapshot()
    if path == "*" {
      for method in routes.keys {
        if let method {
          methods.insert(method)
        }
      }
    } else if let segments = self.pathSegments(of: path) {
      for (method, segment) in routes {
        if let method, segment.match(path: segments, index: 0) != nil {
          methods.insert(method)
        }
      }
    }
    guard !methods.isEmpty else {
      return []
    }
    if methods.contains("GET") {
      methods.insert("HEAD")
    }
    methods.insert("OPTIONS")
    let usual = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    return usual.filter { methods.contains($0) } + methods.subtracting(usual).sorted()
  }
  
  /// The segments of a path as the client sent it, and each decoded; `nil` if one of them
  /// is not valid percent-encoding. Empty segments are left out, and so is everything
  /// from a `?` on. Only a segment that has a `%` is decoded.
  private func pathSegments(of path: String) -> PathSegments? {
    var isEncoded = false
    let utf8 = path.utf8
    let end = utf8.firstIndex(of: 63) ?? utf8.endIndex // `?`
    let parts = utf8[..<end].split(separator: 47) // `/`
    var raw = [String]()
    raw.reserveCapacity(parts.count)
    for part in parts {
      raw.append(String(decoding: part, as: UTF8.self))
      isEncoded = isEncoded || part.contains(37) // `%`
    }
    guard isEncoded else {
      return PathSegments(raw: raw, decoded: raw, isEncoded: false)
    }
    var decoded = [String]()
    decoded.reserveCapacity(raw.count)
    for segment in raw {
      if segment.utf8.contains(37) {
        guard let value = segment.removingPercentEncoding else {
          return nil
        }
        decoded.append(value)
      } else {
        decoded.append(segment)
      }
    }
    return PathSegments(raw: raw, decoded: decoded, isEncoded: true)
  }
  
  private func selectors(from path: String) -> [String] {
    return (path.components(separatedBy: "?").first ?? path).split("/")
  }
}

extension Dictionary where Value == NanoHTTPSegmentRouter.Segment {
  mutating func next(for key: Key) -> Value {
    if let result = self[key] {
      return result
    } else {
      let result = NanoHTTPSegmentRouter.Segment()
      self[key] = result
      return result
    }
  }
  
  mutating func merge(with other: Self) {
    for (selector, otherNext) in other {
      if let next = self[selector] {
        next.merge(with: otherNext)
      } else {
        self[selector] = otherNext.copy()
      }
    }
  }
}
