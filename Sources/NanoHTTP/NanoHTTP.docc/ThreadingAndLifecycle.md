# Threading and Lifecycle

Start and stop servers, and know which code runs on which thread.

## Overview

### Starting and stopping

```swift
let server = NanoHTTPServer()
server.get["/ping"] = { _ in .ok(.text("pong")) }
try server.start(0, forceIPv4: true)         // port 0: any free port
let port = try server.port()
print("listening at port \(port), state: \(server.state)")      // .running
server.stop()                                                   // .stopped
try server.start(UInt16(port), forceIPv4: true)                 // a stopped server can be started again
server.stop()
```

- ``NanoHTTPServerIO/start(_:forceIPv4:priority:handlerPriority:)`` throws if the socket cannot be set up: the port
  is in use, or the listen address is not an address (``NanoHTTPServerIO/listenAddressIPv4``). The server is
  stopped then. Starting a server that is not stopped does nothing.
- ``NanoHTTPServerIO/stop()`` closes the listening socket and all open connections, and returns when that is
  done. Connections that are in the middle of a response fail to write it. Stopping a server that is not running
  does nothing.
- Both can be called from any thread, also at the same time: exactly one call does the work.
- ``NanoHTTPServerIO/state`` is `starting`, `running`, `stopping` or `stopped`; ``NanoHTTPServerIO/operating`` is
  true while it is running; ``NanoHTTPServerIO/openConnections`` counts the open connections.
- With `priority: nil` the server accepts connections on the thread that called `start`, which then does not
  return until the server stops.

### Which thread runs what

- The **accept loop** runs on one background thread, by default with the quality of service `.background`. In an
  app that needs prompt answers under load, pass a higher `priority`.
- Every accepted connection is served by a thread of the global dispatch queues (quality of service
  `handlerPriority`, `.userInitiated` by default). The thread reads a request, calls the middleware and the handler,
  writes the response, and reads the next request. It is blocked in the read while the connection waits.
- Connections are therefore served **concurrently**, and the requests of one connection one after another.
  Handlers, middleware and the closures of WebSocket sessions run on these threads: anything they share has to be
  protected.

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

### Idle connections occupy threads

A connection that does not send anything keeps its thread blocked, and the server has no timeouts. The pool of
threads that the system provides is limited: **somewhere around 64 idle connections, the server stops answering
other requests** until some of them close. This is fine for a server that is used by a few known clients (an app on
a phone and a laptop) and not for one that strangers can reach. See <doc:SecurityAndLimits>.

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
