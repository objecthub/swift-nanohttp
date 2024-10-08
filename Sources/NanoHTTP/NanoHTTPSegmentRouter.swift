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

///
/// Class `NanoHTTPSegmentRouter` implements the `NanoHTTPRouter` protocol. Routing is based
/// on path segments that are matched in sequence. There are two differnt types of placeholders
/// that can be used: _variables_ (with `*` being an anonymous variable) and _path variables_
/// (with `**` being an anonymous path variable). A variable matches one full path segment
/// and its value is being url-decoded. A path variable matches a (potentially empty) sequence
/// of path segments and its value is not being url-decoded.
///
open class NanoHTTPSegmentRouter: NanoHTTPRouter {
  
  /// Represents a single segment of a path
  fileprivate class Segment: CustomDebugStringConvertible {
    /// The fixed child segments that form the route
    var pathChildren: [String : Segment] = [:]
    
    /// The variable child segments that form the route
    var variableChildren: [String? : Segment] = [:]
    
    /// Path variables potentially replacing sequences of segments
    var pathVariableChildren: [String? : Segment] = [:]
    
    /// The closure to handle the route
    var handler: NanoHTTPRequestHandler?
    
    func copy() -> Segment {
      let result = Segment()
      for (selector, next) in self.pathChildren {
        result.pathChildren[selector] = next.copy()
      }
      for (selector, next) in self.variableChildren {
        result.variableChildren[selector] = next.copy()
      }
      for (selector, next) in self.pathVariableChildren {
        result.pathVariableChildren[selector] = next.copy()
      }
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
      for (key, child) in self.variableChildren {
        if let key {
          result.append(contentsOf: child.routes(prefix: prefix + "/:" + key))
        } else {
          result.append(contentsOf: child.routes(prefix: prefix + "/*"))
        }
      }
      for (key, child) in self.pathVariableChildren {
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
    
    func match(path: [String], index: Int) -> ([String : String], NanoHTTPRequestHandler)? {
      // All the path has been matched already: if there is a handler, return it, otherwise fail
      guard index < path.count else {
        // If this segment has a handler, return it
        if let handler = self.handler {
          return ([:], handler)
        }
        // If this segment does not have a handler, check if there is a variable (which will
        // get an empty value) whose next segment has a handler
        for (variable, next) in self.variableChildren {
          if let handler = next.handler {
            return (variable != nil ? [variable! : ""] : [:], handler)
          }
        }
        for (variable, next) in self.pathVariableChildren {
          if let handler = next.handler {
            return (variable != nil ? [variable! : ""] : [:], handler)
          }
        }
        return nil
      }
      // There is at least one more component from the current path...
      guard let component = path[index].removingPercentEncoding else {
        return nil
      }
      // Look at all path children of the current segment
      for (selector, next) in self.pathChildren {
        if selector == component,
           let result = next.match(path: path, index: index + 1) {
          return result
        }
      }
      // Look at all variable children of the current segment
      for (variable, next) in self.variableChildren {
        if var result = next.match(path: path, index: index + 1) {
          if let variable {
            result.0[variable] = component
          }
          return result
        }
      }
      // Look at all path variable children of the current segment
      for (variable, next) in self.pathVariableChildren {
        for i in index...path.count {
          if var result = next.match(path: path, index: i) {
            if let variable {
              result.0[variable] = path[index..<i].joined(separator: "/")
            }
            return result
          }
        }
      }
      return nil
    }
    
    var debugDescription: String {
      var res = "Segment(path = \(self.pathChildren.keys), " +
                "var = \(self.variableChildren.keys), " +
                "pathvar = \(self.pathVariableChildren.keys)"
      if self.handler != nil {
        res += ", handler"
      }
      return res + ")"
    }
  }
  
  private var root: [String? : Segment] = [:]
  private let lock = NSLock()
  
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
  
  open func register(_ method: String?, path: String, handler: NanoHTTPRequestHandler?) {
    let selectors = self.selectors(from: path)
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    self.root.next(for: method).insert(selectors: selectors).handler = handler
  }
  
  open func merge(_ router: NanoHTTPRouter, withPrefix prefix: String) throws {
    guard let router = router as? NanoHTTPSegmentRouter else {
      throw NanoHTTPRouterError.incompatibleRouterForMerge
    }
    let selectors = self.selectors(from: prefix)
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    for (method, initial) in router.root {
      self.root.next(for: method).insert(selectors: selectors).merge(with: initial)
    }
  }
  
  open func route(_ method: String, path: String) -> ([String: String], NanoHTTPRequestHandler)? {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    let path = (path.components(separatedBy: "?").first ?? path).split("/")
    return self.root[method]?.match(path: path, index: 0) ??
           self.root[nil]?.match(path: path, index: 0)
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
