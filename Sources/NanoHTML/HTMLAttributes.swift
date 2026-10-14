//
//  HTMLAttributes.swift
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

// The attributes of HTML as methods of every element. They are not tied to the elements for which
// HTML defines them; ``HTMLElement/attribute(_:_:)`` sets any attribute that is not here.

extension HTMLElement {
  // MARK: Attributes with a value

  /// Sets the `id` attribute. With `nil` the attribute is left out.
  public func id(_ value: String?) -> Self {
    return self.attribute("id", value)
  }
  
  /// Sets the `title` attribute. With `nil` the attribute is left out.
  public func title(_ value: String?) -> Self {
    return self.attribute("title", value)
  }
  
  /// Sets the `lang` attribute. With `nil` the attribute is left out.
  public func lang(_ value: String?) -> Self {
    return self.attribute("lang", value)
  }
  
  /// Sets the `dir` attribute. With `nil` the attribute is left out.
  public func dir(_ value: String?) -> Self {
    return self.attribute("dir", value)
  }
  
  /// Sets the `style` attribute. With `nil` the attribute is left out.
  public func style(_ value: String?) -> Self {
    return self.attribute("style", value)
  }
  
  /// Sets the `role` attribute. With `nil` the attribute is left out.
  public func role(_ value: String?) -> Self {
    return self.attribute("role", value)
  }
  
  /// Sets the `tabindex` attribute. With `nil` the attribute is left out.
  public func tabindex(_ value: String?) -> Self {
    return self.attribute("tabindex", value)
  }
  
  /// Sets the `tabindex` attribute to a number.
  public func tabindex(_ value: Int) -> Self {
    return self.attribute("tabindex", String(value))
  }
  
  /// Sets the `accesskey` attribute. With `nil` the attribute is left out.
  public func accesskey(_ value: String?) -> Self {
    return self.attribute("accesskey", value)
  }
  
  /// Sets the `contenteditable` attribute. With `nil` the attribute is left out.
  public func contenteditable(_ value: String?) -> Self {
    return self.attribute("contenteditable", value)
  }
  
  /// Sets the `draggable` attribute. With `nil` the attribute is left out.
  public func draggable(_ value: String?) -> Self {
    return self.attribute("draggable", value)
  }
  
  /// Sets the `spellcheck` attribute. With `nil` the attribute is left out.
  public func spellcheck(_ value: String?) -> Self {
    return self.attribute("spellcheck", value)
  }
  
  /// Sets the `translate` attribute. With `nil` the attribute is left out.
  public func translate(_ value: String?) -> Self {
    return self.attribute("translate", value)
  }
  
  /// Sets the `inputmode` attribute. With `nil` the attribute is left out.
  public func inputmode(_ value: String?) -> Self {
    return self.attribute("inputmode", value)
  }
  
  /// Sets the `enterkeyhint` attribute. With `nil` the attribute is left out.
  public func enterkeyhint(_ value: String?) -> Self {
    return self.attribute("enterkeyhint", value)
  }
  
  /// Sets the `href` attribute. With `nil` the attribute is left out.
  public func href(_ value: String?) -> Self {
    return self.attribute("href", value)
  }
  
  /// Sets the `src` attribute. With `nil` the attribute is left out.
  public func src(_ value: String?) -> Self {
    return self.attribute("src", value)
  }
  
  /// Sets the `srcset` attribute. With `nil` the attribute is left out.
  public func srcset(_ value: String?) -> Self {
    return self.attribute("srcset", value)
  }
  
  /// Sets the `sizes` attribute. With `nil` the attribute is left out.
  public func sizes(_ value: String?) -> Self {
    return self.attribute("sizes", value)
  }
  
  /// Sets the `alt` attribute. With `nil` the attribute is left out.
  public func alt(_ value: String?) -> Self {
    return self.attribute("alt", value)
  }
  
  /// Sets the `rel` attribute. With `nil` the attribute is left out.
  public func rel(_ value: String?) -> Self {
    return self.attribute("rel", value)
  }
  
  /// Sets the `target` attribute. With `nil` the attribute is left out.
  public func target(_ value: String?) -> Self {
    return self.attribute("target", value)
  }
  
  /// Sets the `download` attribute. With `nil` the attribute is left out.
  public func download(_ value: String?) -> Self {
    return self.attribute("download", value)
  }
  
  /// Sets the `hreflang` attribute. With `nil` the attribute is left out.
  public func hreflang(_ value: String?) -> Self {
    return self.attribute("hreflang", value)
  }
  
