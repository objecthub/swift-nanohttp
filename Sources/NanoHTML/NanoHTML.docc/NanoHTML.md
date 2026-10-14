# ``NanoHTML``

Build web pages in Swift: elements are values, text is escaped, and nothing is shared between pages.

## Overview

NanoHTML is the companion of NanoHTTP for small pages: status and admin pages, forms, the user interface of a
tool. A page is a tree of values that a block builds for every request:

```swift
let server = NanoHTTPServer()
server["/hello/:name"] = htmlHandler { request in
  Html {
    Head { Title("Hello") }
    Body {
      H1("Hello, \(request.params["name"] ?? "world")!")
      A("Home").href("/")
    }
  }
}
```

Text and attribute values are escaped, void elements have no end tag, attributes come out in the order in which
you set them, and building a page needs no locks, also on a server that runs on one thread. Add the product
`NanoHTML` to your target next to `NanoHTTP`, and `import NanoHTML` where you build pages.

## Topics

### Essentials

- <doc:BuildingPages>
- ``htmlHandler(_:)``

### Content

- ``HTMLNode``
- ``HTMLBuilder``
- ``Raw``
- ``Fragment``

### Elements

- ``HTMLElement``
- ``CustomElement``
- ``Html``
- ``HTMLTag``
- ``HTMLContainerTag``
- ``HTMLVoidTag``
- ``HTMLRawTextTag``
- ``HTMLTags``
