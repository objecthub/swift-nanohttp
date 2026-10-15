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
(``NanoHTTPRequest/params``, and ``NanoHTTPRequest/rawParams`` with the values as the client sent them) are known only
after `next` has returned.

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

``NanoMiddleware`` has the ones that servers for web pages need: ``NanoMiddleware/cors(_:)`` (cross-origin resource sharing,
with a ``NanoCORSPolicy``), ``NanoMiddleware/hostAllowlist(_:)`` and ``NanoMiddleware/originAllowlist(_:)``; see
<doc:SecurityAndLimits>.

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
the connection open. (An override that answers from other threads, as in the next section, returns after every request.)

### Answering from another thread

A server that hands its requests to other threads (a pool of workers, a job queue, another language runtime) does not
have to hold a thread of its own for every request that is being worked on. An override of `handle(connection:)` that
does not call `super` calls ``NanoHTTPConnection/deferResponse()``, passes the returned ``NanoHTTPDeferredResponse`` on,
and returns; whoever has the answer calls ``NanoHTTPDeferredResponse/send(_:dontKeepAlive:)`` from any thread:

```swift
// file scope
final class ExampleWorkerServer: NanoHTTPServer {
  let workers = DispatchQueue(label: "workers", attributes: .concurrent)

  override func handle(connection: NanoHTTPConnection) {
    let pending = connection.deferResponse()
    let response = connection.response()        // runs the middleware and the route, here or in the worker
    self.workers.async {
      pending.send(response)
    }
  }
}
```

`send` returns at once: the server writes the response itself, on a thread of its own, and waits for the next request of
the connection there, so a worker never waits for a client that is slow to read or to send. A connection that waits for its
answer is not read and does not time out (but it counts as an open connection, and a request that the client has already
sent behind the first one is handled after the first has been answered). It works the same with threads per connection
and with one thread, where the loop of the server writes the answers: that thread is still the only one that touches the
sockets. If the token is released without an answer, the connection is closed and a warning is logged.

#### A worker pool behind one network thread

The two ideas fit together: a server with ``NanoHTTPServerIO/Configuration/Threading/singleThread`` needs no thread for
a connection that waits, so any number of browsers and idle keep-alive connections cost nothing, and a pool of workers
runs the handlers, which may take long or block. The one thread accepts connections, reads requests and writes responses;
it puts every request into a bounded queue, and the workers take the requests from there. This is a complete server of
that kind, with a queue that refuses requests (`503`) when it is full:

```swift
// file scope
/// Serves the network with one thread, and runs the middleware and the handlers on a pool of worker threads.
/// The handlers run at the same time, so they must protect the state that they share.
final class ExampleWorkerPoolServer: NanoHTTPServer {
  private struct Job {
    let connection: NanoHTTPConnection
    let pending: NanoHTTPDeferredResponse
  }

  private let workerCount: Int
  private let capacity: Int
  private let condition = NSCondition()
  private var queue = [Job]()                 // guarded by `condition`, like `run`
  private var run = 0                         // the number of the current run of the server; 0 if none
  private var runs = 0

  init(workers: Int = 3, capacity: Int = 100) {
    self.workerCount = workers
    self.capacity = capacity
    var configuration = Configuration()
    configuration.threading = .singleThread
    super.init(configuration: configuration)
  }

  /// Runs on the one thread of the server (the calling thread of `run`), and returns when the server stops.
  override func listen() {
    self.condition.lock()
    self.runs += 1
    let run = self.runs
    self.run = run
    self.condition.unlock()
    for index in 0..<self.workerCount {
      let worker = Thread { [self] in self.work(run) }
      worker.name = "Example worker \(index)"
      worker.start()
    }
    super.listen()
    // The server has stopped: the workers of this run end, and the requests that nobody has taken are given up. (A
    // server that is started again right away has begun its next run already, and the queue is that run's.)
    var abandoned = [Job]()
    self.condition.lock()
    if self.run == run {
      self.run = 0
      abandoned = self.queue
      self.queue.removeAll()
    }
    self.condition.broadcast()
    self.condition.unlock()
    for job in abandoned {
      job.pending.close()
    }
  }

  /// Called on the one thread for every request that arrives, also for the next request of a kept-alive connection.
  override func handle(connection: NanoHTTPConnection) {
    self.condition.lock()
    let accepted = self.queue.count < self.capacity
    if accepted {
      self.queue.append(Job(connection: connection, pending: connection.deferResponse()))
      self.condition.signal()
    }
    self.condition.unlock()
    if !accepted {
      // Too many requests are waiting: refuse this one at once, and close its connection.
      let busy = NanoHTTPResponse(statusCode: 503, headers: ["Retry-After": "1"], body: .text("busy"))
      _ = connection.send(busy, dontKeepAlive: true)
    }
  }

  private func work(_ run: Int) {
    while let job = self.nextJob(run) {
      // Runs the middleware and the route, and turns errors into responses as usual. `send` returns at once:
      // the one thread of the server writes the response.
      job.pending.send(job.connection.response())
    }
  }

  private func nextJob(_ run: Int) -> Job? {
    self.condition.lock()
    defer {
      self.condition.unlock()
    }
    while self.queue.isEmpty && self.run == run {
      self.condition.wait()
    }
    return self.run == run ? self.queue.removeFirst() : nil
  }
}
```

```swift
let server = ExampleWorkerPoolServer(workers: 4, capacity: 50)
server.get["/hello/:name"] = { request in
  Thread.sleep(forTimeInterval: 1)            // holds a worker for a second; the network thread stays free
  return .ok(.text("Hello \(request.params["name"] ?? "world")!"))
}
try server.run(8080)                           // returns when another thread has called `server.stop()`
```

Four requests that arrive together are answered after a second, not after four; a fifth that finds the queue full gets
`503` with `Retry-After`; a client that keeps its connection open sends its next request on the same connection, which
comes to `handle(connection:)` again and goes through the queue like the first. With threads per connection instead
(leave out the configuration), the same server works the same way, but every connection that waits for its next
request holds a thread.

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
``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:origins:protocols:hub:)`` works, and the same is available for protocols of
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

### Another router

A router maps a method and a path to a handler and the variables of the route: the protocol ``NanoHTTPRouter`` has
four functions. The default ``NanoHTTPSegmentRouter`` is a good fit for path-based routes; implement the protocol
for something else, for instance to match on patterns of another form. Routers have to be thread-safe.

Two more functions have default implementations: ``NanoHTTPRouter/allowedMethods(path:)`` (without it, a request
that no route matches is always answered with `404`) and ``NanoHTTPRouter/routeWithRawParams(_:path:)``, which the
server calls to route a request. It returns what `route` returns, and the values of the variables as the client sent
them, which the server sets as ``NanoHTTPRequest/rawParams``. The default implementation calls `route` and has no
raw values: a router that does not implement it leaves ``NanoHTTPRequest/rawParams`` empty. A router that decodes
the values should take the raw ones from the same segments, at the same time (deriving them afterwards goes wrong
where the search backtracks). A subclass of ``NanoHTTPSegmentRouter`` that changes `route` has to override
`routeWithRawParams` instead (`route` calls it), or the server does not see the change.

## Topics

- ``NanoHTTPMiddleware``
- ``NanoSocketSession``
- ``NanoHTTPServerIO``
- ``NanoHTTPConnection``
- ``NanoHTTPRouter``
