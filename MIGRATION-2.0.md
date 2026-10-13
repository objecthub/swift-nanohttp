# Migrating from 1.x to 2.0

2.0 is not released yet; this guide grows with the changes on the way. Every item says what to change.

## Server configuration

A server is configured with one object, `server.configuration` (`NanoHTTPServerIO.Configuration`), instead of
properties and parameters of `start`.

| 1.x | 2.0 |
|---|---|
| `server.listenAddressIPv4 = "127.0.0.1"` and `start(8080, forceIPv4: true)` | nothing: loopback is the default |
| no address (all network interfaces) | `server.configuration.listenAddress = .allInterfaces` |
| `server.listenAddressIPv4 = "192.168.1.20"` and `forceIPv4: true` | `server.configuration.listenAddress = .address("192.168.1.20")` |
| `server.listenAddressIPv6 = "::1"` | `server.configuration.listenAddress = .address("::1")` |
| `server.limits = NanoHTTPParser.Limits(...)` | `server.configuration.limits = NanoHTTPParser.Limits(...)` |
| `start(8080, priority: .userInitiated, handlerPriority: .utility)` | `configuration.acceptQoS = .userInitiated`, `configuration.connectionQoS = .utility`, `start(8080)` |
| `override func listen(priority:)` | `override func listen()` |
| `NanoSocket.tcpSocketForListen(port, true, 8, "127.0.0.1")` | `NanoSocket.tcpSocketForListen(port, .loopback, backlog: 8)` |

**Check who must reach the server.** A 1.x server without an address listened on all network interfaces. In 2.0 that
needs `.allInterfaces`; without it, devices on the network get "connection refused", and an iOS app that is meant to
be reached from another device stops working. A server that is only used by the same machine needs no change, and is
no longer exposed to the network by accident.

`forceIPv4` is gone: `.loopback` is an IPv4 socket (`127.0.0.1`), `.allInterfaces` is one socket for IPv4 and IPv6,
and `.address(_)` uses the family of the address. `.address("0.0.0.0")` listens on all IPv4 interfaces only.

`start` takes only the port, and returns after the server has started to listen.

**`priority: nil` is gone**, and with it the one-thread mode of 1.x. Use
`server.configuration.threading = .singleThread` instead (see below): `start(8080)` runs the whole server on one
thread of its own, and `run(8080)` on the calling thread, like `start(8080, priority: nil)` did. In 1.x, `priority: nil`
served the connections on the accepting thread (`handlerPriority: nil`) or accepted on the calling thread (`priority:
nil`); the new mode is better than both because connections that wait for a request no longer block the thread.
The one-thread mode does not use `connectionQoS`; `acceptQoS` is the priority of its thread.

```swift
let server = NanoHTTPServer()
server.configuration.threading = .singleThread
try server.run(8080)
```

## Timeouts and the number of connections

New defaults in `server.configuration`: `idleTimeout` 60 s, `readTimeout` 30 s, `writeTimeout` 30 s and
`maxConnections` 128. A client that is silent for a minute is disconnected, a request that stalls for 30 seconds gets
`408`, and the 129th simultaneous connection gets `503`. Raise or disable (`nil`) what does not fit, for example for
clients that keep many connections open for a long time:

```swift
let server = NanoHTTPServer()
server.configuration.idleTimeout = nil
server.configuration.maxConnections = 512
```

WebSocket sessions are not disconnected for being silent, but each one counts towards `maxConnections` and occupies a
thread.

## Handlers can throw

`NanoHTTPRequestHandler` is now `(NanoHTTPRequest) throws -> NanoHTTPResponse`. Handlers that you write as closures
need no change: a closure that cannot throw is accepted where a throwing one is expected. What changes is the code
that *calls* a handler, in tests for example, and the handlers that `htmlHandler`, `share`, `browse` and
`websocket` return:

```swift
let handler = htmlHandler { p { inner = "hi" } }
let request = NanoHTTPRequest(method: "GET", path: "/")
let response = try handler(request)                   // 1.x: handler(request)
```

A subclass of `NanoHTTPServerIO` that overrides `handle(connection:)` and calls `connection.handler(connection.request)`
by itself should call `connection.response()` instead, which also answers the errors that the handler throws.