  /// Sets the `media` attribute. With `nil` the attribute is left out.
  public func media(_ value: String?) -> Self {
    return self.attribute("media", value)
  }
  
  /// Sets the `type` attribute. With `nil` the attribute is left out.
  public func type(_ value: String?) -> Self {
    return self.attribute("type", value)
  }
  
  /// Sets the `crossorigin` attribute. With `nil` the attribute is left out.
  public func crossorigin(_ value: String?) -> Self {
    return self.attribute("crossorigin", value)
  }
  
  /// Sets the `integrity` attribute. With `nil` the attribute is left out.
  public func integrity(_ value: String?) -> Self {
    return self.attribute("integrity", value)
  }
  
  /// Sets the `loading` attribute. With `nil` the attribute is left out.
  public func loading(_ value: String?) -> Self {
    return self.attribute("loading", value)
  }
  
  /// Sets the `referrerpolicy` attribute. With `nil` the attribute is left out.
  public func referrerpolicy(_ value: String?) -> Self {
    return self.attribute("referrerpolicy", value)
  }
  
  /// Sets the `poster` attribute. With `nil` the attribute is left out.
  public func poster(_ value: String?) -> Self {
    return self.attribute("poster", value)
  }
  
  /// Sets the `preload` attribute. With `nil` the attribute is left out.
  public func preload(_ value: String?) -> Self {
    return self.attribute("preload", value)
  }
  
  /// Sets the `width` attribute. With `nil` the attribute is left out.
  public func width(_ value: String?) -> Self {
    return self.attribute("width", value)
  }
  
  /// Sets the `width` attribute to a number.
  public func width(_ value: Int) -> Self {
    return self.attribute("width", String(value))
  }
  
  /// Sets the `height` attribute. With `nil` the attribute is left out.
  public func height(_ value: String?) -> Self {
    return self.attribute("height", value)
  }
  
  /// Sets the `height` attribute to a number.
  public func height(_ value: Int) -> Self {
    return self.attribute("height", String(value))
  }
  
  /// Sets the `action` attribute. With `nil` the attribute is left out.
  public func action(_ value: String?) -> Self {
    return self.attribute("action", value)
  }
  
  /// Sets the `method` attribute. With `nil` the attribute is left out.
  public func method(_ value: String?) -> Self {
    return self.attribute("method", value)
  }
  
  /// Sets the `enctype` attribute. With `nil` the attribute is left out.
  public func enctype(_ value: String?) -> Self {
    return self.attribute("enctype", value)
  }
  
  /// Sets the `name` attribute. With `nil` the attribute is left out.
  public func name(_ value: String?) -> Self {
    return self.attribute("name", value)
  }
  
  /// Sets the `value` attribute. With `nil` the attribute is left out.
  public func value(_ value: String?) -> Self {
    return self.attribute("value", value)
  }
  
  /// Sets the `placeholder` attribute. With `nil` the attribute is left out.
  public func placeholder(_ value: String?) -> Self {
    return self.attribute("placeholder", value)
  }
  
  /// Sets the `for` attribute. With `nil` the attribute is left out.
  public func `for`(_ value: String?) -> Self {
    return self.attribute("for", value)
  }
  
  /// Sets the `form` attribute. With `nil` the attribute is left out.
  public func form(_ value: String?) -> Self {
    return self.attribute("form", value)
  }
  
  /// Sets the `list` attribute. With `nil` the attribute is left out.
  public func list(_ value: String?) -> Self {
    return self.attribute("list", value)
  }
  
  /// Sets the `accept` attribute. With `nil` the attribute is left out.
  public func accept(_ value: String?) -> Self {
    return self.attribute("accept", value)
  }
  
  /// Sets the `autocomplete` attribute. With `nil` the attribute is left out.
  public func autocomplete(_ value: String?) -> Self {
    return self.attribute("autocomplete", value)
  }
  
  /// Sets the `min` attribute. With `nil` the attribute is left out.
  public func min(_ value: String?) -> Self {
    return self.attribute("min", value)
  }
  
  /// Sets the `max` attribute. With `nil` the attribute is left out.
  public func max(_ value: String?) -> Self {
    return self.attribute("max", value)
  }
  
  /// Sets the `step` attribute. With `nil` the attribute is left out.
  public func step(_ value: String?) -> Self {
    return self.attribute("step", value)
  }
  
  /// Sets the `minlength` attribute. With `nil` the attribute is left out.
  public func minlength(_ value: String?) -> Self {
    return self.attribute("minlength", value)
  }
  
