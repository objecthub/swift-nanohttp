# Middleware and Extending the Server

Look at every request before it is routed, and replace parts of the server by subclassing.

## Overview

### Middleware

``NanoHTTPServer/middleware`` is an array of functions that wrap the handling of every request. Each receives the
request and `next`, which stands for the rest of the chain: the middleware after it, and finally the router and the
handler. Calling `next(request)` lets the request through and returns the response, so a middleware can do something
before and after the handler:

```swift
let server = NanoHTTPServer()
server.middleware.append { request, next in
  // Only requests with the right key get any further.
  guard request.header("x-api-key") == "secret" else {
    throw NanoHTTPError.unauthorized("An API key is required")
  }
  return try next(request)
}
server.middleware.append { request, next in
  let start = Date()
  var response = try next(request)                     // the rest of the chain
  response.headers["X-Served-By"] = "nano"              // change the response
  print("\(request.method) \(request.path) -> \(response.statusCode) in \(Date().timeIntervalSince(start)) s")
  return response
}
```

The first middleware of the array is the outermost: it sees the request first and the response last. A middleware can

- answer the request itself and not call `next`, or throw a ``NanoHTTPError``,
- change the request before it calls `next`: pass information to the handlers in ``NanoHTTPRequest/custom`` (the
  user that a token belongs to), or rewrite ``NanoHTTPRequest/path``, because the request is routed after the middleware
  has run,
- change the response that `next` returns, and
- catch the errors that the handler or later middleware throw.

Middleware sees every request, also the ones that no route matches (and which get their `404` from the
``NanoHTTPServer/notFoundHandler`` or the server). Because it runs before routing, the variables of the route
(``NanoHTTPRequest/params``) are known only after `next` has returned.

An error that is not caught is answered as for a handler (see <doc:HandlersAndResponses#Errors>). To turn the
errors into a JSON response in one place, catch them in a middleware, or set ``NanoHTTPServer/errorHandler``:

```swift
let server = NanoHTTPServer()
server.middleware.insert({ request, next in
  do {
    return try next(request)
  } catch let error as NanoHTTPError {
    return NanoHTTPResponse(statusCode: error.status, body: .json(["error": error.message ?? ""]))
  }
}, at: 0)
```

Middleware runs on the threads of the connections (on one thread if the server has only one), so it has to be
thread-safe, and the array should be set up before the server starts.

### Subclassing

The server is built to be subclassed. These methods are `open`:

| Method | Called | Use it to |
|---|---|---|
| ``NanoHTTPServerIO/dispatch(request:)`` | for every request | change how handlers are found (``NanoHTTPServer`` overrides it to run the middleware and the router) |
| ``NanoHTTPServerIO/handle(connection:)`` | once per connection | wrap the handling of a connection, for example to measure its duration |
| ``NanoHTTPServerIO/response(for:to:)`` | when a handler or middleware throws | decide how an error is answered (``NanoHTTPServer/errorHandler`` does this without subclassing) |
| ``NanoHTTPServerIO/listen()`` | when the server starts accepting | do something when the server is up (call `super`) |
| ``NanoHTTPServerIO/stop()`` | when the server stops | do something when it stops (call `super`) |
| ``NanoHTTPServer/initialRouter()`` | when a server is created | use another ``NanoHTTPRouter`` |

```swift
// file scope
final class ExampleTimingServer: NanoHTTPServer {
  override func handle(connection: NanoHTTPConnection) {
    let start = Date()
    let client = connection.request.address ?? "unknown"
    super.handle(connection: connection)
    log(.info, "connection from \(client) lasted \(Date().timeIntervalSince(start)) s")
  }
}
```

What the server reports does not go through a method that you override, but to a logger that you set: see <doc:Logging>.

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

### Other protocols

A response can turn a connection over to something that is not HTTP. ``NanoHTTPResponse/switchProtocols(_:session:)``
takes a ``NanoSocketSession``, which the server drives: it calls the session when the socket has something to
read, so that a server with one thread can serve many sessions and its other connections. That is how
``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:)`` works, and the same is available for protocols of
your own:

```swift
// file scope
/// Answers every line with the same line in upper case, until it receives "bye".
final class ExampleShoutingSession: NanoSocketSession {
  private var socket: NanoSocket?

  func start(socket: NanoSocket, drainTimeout: TimeInterval, logger: NanoHTTPLogger) {
    self.socket = socket
    try? socket.writeUTF8("HELLO\n")
  }

  func receive() -> Bool {
    guard let socket, let line = try? socket.readLine() else {
      return false                                  // the connection has ended
    }
    try? socket.writeUTF8(line.uppercased() + "\n")
    return line != "bye"
  }

  func end() {
    self.socket = nil
  }
}
```

```swift
let server = NanoHTTPServer()
server["/shout"] = { _ in
  .switchProtocols(["Upgrade": "shout", "Connection": "Upgrade"], session: ExampleShoutingSession())
}
```

``NanoHTTPResponse/switchProtocols(_:_:)`` with a function is the simpler variant, for a session that is written as a
function that owns the connection until it returns. It occupies the thread of its connection; on a server with one
thread, nothing else is served meanwhile.

### A delegate

A ``NanoHTTPServerDelegate`` set as ``NanoHTTPServerIO/delegate`` is told when a connection has received its
first request, and again when it is switched to WebSocket, on the thread of the connection.

### Another router

A router maps a method and a path to a handler and the variables of the route: the protocol ``NanoHTTPRouter`` has
four functions. The default ``NanoHTTPSegmentRouter`` is a good fit for path-based routes; implement the protocol
for something else, for instance to match on patterns of another form. Routers have to be thread-safe.

## Topics

- ``NanoHTTPMiddleware``
- ``NanoSocketSession``
- ``NanoHTTPServerIO``
- ``NanoHTTPServerDelegate``
- ``NanoHTTPConnection``
- ``NanoHTTPRouter``
