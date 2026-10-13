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

The writer is a ``NanoHTTPResponseBodyWriter``. Whatever it writes is sent at once, which makes this the way to send
events and progress as they happen. The length of such a body is not known, so the server sends it in *chunks*
(`Transfer-Encoding: chunked`): every write is a chunk, and the empty chunk at the end ends the body, so that the
connection can be used for the next request. An HTTP/1.0 client does not know chunks; it gets the body up to the end
of the connection, which is then closed. If writing fails because the client has gone, the function throws; there is
no way to answer the client any more, and the body is not ended properly, so that the client sees that it is not
complete.

If you know the length, say so with a `Content-Length` header: the body is then sent as it is, without chunks. The
server makes sure that it has that many bytes: a function that writes fewer or more leaves the connection unusable,
which the server ends (and logs).

```swift
let server = NanoHTTPServer()
server.get["/report"] = { _ in
  .custom(200, headers: ["Content-Length": "6"], contentType: "text/plain") { writer in
    try writer.write(Array("abc".utf8))
    try writer.write(Array("def".utf8))
  }
}
```

### What the server adds

The server writes the status line, `Content-Length` (or `Transfer-Encoding: chunked`) for the body, a `Date`
header, the `Content-Type` of the body, `Connection` where the connection is closed, and your headers. It does not add
`Server`. A `Content-Length`, `Transfer-Encoding`, `Connection` or `Date` header of yours is replaced by what the
server knows better (a handler that sets `Date` itself is the exception: the server adds none then). Responses that
have no body (`1xx`, `204`, `304`) have no `Content-Length` and no body, whatever the handler returned. Header names
must be valid tokens (a name with a space or a colon is dropped, and logged), and carriage return, line feed and NUL
in a header value are replaced by spaces, so that a value taken from a request cannot inject headers.

A body that is in memory is sent together with the head of the response, in one piece.

### HEAD, OPTIONS and methods that a path does not have

- A `HEAD` request is answered by the handler of the `GET` route (or by a handler that is registered for `HEAD`; one for
  all methods comes last). The response is the one that `GET` would get, `Content-Length` included, without
  the body: the handler sees the method `HEAD` and need not do anything special, and a function that writes a body
  is not called.
- If a path has routes, but not for the method of the request, the answer is `405 Method Not Allowed` with an `Allow` header
  that lists the methods that the path has (`Allow: GET, HEAD, POST, OPTIONS`). Without a route for the path it is `404`.
  The ``NanoHTTPServer/notFoundHandler`` is for paths without routes.
- An `OPTIONS` request is answered with `204 No Content` and the same `Allow` header, unless there is a handler for
  `OPTIONS` (`server.options["/items"] = ...`, which is also where cross-origin preflight requests can be answered).
  `OPTIONS *` lists the methods of all routes.

### Connections

HTTP/1.1 connections are **persistent**: the server keeps a connection open after a response and waits for the next
request, until the client sends `Connection: close`, the connection is idle for longer than the
``NanoHTTPServerIO/Configuration/idleTimeout``, or the server stops. An HTTP/1.0 client has its connection closed,
unless it sends `Connection: keep-alive` (and the response has a length). The server says what it does: a response
before the connection is closed has `Connection: close`, and one to a client that asked for `keep-alive` confirms it.

A connection also ends after a response whose end is not known (HTTP/1.0 and no `Content-Length`), after one whose body
could not be written completely, and after a request that cannot be answered (`400`, `413`, `414`, `431`, `408`, `417`, `501`,
`505`, which all have `Connection: close`).

Requests can have bodies of two kinds: with a `Content-Length`, or sent in chunks (`Transfer-Encoding: chunked`), which
the server puts together before the handler is called. A client that sends `Expect: 100-continue` before a body is
answered with `100 Continue` as soon as the server accepts the body (a body that is too large is refused instead). A
request with both a `Content-Length` and chunks, or with another `Transfer-Encoding` than `chunked`, is refused (`400`,
`501`), as is one that speaks another version than HTTP/1.0 and HTTP/1.1 (`505`).

## Topics

- ``NanoHTTPResponse``
- ``NanoHTTPResponse/Body``
- ``NanoHTTPRequestHandler``
- ``NanoHTTPError``
- ``NanoHTTPResponseBodyWriter``
