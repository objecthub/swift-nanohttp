//
//  HTMLNode.swift
//  NanoHTML
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
import NanoHTTP

/// A part of a page: an element, text, or several of them.
///
/// A page is a tree of nodes that is built with plain values, one tree per request, and
/// is turned into HTML by `rendered()`. Nothing is shared between pages, so building
/// pages needs no locks, on whichever thread it happens. Text and attribute values are
/// escaped when the page is rendered; ``Raw`` is the only way to insert HTML as it is.
public protocol HTMLNode {
  /// Appends the HTML of this node to `output`.
  func render(into output: inout String)
}

extension HTMLNode {
  /// The HTML of this node.
  public func rendered() -> String {
    var output = ""
    self.render(into: &output)
    return output
  }
}

/// Text, which is escaped when it is rendered. Strings in a builder block are text.
struct HTMLText: HTMLNode {
  let text: String
  
  func render(into output: inout String) {
    output += self.text.htmlEscaped
  }
}

/// The content of `script` and `style` elements, which is not HTML but code, and so is
/// inserted as it is. Only the end tag of the element is neutralized: `</script` becomes
/// `<\/script`, which has the same meaning in JavaScript strings and cannot end the
/// element early.
struct HTMLRawText: HTMLNode {
  let text: String
  let element: String
  
  func render(into output: inout String) {
    let end = "</" + self.element
    var rest = Substring(self.text)
    while let range = rest.range(of: end, options: .caseInsensitive) {
      output += rest[rest.startIndex..<range.lowerBound]
      output += "<\\/" + rest[range.lowerBound..<range.upperBound].dropFirst(2)
      rest = rest[range.upperBound...]
    }
    output += rest
  }
}

/// HTML that is inserted as it is. This is the one way to bypass escaping: use it for
/// markup that you wrote yourself (an entity such as `&copy;`, a snippet from a
/// template), never for text that came from a request, a file, or any other source that
/// is not yours.
///
/// ```swift
/// let page = Div {
///   P("Copyright ")
///   Raw("&copy; 2026")
/// }
/// ```
public struct Raw: HTMLNode {
  /// The HTML.
  public let html: String
  
  public init(_ html: String) {
    self.html = html
  }
  
  public func render(into output: inout String) {
    output += self.html
  }
}

/// Several nodes without an element around them, for example the result of a function that
/// returns the rows of a table.
///
/// ```swift
/// func rows(_ names: [String]) -> HTMLNode {
///   Fragment {
///     for name in names {
///       Tr { Td(name) }
///     }
///   }
/// }
/// ```
public struct Fragment: HTMLNode {
  let nodes: [HTMLNode]
  
  public init(_ nodes: [HTMLNode]) {
    self.nodes = nodes
  }
  
  public init(@HTMLBuilder _ content: () -> HTMLNode) {
    self.nodes = [content()]
  }
  
  public func render(into output: inout String) {
    for node in self.nodes {
      node.render(into: &output)
    }
  }
}

/// The result builder for the content of elements. Inside a block, every expression is a
/// node or text, and `if`, `else`, `switch` and `for` decide what a page contains:
///
/// ```swift
/// let showHint = true
/// let page = Ul {
///   for name in ["one", "two"] {
///     Li(name)
///   }
///   if showHint {
///     Li { "Written as "; B("bold"); " text" }
///   }
/// }
/// ```
@resultBuilder
public enum HTMLBuilder {
  public static func buildExpression(_ node: HTMLNode) -> HTMLNode {
    return node
  }
  
  /// A string is text: it is escaped.
  public static func buildExpression(_ text: String) -> HTMLNode {
    return HTMLText(text: text)
  }
  
  public static func buildBlock(_ nodes: HTMLNode...) -> HTMLNode {
    return Fragment(nodes)
  }
  
  public static func buildOptional(_ node: HTMLNode?) -> HTMLNode {
    return node ?? Fragment([])
  }
  
  public static func buildEither(first node: HTMLNode) -> HTMLNode {
    return node
  }
  
  public static func buildEither(second node: HTMLNode) -> HTMLNode {
    return node
  }
  
  public static func buildArray(_ nodes: [HTMLNode]) -> HTMLNode {
    return Fragment(nodes)
  }
}
