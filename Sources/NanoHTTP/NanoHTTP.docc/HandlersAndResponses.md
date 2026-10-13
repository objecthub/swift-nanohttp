# Handlers and Responses

Answer requests with text, JSON, bytes, redirects or streamed content.

## Overview

A handler is a function ``NanoHTTPRequestHandler``: it takes a ``NanoHTTPRequest`` and returns a
``NanoHTTPResponse``, which consists of a status code, headers and a body. A handler can throw, see
<doc:HandlersAndResponses#Errors>.

### Creating responses

The static functions of ``NanoHTTPResponse`` create the usual responses:

```swift
let server = NanoHTTPServer()
server.get["/text"] = { _ in .ok(.text("plain text")) }
server.get["/page"] = { _ in .ok(.html("<!DOCTYPE html><h1>A page</h1>")) }
server.get["/data"] = { _ in .ok(.data(Data([0, 1, 2]), contentType: "application/octet-stream")) }
server.get["/old"] = { _ in .movedPermanently("/new") }
server.get["/login"] = { _ in .movedTemporarily("/signin") }
server.get["/secret"] = { _ in .unauthorized(headers: ["WWW-Authenticate": "Basic realm=\"demo\""]) }
server.get["/teapot"] = { _ in NanoHTTPResponse(statusCode: 418, body: "short and stout") }
```

`.ok`, `.badRequest`, `.notFound` and the other helpers take optional `headers` and a body; a string literal
is a text body. ``NanoHTTPResponse/init(statusCode:headers:body:)`` creates a response with any status.

### Errors

A handler that cannot answer a request can throw instead of building an error response. A ``NanoHTTPError``
becomes the response with its status code, its headers and, as a plain text body, its message:

```swift
let server = NanoHTTPServer()
server.get["/items/:id"] = { request in
  guard let id = Int(request.params["id"] ?? "") else {
    throw NanoHTTPError.badRequest("The id is not a number")           // 400
  }
  guard id < 100 else {
    throw NanoHTTPError.notFound("There is no item \(id)")            // 404
  }
  return .ok(.text("Item \(id)"))
}
server.get["/admin"] = { _ in
  throw NanoHTTPError.unauthorized(wwwAuthenticate: "Basic realm=\"admin\"")
}
server.get["/limit"] = { _ in throw NanoHTTPError.tooManyRequests("Slow down", retryAfter: 30) }
server.get["/other"] = { _ in throw NanoHTTPError(status: 418, message: "short and stout") }
```

Every other error that a handler throws is answered with `500 Internal Server Error` and the text
`Internal Server Error`. The details of the error are logged (with the method and path of the request), not sent to
the client: the description of a database error or of a missing file tells an attacker more than it should. To
decide differently, set ``NanoHTTPServer/errorHandler``, for example to answer all errors as JSON:

```swift
let server = NanoHTTPServer()
server.errorHandler = { error, request in
  guard let error = error as? NanoHTTPError else {
    return nil                                      // leave all other errors to the default
  }
  return NanoHTTPResponse(statusCode: error.status, body: .json(["error": error.message ?? ""]))
}
```

Middleware can catch errors as well, see <doc:MiddlewareAndExtending>.

### Bodies

| Body | Content type | Notes |
|---|---|---|
| `.empty` | none | `Content-Length: 0` |
| `.text(String)` | `text/plain; charset=utf-8` | |
| `.html(String)` | `text/html; charset=utf-8` | the whole document; `.htmlBody(content)` wraps content |
| `.json(Any)` | `application/json` | a dictionary or array that `JSONSerialization` can write |
| `.data(Data, contentType:)` | the given one, or `application/octet-stream` | |
| `.custom(writer, contentType:)` | the given one | streamed, length unknown |
| `.socket(session)` | none | switches the connection to another protocol |

### JSON

A `.json` body is written with `JSONSerialization`. A value that is not valid JSON (a `Date`, say) cannot be
written; the client then gets `500 Internal Server Error` and the reason is logged. To send a `Codable` value,
encode it yourself:

```swift
// file scope
struct ExampleItem: Codable {
  let id: Int
  let name: String
}
```

```swift
let server = NanoHTTPServer()
server.get["/items/:id"] = { request in
  let item = ExampleItem(id: Int(request.params["id"] ?? "") ?? 0, name: "Example")
  guard let data = try? JSONEncoder().encode(item) else {
    return .internalServerError()
  }
  return .ok(.data(data, contentType: "application/json"))
}
```

### Streaming

A `.custom` body is written by a function, so that content of any size can be sent without holding it in memory:

```swift
let server = NanoHTTPServer()
server.get["/countdown"] = { _ in
  .custom(200, contentType: "text/plain") { writer in
    for number in (1...5).reversed() {
      try writer.write(Array("\(number)\n".utf8))
    }
  }
}
```

The writer is a ``NanoHTTPResponseBodyWriter``. Whatever it writes is sent at once. The length of such a body is
not known, so the server closes the connection after it (see below). If writing fails because the client has
gone, the function throws; there is no way to answer the client any more.

### What the server adds

The server writes the status line, `Content-Length` for bodies of known length, `Connection: keep-alive`
where the connection stays open, the `Content-Type` of the body, and your headers. It does not add `Date` or
`Server`. Header names must be valid tokens (a name with a space or a colon is dropped, and logged), and
carriage return, line feed and NUL in a header value are replaced by spaces, so that a value taken from a request
cannot inject headers.

### Connections

HTTP/1.1 connections can be reused for several requests. This server keeps a connection open after a response
only if the client sent `Connection: keep-alive` and the response has a known length (not `.custom` and not
a file); otherwise it closes the connection after the response, without announcing that with a
`Connection: close` header. A client that wants to reuse connections has to open a new one for the next request.

## Topics

- ``NanoHTTPResponse``
- ``NanoHTTPResponse/Body``
- ``NanoHTTPRequestHandler``
- ``NanoHTTPError``
- ``NanoHTTPResponseBodyWriter``