  /// Sets the `minlength` attribute to a number.
  public func minlength(_ value: Int) -> Self {
    return self.attribute("minlength", String(value))
  }
  
  /// Sets the `maxlength` attribute. With `nil` the attribute is left out.
  public func maxlength(_ value: String?) -> Self {
    return self.attribute("maxlength", value)
  }
  
  /// Sets the `maxlength` attribute to a number.
  public func maxlength(_ value: Int) -> Self {
    return self.attribute("maxlength", String(value))
  }
  
  /// Sets the `pattern` attribute. With `nil` the attribute is left out.
  public func pattern(_ value: String?) -> Self {
    return self.attribute("pattern", value)
  }
  
  /// Sets the `size` attribute. With `nil` the attribute is left out.
  public func size(_ value: String?) -> Self {
    return self.attribute("size", value)
  }
  
  /// Sets the `size` attribute to a number.
  public func size(_ value: Int) -> Self {
    return self.attribute("size", String(value))
  }
  
  /// Sets the `rows` attribute. With `nil` the attribute is left out.
  public func rows(_ value: String?) -> Self {
    return self.attribute("rows", value)
  }
  
  /// Sets the `rows` attribute to a number.
  public func rows(_ value: Int) -> Self {
    return self.attribute("rows", String(value))
  }
  
  /// Sets the `cols` attribute. With `nil` the attribute is left out.
  public func cols(_ value: String?) -> Self {
    return self.attribute("cols", value)
  }
  
  /// Sets the `cols` attribute to a number.
  public func cols(_ value: Int) -> Self {
    return self.attribute("cols", String(value))
  }
  
  /// Sets the `wrap` attribute. With `nil` the attribute is left out.
  public func wrap(_ value: String?) -> Self {
    return self.attribute("wrap", value)
  }
  
  /// Sets the `label` attribute. With `nil` the attribute is left out.
  public func label(_ value: String?) -> Self {
    return self.attribute("label", value)
  }
  
  /// Sets the `colspan` attribute. With `nil` the attribute is left out.
  public func colspan(_ value: String?) -> Self {
    return self.attribute("colspan", value)
  }
  
  /// Sets the `colspan` attribute to a number.
  public func colspan(_ value: Int) -> Self {
    return self.attribute("colspan", String(value))
  }
  
  /// Sets the `rowspan` attribute. With `nil` the attribute is left out.
  public func rowspan(_ value: String?) -> Self {
    return self.attribute("rowspan", value)
  }
  
  /// Sets the `rowspan` attribute to a number.
  public func rowspan(_ value: Int) -> Self {
    return self.attribute("rowspan", String(value))
  }
  
  /// Sets the `headers` attribute. With `nil` the attribute is left out.
  public func headers(_ value: String?) -> Self {
    return self.attribute("headers", value)
  }
  
  /// Sets the `scope` attribute. With `nil` the attribute is left out.
  public func scope(_ value: String?) -> Self {
    return self.attribute("scope", value)
  }
  
  /// Sets the `span` attribute. With `nil` the attribute is left out.
  public func span(_ value: String?) -> Self {
    return self.attribute("span", value)
  }
  
  /// Sets the `span` attribute to a number.
  public func span(_ value: Int) -> Self {
    return self.attribute("span", String(value))
  }
  
  /// Sets the `charset` attribute. With `nil` the attribute is left out.
  public func charset(_ value: String?) -> Self {
    return self.attribute("charset", value)
  }
  
  /// Sets the `content` attribute. With `nil` the attribute is left out.
  public func content(_ value: String?) -> Self {
    return self.attribute("content", value)
  }
  
  /// Sets the `http-equiv` attribute. With `nil` the attribute is left out.
  public func httpEquiv(_ value: String?) -> Self {
    return self.attribute("http-equiv", value)
  }
  
  /// Sets the `datetime` attribute. With `nil` the attribute is left out.
  public func datetime(_ value: String?) -> Self {
    return self.attribute("datetime", value)
  }
  
  /// Sets the `cite` attribute. With `nil` the attribute is left out.
  public func cite(_ value: String?) -> Self {
    return self.attribute("cite", value)
  }
  
  /// Sets the `start` attribute. With `nil` the attribute is left out.
  public func start(_ value: String?) -> Self {
    return self.attribute("start", value)
  }
  
  /// Sets the `start` attribute to a number.
  public func start(_ value: Int) -> Self {
    return self.attribute("start", String(value))
  }
  
