//
//  HTMLElement.swift
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

/// What an element type is: its tag name, and whether it has content. Element types are described by
/// enumerations in ``HTMLTags``; use the types that are built on them, such as ``Div``.
public protocol HTMLTag {
  /// The name of the tag, in lower case.
  static var name: String { get }
  /// Whether the element can have no content and no end tag (`br`, `img`, `input`, ...).
  static var isVoid: Bool { get }
  /// Text that is written before the start tag. It is the document type for `html`.
  static var prefix: String { get }
}

extension HTMLTag {
  public static var isVoid: Bool { return false }
  public static var prefix: String { return "" }
}

/// Tags of elements that have content: text and other elements.
public protocol HTMLContainerTag: HTMLTag {}

/// Tags of elements that never have content: they are written without an end tag.
public protocol HTMLVoidTag: HTMLTag {}

extension HTMLVoidTag {
  public static var isVoid: Bool { return true }
}

/// Tags of elements whose content is code and not HTML (`script`, `style`).
public protocol HTMLRawTextTag: HTMLTag {}

/// An element of a page: a tag, attributes and content.
///
/// The element types of HTML (`Div`, `A`, `Ul`, ...) are this type with a tag. Content is written as
/// a block, or as text for elements that contain only text. Attributes are set by calling methods
/// on the element, which return the changed element:
///
/// ```swift
/// let link = A("Sign in").href("/login").class("button")
/// let card = Div {
///   H2("Title")
///   P("Some text.")
/// }
/// .id("card").class("wide")
/// ```
///
/// Text and attribute values are escaped; an element is a plain value, and building one needs no
/// locks. Setting an attribute again replaces its value, except for `class`, whose values are added.
/// Attributes appear in the order in which they were set. A value of `nil` leaves the attribute out.
public struct HTMLElement<Kind: HTMLTag>: HTMLNode {
  var tagName: String
  var isVoidElement: Bool
  var attributeList: [(name: String, value: String?)] = []
  var children: [HTMLNode] = []
  
  init(tagName: String, isVoid: Bool) {
    self.tagName = tagName
    self.isVoidElement = isVoid
  }
  
  init() {
    self.init(tagName: Kind.name, isVoid: Kind.isVoid)
  }
  
  public func render(into output: inout String) {
    output += Kind.prefix
    guard !self.tagName.isEmpty else { // the name of a custom element was not valid: only its content
      for child in self.children {
        child.render(into: &output)
      }
      return
    }
    output += "<" + self.tagName
    for (name, value) in self.attributeList {
      output += " " + name
      if let value = value {
        output += "=\"" + value.htmlEscaped + "\""
      }
    }
    output += ">"
    if self.isVoidElement {
      return
    }
    for child in self.children {
      child.render(into: &output)
    }
    output += "</" + self.tagName + ">"
  }
  
  /// Sets an attribute, which replaces an earlier value. With `nil` the attribute is left out.
  /// Names that are not valid for attributes are ignored.
  public func attribute(_ name: String, _ value: String?) -> Self {
    guard HTMLElement.isValidName(name) else {
      return self
    }
    var copy = self
    copy.attributeList.removeAll { $0.name == name }
    if let value = value {
      copy.attributeList.append((name, value))
    }
    return copy
  }
  
  /// Sets an attribute that has no value, such as `disabled`, if `condition` is true; otherwise
  /// the attribute is left out.
  public func attribute(_ name: String, if condition: Bool = true) -> Self {
    guard HTMLElement.isValidName(name) else {
      return self
    }
    var copy = self
    copy.attributeList.removeAll { $0.name == name }
    if condition {
      copy.attributeList.append((name, nil))
    }
    return copy
  }
  
  /// Adds names to the `class` attribute, separated by a space from the ones that are there.
  public func `class`(_ names: String?) -> Self {
    guard let names = names, !names.isEmpty else {
      return self
    }
    let existing = self.attributeList.first { $0.name == "class" }?.value
    return self.attribute("class", existing.map { $0 + " " + names } ?? names)
  }
  
  /// Sets a data attribute: `data("id", "7")` is `data-id="7"`.
  public func data(_ name: String, _ value: String?) -> Self {
    return self.attribute("data-" + name, value)
  }
  
  /// Sets an ARIA attribute: `aria("label", "Close")` is `aria-label="Close"`.
  public func aria(_ name: String, _ value: String?) -> Self {
    return self.attribute("aria-" + name, value)
  }
  
  /// Sets the script of an event handler: `on("click", "go()")` is `onclick="go()"`. The script is
  /// JavaScript, which this module cannot make safe: do not build it from untrusted text.
  public func on(_ event: String, _ script: String?) -> Self {
    return self.attribute("on" + event, script)
  }
  
  /// Whether `name` can be used as the name of an attribute or a custom element: letters, digits and
  /// `-`, `_`, `:` and `.`, starting with a letter, `_` or `:`.
  static func isValidName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first,
          first.isASCII, first.properties.isAlphabetic || first == "_" || first == ":" else {
      return false
    }
    return name.unicodeScalars.allSatisfy {
      $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "-_:.".unicodeScalars.contains($0))
    }
  }
}

// MARK: - Content

extension HTMLElement where Kind: HTMLContainerTag {
  /// An element without content.
  public init() {
    self.init(tagName: Kind.name, isVoid: false)
  }
  
  /// An element that contains text. The text is escaped.
  public init(_ text: String) {
    self.init()
    self.children = [HTMLText(text: text)]
  }
  
  /// An element with content: text and other elements.
  public init(@HTMLBuilder _ content: () -> HTMLNode) {
    self.init()
    self.children = [content()]
  }
}

extension HTMLElement where Kind: HTMLVoidTag {
  /// An element that cannot have content.
  public init() {
    self.init(tagName: Kind.name, isVoid: true)
  }
}

extension HTMLElement where Kind: HTMLRawTextTag {
  /// An element without content.
  public init() {
    self.init(tagName: Kind.name, isVoid: false)
  }
  
  /// An element with code as its content, which is inserted as it is: `Script("start()")`. The end
  /// tag of the element is neutralized if the code contains it.
  public init(_ code: String) {
    self.init()
    self.children = [HTMLRawText(text: code, element: Kind.name)]
  }
}

// MARK: - Elements that have no type of their own

extension HTMLTags {
  /// The tag of ``CustomElement``.
  public enum Custom: HTMLTag {
    public static let name = ""
  }
}

/// An element with a name of your choosing, for example a web component: `CustomElement("my-widget")`.
/// Its content and attributes are set like those of any other element. A name that is not valid
/// (letters, digits and `-`, starting with a letter) leaves only the content.
public typealias CustomElement = HTMLElement<HTMLTags.Custom>

extension HTMLElement where Kind == HTMLTags.Custom {
  /// An element without content, which has no end tag if `isVoid` is true.
  public init(_ name: String, isVoid: Bool = false) {
    self.init(tagName: HTMLElement.isValidName(name) ? name : "", isVoid: isVoid)
  }
  
  /// An element with text as its content. The text is escaped.
  public init(_ name: String, text: String) {
    self.init(name)
    self.children = [HTMLText(text: text)]
  }
  
  /// An element with content: text and other elements.
  public init(_ name: String, @HTMLBuilder content: () -> HTMLNode) {
    self.init(name)
    self.children = [content()]
  }
}
