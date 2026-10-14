# Getting Started

Add NanoHTTP to a project, answer your first request and learn where to go next.

## Overview

NanoHTTP is a Swift package without dependencies. It runs a web server inside your own process: a
command-line tool, a Mac app, an iOS app. It supports macOS 12, iOS 15 and tvOS 15 and later.

### Add the package

Add the package to the dependencies of your `Package.swift`, and the product `NanoHTTP` to your target:

```text
.package(url: "https://github.com/objecthub/swift-nanohttp.git", from: "2.1.0"),
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

``NanoHTTPServerIO/start(_:)`` returns at once: the server accepts connections on threads of its own. A command-line tool has to keep the process alive, as the example does with
the run loop; an app has a run loop anyway. Passing the port `0` lets the system choose a free port, which
``NanoHTTPServerIO/port()`` reports.

Try it from a terminal:

```bash
curl http://localhost:8080/hello/Ada
```

Stop the server with ``NanoHTTPServerIO/stop()``. A stopped server can be started again.

### Who can connect

Without further settings the server accepts connections from **this machine only** (`127.0.0.1`). A server that
other devices are meant to reach has to say so:

```swift
let server = NanoHTTPServer()
server.configuration.listenAddress = .allInterfaces
try server.start(8080)
```

With `.address("192.168.1.20")` the server listens at one address; one that is not an address of this machine makes
`start` throw instead of listening everywhere. See
<doc:SecurityAndLimits> for what else to consider before you expose a server.

### Next steps

- <doc:Routing> explains how paths are matched and how variables work.
- <doc:HandlersAndResponses> and <doc:ReadingRequests> cover what handlers receive and return.
- <doc:ServingFiles> and <doc:WebSockets> cover files and live connections.
- <doc:Examples> are six complete programs that you can run and change: a JSON API, a file server, a chat, and more.
- <doc:HowARequestIsServed> describes what happens between a client's request and your handler.