Throwing is optional. Where a handler built an error response, it can throw an error:

```swift
let items = ["1": "pen"]
let server = NanoHTTPServer()
server.get["/items/:id"] = { request in
  guard let item = items[request.params["id"] ?? ""] else {
    throw NanoHTTPError.notFound("No such item")      // 1.x: return .notFound(.text("No such item"))
  }
  return .ok(.text(item))
}
```

`NanoHTTPError` has a status code, headers and a message (a plain text body), and a function for every usual
status (`.badRequest`, `.unauthorized(wwwAuthenticate:)`, `.forbidden`, `.notFound`, `.methodNotAllowed(allow:)`,
`.conflict`, `.payloadTooLarge`, `.unprocessableContent`, `.tooManyRequests(retryAfter:)`, ...). Every other error
that a handler throws is answered with `500 Internal Server Error` and no details; the details are logged.
`server.errorHandler` changes how errors are answered, for example as JSON.

## Sessions

`NanoHTTPResponse.Body` has a new case, `.session(NanoSocketSession)`; a `switch` over a body needs to handle it.
`websocket(...)` and `switchProtocols(_:_:)` work as before. A server that runs on one thread
(`threading = .singleThread`) serves WebSockets without blocking: see `NanoSocketSession` for protocols of your
own, and the article about WebSockets for a chat that needs no locks.

## Middleware wraps the request

The type of `server.middleware` changed from `(NanoHTTPRequest) -> NanoHTTPResponse?`, which could only answer a
request or let it pass, to `NanoHTTPMiddleware`, `(NanoHTTPRequest, next) throws -> NanoHTTPResponse`: it gets the
rest of the chain as `next`, so that it can change the response, catch errors, and measure how long the handler took.

| 1.x | 2.0 |
|---|---|
| `return nil` (let the request pass) | `return try next(request)` |
| `return .unauthorized(.text("denied"))` (answer) | the same, or `throw NanoHTTPError.unauthorized("denied")`; do not call `next` |
| `{ request in ... }` | `{ request, next in ... }` |

```swift nocompile
// 1.x
server.middleware.append { request in
  request.header("x-api-key") == "secret" ? nil : .unauthorized(.text("An API key is required"))
}
```

```swift
// 2.0
let server = NanoHTTPServer()
server.middleware.append { request, next in
  request.header("x-api-key") == "secret" ? try next(request) : .unauthorized(.text("An API key is required"))
}
```

What stays: the first middleware runs first, middleware sees every request before it is routed (and can rewrite
`request.path`), and the order of several checks is the same. What is new: middleware also sees the response, and it
sees the requests that no route matches together with their `404`. Variables of the route (`request.params`) are known
after `next` has returned.

## Paths and query values are decoded (H1)

In 1.x, `request.path` and the values of `request.queryParams` were still percent-encoded, a `+` in a query stayed a `+`,
the router decoded the values of `:variables` but not those of `::variables`, and the file handlers decoded the rest.
In 2.0 everything that you read from a request is decoded text, once:

| | 1.x | 2.0 |
|---|---|---|
| `request.path` for `/caf%C3%A9` | `"/caf%C3%A9"` | `"/café"` |
| `request.queryParams` for `?q=a%20b+c` | `("q", "a%20b+c")` | `("q", "a b c")` |
| `request.params` for `:name` | decoded | decoded |
| `request.params` for `::path` | **not** decoded | decoded |
| the path as sent | `request.path` | `request.rawPath` |
| the query as sent | (not available) | `request.rawQuery` |

New: `request.query("q")` (the first value of a parameter), `request.queries("tag")` (all values),
`request.bodyString` and `request.json(Type.self)`, which throws `NanoHTTPError.badRequest` with a message that says what is wrong
with the body. The router routes on `rawPath`; setting `request.path` (or `rawPath`) in middleware re-routes the request.

**Remove the decoding that you did yourself.** This is the one change that can open a hole if it is overlooked:

```swift nocompile
// 1.x
let name = request.queryParams.first { $0.0 == "name" }?.1.removingPercentEncoding   // decoded by you
let file = request.params["path"]?.removingPercentEncoding                           // decoded by you
// 2.0: both are decoded already; decoding again turns %252e%252e into %2e%2e, and a second time into ".."
let name = request.query("name")
let file = request.params["path"]
```