  /// Sets the `sandbox` attribute. With `nil` the attribute is left out.
  public func sandbox(_ value: String?) -> Self {
    return self.attribute("sandbox", value)
  }
  
  /// Sets the `allow` attribute. With `nil` the attribute is left out.
  public func allow(_ value: String?) -> Self {
    return self.attribute("allow", value)
  }
  
  // MARK: Attributes without a value

  /// Sets the `hidden` attribute, or leaves it out if `condition` is false.
  public func hidden(_ condition: Bool = true) -> Self {
    return self.attribute("hidden", if: condition)
  }
  
  /// Sets the `autofocus` attribute, or leaves it out if `condition` is false.
  public func autofocus(_ condition: Bool = true) -> Self {
    return self.attribute("autofocus", if: condition)
  }
  
  /// Sets the `disabled` attribute, or leaves it out if `condition` is false.
  public func disabled(_ condition: Bool = true) -> Self {
    return self.attribute("disabled", if: condition)
  }
  
  /// Sets the `checked` attribute, or leaves it out if `condition` is false.
  public func checked(_ condition: Bool = true) -> Self {
    return self.attribute("checked", if: condition)
  }
  
  /// Sets the `selected` attribute, or leaves it out if `condition` is false.
  public func selected(_ condition: Bool = true) -> Self {
    return self.attribute("selected", if: condition)
  }
  
  /// Sets the `required` attribute, or leaves it out if `condition` is false.
  public func required(_ condition: Bool = true) -> Self {
    return self.attribute("required", if: condition)
  }
  
  /// Sets the `readonly` attribute, or leaves it out if `condition` is false.
  public func readonly(_ condition: Bool = true) -> Self {
    return self.attribute("readonly", if: condition)
  }
  
  /// Sets the `multiple` attribute, or leaves it out if `condition` is false.
  public func multiple(_ condition: Bool = true) -> Self {
    return self.attribute("multiple", if: condition)
  }
  
  /// Sets the `novalidate` attribute, or leaves it out if `condition` is false.
  public func novalidate(_ condition: Bool = true) -> Self {
    return self.attribute("novalidate", if: condition)
  }
  
  /// Sets the `controls` attribute, or leaves it out if `condition` is false.
  public func controls(_ condition: Bool = true) -> Self {
    return self.attribute("controls", if: condition)
  }
  
  /// Sets the `autoplay` attribute, or leaves it out if `condition` is false.
  public func autoplay(_ condition: Bool = true) -> Self {
    return self.attribute("autoplay", if: condition)
  }
  
  /// Sets the `loop` attribute, or leaves it out if `condition` is false.
  public func loop(_ condition: Bool = true) -> Self {
    return self.attribute("loop", if: condition)
  }
  
  /// Sets the `muted` attribute, or leaves it out if `condition` is false.
  public func muted(_ condition: Bool = true) -> Self {
    return self.attribute("muted", if: condition)
  }
  
  /// Sets the `async` attribute, or leaves it out if `condition` is false.
  public func async(_ condition: Bool = true) -> Self {
    return self.attribute("async", if: condition)
  }
  
  /// Sets the `defer` attribute, or leaves it out if `condition` is false.
  public func `defer`(_ condition: Bool = true) -> Self {
    return self.attribute("defer", if: condition)
  }
  
  /// Sets the `nomodule` attribute, or leaves it out if `condition` is false.
  public func nomodule(_ condition: Bool = true) -> Self {
    return self.attribute("nomodule", if: condition)
  }
  
  /// Sets the `open` attribute, or leaves it out if `condition` is false.
  public func open(_ condition: Bool = true) -> Self {
    return self.attribute("open", if: condition)
  }
  
  /// Sets the `reversed` attribute, or leaves it out if `condition` is false.
  public func reversed(_ condition: Bool = true) -> Self {
    return self.attribute("reversed", if: condition)
  }
  
  /// Sets the `allowfullscreen` attribute, or leaves it out if `condition` is false.
  public func allowfullscreen(_ condition: Bool = true) -> Self {
    return self.attribute("allowfullscreen", if: condition)
  }
  
  /// Sets the `playsinline` attribute, or leaves it out if `condition` is false.
  public func playsinline(_ condition: Bool = true) -> Self {
    return self.attribute("playsinline", if: condition)
  }
  
  /// Sets the `ismap` attribute, or leaves it out if `condition` is false.
  public func ismap(_ condition: Bool = true) -> Self {
    return self.attribute("ismap", if: condition)
  }
}
