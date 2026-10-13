# Threading and Lifecycle

Start and stop servers, and know which code runs on which thread.

## Overview

### Starting and stopping

```swift
let server = NanoHTTPServer()
server.get["/ping"] = { _ in .ok(.text("pong")) }
try server.start(0)                         // port 0: any free port
let port = try server.port()
print("listening at port \(port), state: \(server.state)")      // .running
server.stop()                                                   // .stopped
try server.start(UInt16(port))                                 // a stopped server can be started again
server.stop()
```

- ``NanoHTTPServerIO/start(_:)`` returns as soon as the server listens, and throws if the socket cannot be set up:
  the port is in use, or the listen address is not an address of this machine
  (``NanoHTTPServerIO/Configuration/listenAddress``). The server is stopped then. Starting a server that is not
  stopped does nothing.
- ``NanoHTTPServerIO/stop()`` closes the listening socket and all open connections, and returns when that is
  done. Connections that are in the middle of a response fail to write it. Stopping a server that is not running
  does nothing.
- Both can be called from any thread, also at the same time: exactly one call does the work.
- ``NanoHTTPServerIO/state`` is `starting`, `running`, `stopping` or `stopped`; ``NanoHTTPServerIO/operating`` is
  true while it is running; ``NanoHTTPServerIO/openConnections`` counts the open connections.
- A server starts with its ``NanoHTTPServerIO/configuration``; changing it while the server runs takes effect the
  next time it is started.

### Which thread runs what

- The **accept loop** runs on one thread of its own (``NanoHTTPServerIO/Configuration/acceptQoS``,
  `.userInitiated` by default).
- Every accepted connection is served by a thread of its own (``NanoHTTPServerIO/Configuration/connectionQoS``,
  `.userInitiated` by default), not by a thread of the dispatch queues, which could not hold many blocked threads.
  The threads are reused: a thread that has finished its connection waits for the next one for a few seconds.
  The thread reads a request, calls the middleware and the handler, writes the response, and reads the next
  request. It is blocked in the read while the connection waits.
- Connections are therefore served **concurrently**, and the requests of one connection one after another.
  Handlers, middleware and the closures of WebSocket sessions run on these threads: anything they share has to be
  protected. (Or run the server on one thread, see below.)

```swift
// file scope
final class ExampleCounter {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}
```

```swift
let counter = ExampleCounter()
let server = NanoHTTPServer()
server.get["/visits"] = { _ in .ok(.text("visit \(counter.next())")) }
```

Routes can be registered while the server runs. ``NanoHTTPServer/middleware`` and
``NanoHTTPServer/notFoundHandler`` are plain properties: set them up before starting.

### Running everything on one thread

A server can do all its work on a single thread: accepting connections, reading requests, the middleware, the
handlers, writing responses. Requests are then served one at a time, and **handlers need no locks**:

```swift
let server = NanoHTTPServer()
server.configuration.threading = .singleThread
var visits = 0                          // shared by all handlers, and needs no lock
server.get["/visits"] = { _ in
  visits += 1
  return .ok(.text("visit \(visits)"))
}
try server.run(8080)                    // serves on this thread until the server is stopped
```

``NanoHTTPServerIO/run(_:)`` serves on the calling thread, which returns when the server is stopped (from a signal
handler or another thread). ``NanoHTTPServerIO/start(_:)`` returns at once and uses one thread of its own instead; the
handlers run on it, never on the thread that called `start`.

The thread waits for all connections together, so connections that wait for a request cost nothing and block no
one: a browser that opens a few connections it does not use, or keeps them alive, does not slow the server down.
What blocks the thread does block the server:

- A slow handler delays every other request.
- A request that stalls half way delays the others for up to the `readTimeout`, and a client that does not read its
  response for up to the `writeTimeout` (30 seconds each by default): lower them for a server like this.
- The messages of WebSockets are handled by the one thread as well, one at a time between other work: a closure that
  takes long delays everything, and a message that stalls half way delays the server up to the `readTimeout`. See
  <doc:WebSockets#On-a-server-with-one-thread>.

```swift
let server = NanoHTTPServer()
server.configuration.threading = .singleThread
server.configuration.readTimeout = 5
server.configuration.writeTimeout = 5
```

The threading mode is part of the ``NanoHTTPServerIO/configuration``, and changing it takes effect when the server
is started the next time. With threads per connection, `run` accepts connections on the calling thread and the
connections still have threads of their own.

### Idle connections, timeouts and the number of connections

Every connection occupies a thread and a file descriptor for as long as it is open, so the server limits both
what a connection may waste and how many there are (see ``NanoHTTPServerIO/Configuration``):

| Setting | Default | What happens |
|---|---|---|
| `idleTimeout` | 60 s | A connection that sends nothing, as its first request or between two requests (connections are persistent), is closed. |
| `readTimeout` | 30 s | A request that has begun but stalls for this long is answered with `408 Request Timeout`. |
| `writeTimeout` | 30 s | A connection whose peer takes no data for this long is closed. |
| `maxConnections` | 128 | A connection that arrives when that many are open is answered with `503 Service Unavailable`. |

`nil` turns a limit off. (On a server that runs on one thread the idle connections cost no thread, but they still count.) The timeouts are pauses, not total times: a large upload that keeps arriving is not cut
off, and a handler may take as long as it likes. WebSocket sessions are not subject to the idle and read timeouts,
but they count as connections.

```swift
let server = NanoHTTPServer()
server.configuration.idleTimeout = 10        // drop silent connections sooner
server.configuration.maxConnections = 32     // a small embedded server
```

### Accepting under pressure

If the process runs out of file descriptors, accepting is paused for a moment (and logged) instead of stopping the
server, and goes on when descriptors are free again. Connections that arrive during such a shortage can be lost.

### Reacting to termination

A command-line tool can stop the server when it is terminated. The callback runs inside the signal handler, so it should
do very little:

```swift
let server = NanoHTTPServer()
NanoProcess.watchSignals { _ in
  exit(0)
}
```

## Topics

- ``NanoHTTPServerIO``
- ``NanoHTTPServerIO/State``
- ``NanoProcess``