Code that checked a value for `..` and decoded it afterwards was already unsafe in 1.x; code that decodes a value of 2.0
again has the same flaw. Search your code for `removingPercentEncoding`, `replacingOccurrences(of: "+"` and
`addingPercentEncoding` next to `request.path`, `queryParams` and `params`, and delete the decoding of values
that you got from the framework. `share(directory:)` and `browse(directory:)` are changed already.

Two smaller things that come with it: the decoded path can contain line breaks and NUL characters (`%0A`, `%00`), so log
`request.rawPath` instead of `request.path`, and `NanoHTTPRequest(method:path:queryParams:)` takes decoded text now
(`path: "/a b"`, not `"/a%20b"`); use `NanoHTTPRequest(method:rawPath:rawQuery:)` for the encoded form.

Targets with bytes that are not ASCII (a client that sends `é` as UTF-8 without encoding it), the absolute form (`GET http://host/a`) and
`*` are handled by the parser now; `URLComponents` is no longer involved in reading a request.

## HTTP as clients expect it (H4, H7, H10)

The server does what HTTP/1.1 clients assume. Most of it is invisible; these are the changes that are not:

- **Connections are persistent.** After a response the server waits for the next request on the connection (it
  used to close it unless the request said `Connection: keep-alive`), until the client says `Connection: close`, the
  connection is idle for the `idleTimeout` (60 seconds), or the server stops. Idle connections count towards
  `maxConnections` and, with threads per connection, occupy a thread each: a server that many browsers use can set a
  shorter `idleTimeout` (the one-thread mode does not have this cost). Tests and tools that relied on the server
  closing the connection have to send `Connection: close`.
- **The server says what it does with the connection**: `Connection: close` in the response before it closes, and
  `Connection: keep-alive` for a client that asked for that. Every response has a `Date` header, and `204` and `304`
  responses have no `Content-Length`.
- **Bodies that a function writes are sent in chunks** (`Transfer-Encoding: chunked`) to HTTP/1.1 clients, and the
  connection goes on; they used to end with the connection. A handler that knows the length sets `Content-Length` and
  gets a body without chunks (it has to write exactly that many bytes, or the connection is closed). HTTP/1.0 clients
  still get a body that ends with the connection.
- **`HEAD`** is answered by the handler of the `GET` route, without a body (it used to be `404`, or the body was sent
  for a handler that is registered for all methods). **A path that has routes, but not for the method of the request,
  is `405`** with an `Allow` header (it was `404`), and **`OPTIONS` is answered by the server** (`204` and `Allow`)
  unless there is a handler: `server.options[...]`. A custom `NanoHTTPRouter` can offer `allowedMethods(path:)`, which a
  router that does not leaves as it is (always `404`).
- **Requests**: bodies in chunks are decoded (the handler sees the body, `Content-Length` of its size and no
  `Transfer-Encoding`), `Expect: 100-continue` is answered, and requests that cannot be handled safely are refused: a
  `Content-Length` together with chunks (`400`), another `Transfer-Encoding` (`501`), a version that is not HTTP/1.0 or
  HTTP/1.1 (`505`), another expectation (`417`). `request.httpVersion` is new, and `supportsKeepAlive` follows the
  version of the protocol.
- **Files** (`share`, `browse`) are sent with `ETag`, `Last-Modified` and `Accept-Ranges`, answer conditional requests
  with `304` and ranges with `206` and `416`, and keep the connection. A directory is redirected to the address with a
  slash and serves its index file (it was an empty `200`, or only for the root), and the listing of `browse` no longer has
  the entries `.` and `..`.
- `NanoHTTPResponseBodyWriter` has a new function, `write(_:offset:length:)`, with an implementation for all writers, so
  that existing ones need no change; `NanoSocket.writeFile(_:offset:length:)` sends a part of a file exactly.

Under the hood, sockets read in blocks of 16 KB (a `NanoSocket` reads from a buffer: code that waits for the descriptor
of a socket itself has to look at `NanoSocket.hasBufferedData` first, which `NanoSocket` subclasses of the framework
and the sessions of `NanoSocketSession` need not do), and `TCP_NODELAY` is set on accepted connections.

