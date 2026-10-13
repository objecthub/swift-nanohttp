# The HTML Builder

Write small web pages as Swift code.

## Overview

The builder describes a page with nested closures. Element functions (`html`, `body`, `h1`, `a`, `table`, ...) create
elements; attributes and content are set with assignments inside the closure of an element:

```swift
let server = NanoHTTPServer()
server["/"] = htmlHandler {
  html {
    head {
      title { inner = "Demo" }
    }
    body {
      h1 { inner = "Routes" }
      ul(server.routes.sorted()) { route in
        li {
          a { href = route; inner = route.htmlEscaped }
        }
      }
    }
  }
}
```

``htmlHandler(_:)`` runs the closure for every request, adds `<!DOCTYPE html>` and answers with
`text/html; charset=utf-8`.

### Attributes and content

- Attributes are variables with the name of the attribute: `href`, `src`, `type`, `name`, `value`, `style`,
  `placeholder`, `onclick`, and so on. Names that are Swift keywords have a different spelling: `classs` (class),
  `idd` (id), `forr` (for), `acceptt` (accept), `deferr` (defer); the elements `var` and `element` are `varr` and
  `elementt`. Any element and attribute can be written with ``element(_:_:_:)``:
  `element("section", ["data-id": "7"]) { inner = "text" }`.
- `inner` is the content of the element **as HTML**, inserted unchanged, and replaces anything built inside the
  closure. Text that does not come from you must be escaped with ``Swift/String/htmlEscaped``.
- The values of attributes are escaped as far as quotes go (a `"` becomes `&quot;`), so they cannot end the attribute.
- Sequences have helpers: `ul(items) { item in ... }`, `table(rows) { row in ... }`, `tbody(rows) { ... }`.

### Things to know

- The builder keeps its state in variables that exist once per process. To make that safe, ``htmlHandler(_:)``
  builds one page at a time: the closures of two requests do not run at the same time. Keep them short, and do not
  wait for slow work in them; compute what the page shows before.
- The order of the attributes of an element is not defined.
- Elements that have no end tag in HTML (`br`, `img`, `input`, `meta`, `link`) are written with an end tag
  (`<br></br>`), which browsers tolerate for most of them but treat as a second `<br>`.
- The names of the attributes are global, which can clash with members of your own types: inside a type that has a
  property `name`, `title` or `value`, a plain `name = "x"` assigns to that property. Write
  `NanoHTTP.name = "x"` there, or build pages in a free function.
- A page built from a template language or a bundled file is often the better choice for anything bigger; this
  builder is meant for small status and admin pages.

## Topics

- ``htmlHandler(_:)``
- ``element(_:_:_:)``
- ``NanoHTMLClosure``
