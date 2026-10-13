# Reading Requests

Get at the headers, the query, the route variables, forms, uploads and JSON that a client sent.

## Overview

A ``NanoHTTPRequest`` has everything the client sent, parsed:

```swift
let server = NanoHTTPServer()
server.post["/users/:id"] = { request in
  let method = request.method                              // "POST"
  let path = request.path                                  // "/users/42", as sent (percent-encoded)
  let id = request.params["id"] ?? ""                      // "42": the variable of the route
  let agent = request.header("User-Agent") ?? "unknown"    // header names are case-insensitive
  let client = request.address ?? "unknown"                // the IP address of the client
  return .ok(.text("\(method) \(path): user \(id), \(request.body.count) bytes from \(agent) at \(client)"))
}
```

### What is decoded and what is not

- ``NanoHTTPRequest/path`` is **not** percent-decoded, and neither are the names and values of
  ``NanoHTTPRequest/queryParams``. `?q=a%20b` gives the value `a%20b`, and a `+` stays a `+`. Decode what you use:

```swift
let server = NanoHTTPServer()
server.get["/search"] = { request in
  let raw = request.queryParams.first { $0.0 == "q" }?.1 ?? ""
  // `+` means a space in a query; replace it before the percent sequences are decoded.
  let query = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
  return .ok(.text("You searched for: \(query)"))
}
```

- The values of route variables written `:name` are decoded; the values of `::name` are not (see <doc:Routing>).
- Header names are case-insensitive. If a header was sent several times, ``NanoHTTPRequest/header(_:)`` returns
  the values joined with `, `.

### The body

The body is available as bytes once the request has been read completely, up to the limit of the server
(64 MiB unless you change ``NanoHTTPServerIO/Configuration/limits``; larger requests are answered with `413`).

```swift
// file scope
struct ExampleNewItem: Codable {
  let name: String
}
```

```swift
let server = NanoHTTPServer()
server.post["/items"] = { request in
  guard let item = try? JSONDecoder().decode(ExampleNewItem.self, from: Data(request.body)) else {
    return .badRequest(.text("Invalid JSON"))
  }
  return .ok(.text("Created \(item.name)"))
}
```

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
body is held in memory, so uploads are limited by ``NanoHTTPParser/Limits/maxBodyBytes``.

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

Names and file names that contain `;`, `=` or `:` are not parsed correctly. Treat file names as untrusted: never
use them as paths without checking.

## Topics

- ``NanoHTTPRequest``
- ``NanoHTTPParser``
- ``NanoHTTPParser/Limits``
