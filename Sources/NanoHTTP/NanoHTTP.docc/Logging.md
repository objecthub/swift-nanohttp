# Logging

See what the server reports, and send it where you want it.

## Overview

A server reports what nobody else can see: a handler that threw an error (with the method and path of the request), a
response that could not be written, a pause in accepting connections, the connection limit, a response header that had to
be dropped, a WebSocket client that broke the protocol. The messages go to the ``NanoHTTPLogger`` of the server's
configuration, with a level: ``NanoLogLevel/debug``, ``NanoLogLevel/info``, ``NanoLogLevel/warning`` or ``NanoLogLevel/error``.

| Level | The server uses it for |
|---|---|
| `error` | a handler that threw an error other than ``NanoHTTPError``; a response that could not be built, or whose body does not have the length that its `Content-Length` says |
| `warning` | a shortage that the server works around (out of file descriptors, the connection limit), a response header that was dropped |
| `info` | clients that went away or broke a protocol (a response that could not be written, a WebSocket frame that is not valid), a recovery |
| `debug` | nothing: it is for your own messages |

### The loggers that come with the framework

The default is a ``NanoOSLogger``, which writes to the unified logging system of Apple's platforms: the messages appear in
the console of Xcode and in the Console app, with the subsystem `org.objecthub.NanoHTTP`. A **command-line tool** does not
see them in its terminal; it uses a ``NanoConsoleLogger``, which prints a line for every message. A ``NanoSilentLogger``
discards everything.

```swift
let server = NanoHTTPServer()
server.configuration.logger = NanoConsoleLogger(minimumLevel: .info)   // [WARNING] Unable to accept a connection ...
try server.start(8080)
```

Set the logger before the server starts: a running server keeps the configuration it was started with.

### Your own messages

``NanoHTTPServerIO/log(_:_:)`` logs with the logger of the server, from handlers and everywhere else, from any thread:

```swift
let server = NanoHTTPServer()
server.get["/order"] = { request in
  server.log(.info, "order from \(request.address ?? "unknown")")
  return .ok(.text("thanks"))
}
```

The message is an autoclosure: a logger that does not want the level does not build the text, so a `.debug` message that is
expensive to build costs nothing in a server that logs from `.info` on.

### Your own logger

A logger is a type with one method. This one collects the lines for a window of an app (the iOS demo does the same):

```swift
// file scope
/// Collects what the server reports.
final class ExampleOutputLogger: NanoHTTPLogger {
  private let lock = NSLock()
  private var lines = [String]()

  func log(_ level: NanoLogLevel, _ message: @autoclosure () -> String) {
    guard level >= .info else {
      return
    }
    let line = "\(level): \(message())"
    lock.lock()
    lines.append(line)
    lock.unlock()
  }
}
```

A logger is called from the threads of the connections, also at the same time, so it must be safe for that. On a server
that runs on one thread (``NanoHTTPServerIO/Configuration/Threading/singleThread``) it is called on that thread, and a logger
that blocks (a slow disk, a network call) blocks the server: hand the line to another queue.

### Coming from 1.x

`NanoHTTPServerIO.log(_:)` was `open` and printed to the console; subclasses overrode it to send the messages elsewhere. It is
`public` now (it logs at the level `info`), and the place to send messages elsewhere is the configuration's logger. Code that
overrides `log(_:)` no longer compiles, which is intended: the override would not see the messages of the server any more.

## Topics

### Loggers

- ``NanoHTTPLogger``
- ``NanoLogLevel``
- ``NanoOSLogger``
- ``NanoConsoleLogger``
- ``NanoSilentLogger``
