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

