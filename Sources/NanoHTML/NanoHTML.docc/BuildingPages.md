# Building Pages

Write small web pages as Swift code.

## Overview

A page is built from element types (``Html``, ``Body``, ``H1``, ``A``, ``Table``, ...) whose content is a block. Text
is a string, attributes are set by methods of the element. ``htmlHandler(_:)`` runs the block for every request and
answers with the page, as `text/html; charset=utf-8`:

```swift
let server = NanoHTTPServer()
server["/"] = htmlHandler { _ in
  Html {
    Head {
      Title("Demo")
    }
    Body {
      H1("Routes")
      Ul {
        for route in server.routes.sorted() {
          Li { A(route).href(route) }
        }
      }
    }
  }
}
```

The block receives the request, so a page can show what was asked for: `htmlHandler { request in ... }`. It may
throw; the error is answered like the error of any other handler.

### Text, attributes and content

- An element with text is written `P("text")`, an element with content `Div { ... }`. In a block, a string is text
  too: `P { "Hello, "; B("world") }`.
- Attributes are methods that return the changed element, so they follow the element, also after a block:
  `A("Sign in").href("/login")`, `Form { ... }.method("POST").action("/login")`. There are methods for the usual
  attributes (`href`, `src`, `type`, `name`, `value`, `placeholder`, `style`, `width`, ...), numbers where numbers make
  sense (`Img().width(300)`), and ``HTMLElement/attribute(_:_:)`` for any other: `Div().attribute("lang", "de")`.
- `class` adds to the class names that are there: `Div().class("card").class("wide")` is `class="card wide"`.
  Every other attribute that is set again replaces its value.
- Attributes without a value are methods with an optional condition: `Input().autofocus()`,
  `Button("Save").disabled(isBusy)`. A value of `nil` leaves an attribute out: `A("x").title(maybeTitle)`.
- ``HTMLElement/data(_:_:)`` sets `data-` attributes, ``HTMLElement/aria(_:_:)`` sets `aria-` attributes, and
  ``HTMLElement/on(_:_:)`` the script of an event: `Button("x").on("click", "go()")`.
- ``CustomElement`` writes an element that has no type of its own, for example a web component:
  `CustomElement("my-widget") { ... }`.

### Loops and conditions

A block can contain `for`, `if`, `if let` and `switch`, so that a page is built from data:

```swift
let people = ["Ada": 36, "Grace": 85]
let table = Table {
  Thead { Tr { Th("Name"); Th("Age") } }
  Tbody {
    for (name, age) in people.sorted(by: { $0.key < $1.key }) where age > 18 {
      Tr { Td(name); Td("\(age)") }
    }
  }
}
```

Functions can return nodes (``HTMLNode``); ``Fragment`` returns several nodes without an element around them.

### Escaping

Text and attribute values are **escaped** when the page is rendered: `P(request.path)` is safe, also if the path
contains `<script>`. ``Raw`` is the only way to write HTML as it is. Use it for markup that you wrote, for example
`Raw("&copy;")`, never for text from a request, a file or a database.

The content of ``Script`` and ``Style`` is code: it is written as it is, and only a `</script` that would end the
element early is changed to `<\/script`. A script that is built from untrusted text is unsafe all the same, and so is a
URL in `href` or `src` that you did not check (`javascript:` URLs are not filtered); event attributes are scripts too.

### The elements

The element types are the ones of HTML that are not obsolete, with the tag name in capitalized form: `Div`, `Ul`, `Li`,
`Table`, `Tr`, `Td`, `H1`...`H6`, `Form`, `Input`, `Button`, `Select`, `Option`, `Img`, `Script`, `Style`, `Link`,
`Meta`, and so on. Two names differ from the tag because the framework `Foundation` has types of that name: ``DataValue``
is `<data>` and ``ProgressBar`` is `<progress>`. Some names are also names of types in SwiftUI and AppKit (`Button`,
`Label`, `Link`, `Form`, `Table`, `Menu`, `Section`, `Canvas`): in a file that imports one of those frameworks, write the
module name, `NanoHTML.Button(...)`. Elements that were removed from HTML (`center`, `font`, `marquee`, ...) have no
type: use ``CustomElement``.

Elements that have no content (`Br`, `Img`, `Input`, `Meta`, `Link`, `Hr`, ...) have no end tag, and cannot be given
content. ``Html`` writes the document type, `<!DOCTYPE html>`, before itself, so a handler that returns a fragment sends
a fragment.

### Pages as responses

``htmlHandler(_:)`` is a shortcut. To answer with a page from any handler, use `NanoHTTPResponse.html(_:status:headers:)`:

```swift
let server = NanoHTTPServer()
server.notFoundHandler = { request in
  .html(Html { Body { P("There is nothing at \(request.path).") } }, status: 404)
}
```

A page is rendered at once, so the response has a length and the connection can be used again.

### Things to know

- Pages are values and share nothing. Building them needs no locks, on a server that uses a thread per connection as
  well as on one that runs on one thread.
- Attributes are written in the order in which they were set, so the output is the same on every run.
- A page that is built from a template language, or a bundled file, is often the better choice for anything bigger.
  This module is meant for small status and admin pages and for the user interface of a tool.

### Coming from the builder of 1.x

The closures and global variables of 1.x (`html { body { h1 { inner = "x" } } }`) are gone, which also ends their clashes
with member names (`name`, `title`, `type`) and the lock that rendered pages one at a time.

| 1.x | 2.0 |
|---|---|
| `html { body { ... } }` | `Html { Body { ... } }` |
| `h1 { inner = "x" }` | `H1("x")` (the text is escaped) |
| `a { href = u; inner = t }` | `A(t).href(u)` |
| `p { inner = htmlText }` | `P { Raw(htmlText) }` |
| `classs = "c"`, `idd = "i"`, `forr = "f"` | `.class("c")`, `.id("i")`, `.for("f")` |
| `ul(items) { item in li { ... } }` | `Ul { for item in items { Li { ... } } }` |
| `element("x", ["data-id": "7"]) { ... }` | `CustomElement("x") { ... }.data("id", "7")` |
| `htmlHandler { ... }` | `htmlHandler { request in ... }` |
| `htmlHandler { ... }(request)` | `htmlHandler { request in ... }` (the block gets the request) |
| `center`, `font`, `marquee`, ... | a style, or ``CustomElement`` |

## Topics

- ``htmlHandler(_:)``
- ``Html``
- ``HTMLElement``
- ``Raw``
- ``Fragment``
