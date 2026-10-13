# Getting Started

Add NanoHTTP to a project, answer your first request and learn where to go next.

## Overview

NanoHTTP is a Swift package without dependencies. It runs a web server inside your own process: a
command-line tool, a Mac app, an iOS app. It supports macOS 12, iOS 15 and tvOS 15 and later.

### Add the package

Add the package to the dependencies of your `Package.swift`, and the product `NanoHTTP` to your target:

```text
.package(url: "https://github.com/objecthub/swift-nanohttp.git", from: "1.0.2"),
...
.product(name: "NanoHTTP", package: "swift-nanohttp"),
```

In Xcode, choose File > Add Package Dependencies and enter the URL of the repository.

### Your first server

A server maps methods and paths to *handlers*, functions that take a ``NanoHTTPRequest`` and
return a ``NanoHTTPResponse``:

```swift
import Foundation
import NanoHTTP

let server = NanoHTTPServer()
server.get["/hello"] = { _ in .ok(.text("Hello, world!")) }
server.get["/hello/:name"] = { request in
  .ok(.text("Hello, \(request.params["name"] ?? "stranger")!"))
}
try server.start(8080)
print("Serving at http://localhost:\(try server.port())")
RunLoop.main.run()
```

``NanoHTTPServerIO/start(_:forceIPv4:priority:handlerPriority:)`` returns at once: the server accepts
connections on background threads. A command-line tool has to keep the process alive, as the example does with
the run loop; an app has a run loop anyway. Passing the port `0` lets the system choose a free port, which
``NanoHTTPServerIO/port()`` reports.

Try it from a terminal:

```bash
curl http://localhost:8080/hello/Ada
```

Stop the server with ``NanoHTTPServerIO/stop()``. A stopped server can be started again.

### Who can connect

Without further settings the server accepts connections on **all network interfaces**: from this
machine and from every machine that can reach it. To accept connections from this machine only, give the
address to listen at:

```swift
let server = NanoHTTPServer()
server.listenAddressIPv4 = "127.0.0.1"
try server.start(8080, forceIPv4: true)
```

An address that is not an address makes `start` throw instead of listening everywhere. See
<doc:SecurityAndLimits> for what else to consider before you expose a server.

### Next steps

- <doc:Routing> explains how paths are matched and how variables work.
- <doc:HandlersAndResponses> and <doc:ReadingRequests> cover what handlers receive and return.
- <doc:ServingFiles> and <doc:WebSockets> cover files and live connections.
- <doc:HowARequestIsServed> describes what happens between a client's request and your handler.
