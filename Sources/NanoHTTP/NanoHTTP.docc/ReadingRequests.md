# Reading Requests

Get at the headers, the query, the route variables, forms, uploads and JSON that a client sent.

## Overview

A ``NanoHTTPRequest`` has everything the client sent, parsed:

```swift
let server = NanoHTTPServer()
server.post["/users/:id"] = { request in
  let method = request.method                              // "POST"
  let path = request.path                                  // "/users/42", percent-decoded
  let id = request.params["id"] ?? ""                      // "42": the variable of the route
  let agent = request.header("User-Agent") ?? "unknown"    // header names are case-insensitive
  let client = request.address ?? "unknown"                // the IP address of the client
  return .ok(.text("\(method) \(path): user \(id), \(request.body.count) bytes from \(agent) at \(client)"))
}
```

### Paths and query parameters are decoded

``NanoHTTPRequest/path``, the names and values of ``NanoHTTPRequest/queryParams`` and the values of the route
variables (``NanoHTTPRequest/params``, see <doc:Routing>) are percent-decoded text: `/caf%C3%A9?q=a%20b+c` has the path
`/café` and the query parameter `q` with the value `a b c`. In a query, `+` is a space (`%2B` is a plus); in a path, `+`
is a plus. Use the values as they are:

```swift
let server = NanoHTTPServer()
server.get["/search"] = { request in
  let query = request.query("q") ?? ""                  // decoded; the first parameter named q
  let tags = request.queries("tag")                     // all parameters named tag, in order
  return .ok(.text("You searched for \(query) in \(tags.joined(separator: ", "))"))
}
```

What the client sent is available as ``NanoHTTPRequest/rawPath`` and ``NanoHTTPRequest/rawQuery``, and the values of
the route variables as sent as ``NanoHTTPRequest/rawParams`` (`/users/a%2Fb` has `params["id"] == "a/b"` and
`rawParams["id"] == "a%2Fb"`; a path variable has its segments as sent, joined by `/`, see <doc:Routing>). The router
routes on the raw path, which is how an encoded slash (`%2F`) stays inside its segment, while
``NanoHTTPRequest/path`` cannot tell it from a separator.

Two things follow from this:

- **Do not decode the values again.** Decoding is done once. `removingPercentEncoding` on a value turns
  `%252e%252e` into `%2e%2e` the first time, which is what the client sent, and into `..` the second time, which
  is what it did not send: a check that looks at the first and a use that follows the second is a way out of a
  directory. A raw value (``NanoHTTPRequest/rawParams``, ``NanoHTTPRequest/rawPath``) has not been decoded yet:
  decode it at most once, and never a value that is decoded already.
- **The values can contain anything.** `%0A` is a line feed, `%00` a NUL character. Do not write a path or a query
  value to a log or into HTML as it is (``Swift/String/htmlEscaped``), and do not use one as a file path
  without checking it, a raw value of a route variable no more than a decoded one. Use
  ``NanoHTTPRequest/rawPath`` for logs: it cannot contain control characters.

Text that is not valid percent-encoding is kept as it is (`/100%` stays `/100%`), and bytes that are not valid UTF-8
become the replacement character U+FFFD.
- Header names are case-insensitive. If a header was sent several times, ``NanoHTTPRequest/header(_:)`` returns
  the values joined with `, ` (the `Cookie` headers with `; `).

### Cookies

``NanoHTTPRequest/cookie(_:)`` returns the value of a cookie that the client sent, and ``NanoHTTPRequest/cookies`` all of
them, by name. The values are percent-decoded once, like everything else of a request (``NanoHTTPCookie`` writes
them that way), and a pair of quotes around a value is removed. If a name appears twice, the first counts: it is the one
with the most specific path. A cookie has no attributes in a request: the client does not say where it came from or when
it ends. Treat the value as untrusted input, like any other.

```swift
let server = NanoHTTPServer()
server.get["/home"] = { request in
  guard let session = request.cookie("session") else {
    return .seeOther("/login")
  }
  return .ok(.text("Welcome back, session \(session)"))
}
```

Setting cookies is described in <doc:HandlersAndResponses#Cookies>.

### The body

The body is available as bytes once the request has been read completely, up to the limit of the server
(64 MiB unless you change ``NanoHTTPServerIO/Configuration/limits``; larger requests are answered with `413`).
``NanoHTTPRequest/bodyString`` reads it as text, in the charset of the `Content-Type` header (UTF-8 if it has none), or
gives `nil` if the bytes are no valid text.

``NanoHTTPRequest/json(_:decoder:)`` decodes a JSON body into a `Decodable` type. If the body is empty, no JSON or does
not fit the type, it throws a ``NanoHTTPError`` for `400 Bad Request` that says what is wrong (`The key 'name' is
missing`), so that a handler needs no code for bad input:

```swift
// file scope
struct ExampleNewItem: Codable {
  let name: String
}
```

```swift
let server = NanoHTTPServer()
server.post["/items"] = { request in
  let item = try request.json(ExampleNewItem.self)
  return .ok(.text("Created \(item.name)"))
}
```

Pass a `JSONDecoder` for other strategies for keys and dates. ``NanoHTTPRequest/jsonObject()`` parses JSON of any
shape into dictionaries and arrays.

### Forms

``NanoHTTPRequest/parseUrlencodedForm()`` reads the body of an HTML form (`application/x-www-form-urlencoded`).
Names and values are decoded; repeated names are kept in order.

```swift
let server = NanoHTTPServer()
server.post["/login"] = { request in
  let fields = Dictionary(request.parseUrlencodedForm(), uniquingKeysWith: { _, last in last })
  guard let user = fields["user"], !user.isEmpty else {
    return .badRequest(.text("A user name is required"))
  }
  return .ok(.text("Welcome, \(user)"))
}
```

### Uploads

``NanoHTTPRequest/parseMultiPartFormData()`` reads `multipart/form-data` bodies (forms with files). The whole
body is held in memory, so uploads are limited by ``NanoHTTPParser/Limits/maxBodyBytes``. Every part has its
``NanoHTTPRequest/MultiPart/headers``, its ``NanoHTTPRequest/MultiPart/body`` (exactly the bytes that were sent), and,
from its `Content-Disposition`, a ``NanoHTTPRequest/MultiPart/name`` and, for a file, a
``NanoHTTPRequest/MultiPart/fileName``.

```swift
let server = NanoHTTPServer()
server.post["/upload"] = { request in
  var report = ""
  for part in request.parseMultiPartFormData() {
    guard let name = part.name else { continue }
    report += "\(name): \(part.fileName ?? "(field)"), \(part.body.count) bytes\n"
  }
  return .ok(.text(report))
}
```

Names and file names can contain quotes (`\"`), `;`, `=` and `:`, and the extended form `filename*=UTF-8''...` is
understood. A body that is not well-formed (it has no closing boundary, or the headers of a part are not followed by an
empty line) is refused as a whole: the result is empty. So is a body with more parts than
``NanoHTTPParser/Limits/maxMultipartParts`` (1000), or with headers of a part that are longer than
``NanoHTTPParser/Limits/maxMultipartHeaderBytes`` (16 KiB). Treat file names as untrusted: never use them as paths
without checking.

## Topics

- ``NanoHTTPRequest``
- ``NanoHTTPParser``
- ``NanoHTTPParser/Limits``
