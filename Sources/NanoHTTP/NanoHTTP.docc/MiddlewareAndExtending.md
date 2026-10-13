# Middleware and Extending the Server

Look at every request before it is routed, and replace parts of the server by subclassing.

## Overview

### Middleware

``NanoHTTPServer/middleware`` is an array of functions that see every request before it is routed. A function
that returns a response answers the request: the router and the handlers are not consulted. A function that
returns `nil` lets the request pass to the next one, and finally to the router.

```swift
let server = NanoHTTPServer()
server.middleware.append { request in
  // Only requests with the right key get any further.
  request.header("x-api-key") == "secret" ? nil : .unauthorized(.text("An API key is required"))
}
server.middleware.append { request in
  print("\(request.method) \(request.path) from \(request.address ?? "?")")   // logging
  return nil
}
```

Middleware runs on the threads of the connections, so it has to be thread-safe, and the array should be set up
before the server starts. Middleware cannot change a response afterwards: it sees requests, not responses. To add
a header to *all* responses, wrap the handlers you register or subclass the server (below).

Information can be passed from middleware to handlers in ``NanoHTTPRequest/custom``.

### Subclassing

The server is built to be subclassed. These methods are `open`:

| Method | Called | Use it to |
|---|---|---|
| ``NanoHTTPServerIO/dispatch(request:)`` | for every request | change how handlers are found (``NanoHTTPServer`` overrides it to run the middleware and the router) |
| ``NanoHTTPServerIO/handle(connection:)`` | once per connection | wrap the handling of a connection, for example to measure its duration |
| ``NanoHTTPServerIO/log(_:)`` | when the server reports something | send messages to your logger instead of the console |
| ``NanoHTTPServerIO/listen(priority:)`` | when the server starts accepting | do something when the server is up (call `super`) |
| ``NanoHTTPServerIO/stop()`` | when the server stops | do something when it stops (call `super`) |
| ``NanoHTTPServer/initialRouter()`` | when a server is created | use another ``NanoHTTPRouter`` |

```swift
// file scope
final class ExampleLoggingServer: NanoHTTPServer {
  override func log(_ str: String) {
    print("[nanohttp] \(str)")
  }

  override func handle(connection: NanoHTTPConnection) {
    let start = Date()
    let client = connection.request.address ?? "unknown"
    super.handle(connection: connection)
    log("connection from \(client) lasted \(Date().timeIntervalSince(start)) s")
  }
}
```

`handle(connection:)` returns when the connection has ended, which can be long after the first request if the client keeps
the connection open.

### A server without routing

``NanoHTTPServerIO`` can also be used on its own: it provides the sockets, threads and limits, and a subclass decides
how every request is answered.

```swift
// file scope
final class ExampleHelloServer: NanoHTTPServerIO {
  override func dispatch(request: NanoHTTPRequest) -> ([String: String], NanoHTTPRequestHandler) {
    return ([:], { _ in .ok(.text("You asked for \(request.path)")) })
  }
}
```

### A delegate

A ``NanoHTTPServerDelegate`` set as ``NanoHTTPServerIO/delegate`` is told when a connection has received its
first request, and again when it is switched to WebSocket, on the thread of the connection.

### Another router

A router maps a method and a path to a handler and the variables of the route: the protocol ``NanoHTTPRouter`` has
four functions. The default ``NanoHTTPSegmentRouter`` is a good fit for path-based routes; implement the protocol
for something else, for instance to match on patterns of another form. Routers have to be thread-safe.

## Topics

- ``NanoHTTPServerIO``
- ``NanoHTTPServerDelegate``
- ``NanoHTTPConnection``
- ``NanoHTTPRouter``
