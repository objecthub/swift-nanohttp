# Swift NanoHTTP

[![Platforms: macOS, iOS, tvOS](https://img.shields.io/badge/Platforms-macOS,%20iOS,%20tvOS-blue.svg?style=flat)](https://developer.apple.com/osx/) [![Language: Swift 5.9](https://img.shields.io/badge/Language-Swift%205.9-green.svg?style=flat)](https://developer.apple.com/swift/) [![IDE: Xcode 15](https://img.shields.io/badge/IDE-Xcode%2015-orange.svg?style=flat)](https://developer.apple.com/xcode/) [![Package managers: SwiftPM](https://img.shields.io/badge/Package%20managers-SwiftPM-8E64B0.svg?style=flat)](https://swift.org/package-manager/) [![License: BSD 3-Clause](https://img.shields.io/badge/License-BSD%203--Clause-lightgrey.svg?style=flat)](LICENSE)

> **This is the maintenance branch of version 1.** Version 2.0 is the current version (see the
> [`main` branch](https://github.com/objecthub/swift-nanohttp) and its
> [migration guide](https://github.com/objecthub/swift-nanohttp/blob/main/MIGRATION-2.0.md)). Version 1.0 receives
> fixes for security problems and crashes until the end of 2027; see [SECURITY.md](SECURITY.md).

NanoHTTP is a small, extensible HTTP/1.1 server framework for macOS, iOS and tvOS. It runs a web server inside your
own process, with routing, forms, uploads, file serving and WebSockets, and no dependencies. It is based on
[Swifter](https://github.com/httpswift/swifter) by Damian Kołakowski.

It is made for servers that are used by you, your own devices or a small trusted group: tools, local user
interfaces, companion apps, test servers. It does not provide TLS or authentication, and it is not built to withstand
many hostile clients; see [Security](#security).

## A first server

```swift
import Foundation
import NanoHTTP

let server = NanoHTTPServer()

server.get["/hello/:name"] = { request in
  .ok(.text("Hello, \(request.params["name"] ?? "stranger")!"))
}

server.post["/echo"] = { request in
  .ok(.data(Data(request.body), contentType: request.header("content-type")))
}

server.get["/time"] = { _ in
  .ok(.json(["now": ISO8601DateFormatter().string(from: Date())]))
}

try server.start(8080)
print("Serving at http://localhost:\(try server.port())")
RunLoop.main.run()
```

```bash
curl http://localhost:8080/hello/Ada
```

A handler is a function from a request to a response. Paths can have variables (`/users/:id`), routes can be
grouped and mounted below a prefix, and `server["/path"]` answers every method.

## What it can do

- **Routing** with `:variables`, wildcards and path variables, per-method registration, sub-routers.
- **Requests**: headers, query, route variables, URL-encoded forms, multipart uploads, bodies of up to 64 MiB
  (configurable).
- **Responses**: text, HTML, JSON, bytes, redirects, streamed bodies, any status code.
- **Files**: `share(file:)`, `share(directory:)` and `browse(directory:)`, which do not serve anything from outside
  the directory.
- **WebSockets** (RFC 6455): fragmented messages, ping/pong, close codes, thread-safe sending, size limits.
- **A small HTML builder** for status and admin pages.
- **Middleware** and subclassing for everything else: how requests are dispatched, how connections are handled,
  logging.
- **Limits** for lines, headers and bodies, and answers (`400`, `413`, `414`, `431`) for requests that exceed
  them.

A thread serves each connection, so handlers of different connections run at the same time. There are no timeouts,
and about 64 connections that stay idle stop the server from answering others.

## Serving files

```swift
let server = NanoHTTPServer()
let directory = NSHomeDirectory() + "/Public"
server["/files/::path"] = share(directory: directory)       // GET /files/photos/cat.jpg
server["/browse/::path"] = browse(directory: directory)     // a listing of the directory
```

Requests with `..`, NUL characters or symbolic links that lead out of the directory are refused with `403`.

## WebSockets

```swift
let server = NanoHTTPServer()
server["/chat"] = websocket(
  text: { session, message in session.writeText("You said: \(message)") },
  connected: { session in session.writeText("Welcome!") })
```

Sessions can be written from any thread, which makes broadcasting to many clients simple.

## Security

NanoHTTP listens on **all network interfaces** unless you tell it otherwise. For a server that is for this machine
only:

```swift
let server = NanoHTTPServer()
server.listenAddressIPv4 = "127.0.0.1"
try server.start(8080, forceIPv4: true)
```

Even then, web pages in the user's browser can send requests to it: check the `Host` and `Origin` headers in a
middleware if that matters. There is no TLS, no authentication, no rate limiting and no timeouts: do not expose a
server to the internet without a reverse proxy that provides them. The documentation article *Security and Limits*
lists what to decide, with code. To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Installation

Add the package to your `Package.swift`:

```text
.package(url: "https://github.com/objecthub/swift-nanohttp.git", from: "1.0.3"),
```

and the product `NanoHTTP` to the dependencies of your target. In Xcode, use File > Add Package Dependencies.

## Documentation

The API is documented with DocC: a catalog with articles (getting started, routing, requests and responses, files,
WebSockets, middleware, threading, security, testing, iOS) and documentation comments for every public symbol.
Build it in Xcode with Product > Build Documentation, or from the command line, keeping the archive to open in
Xcode:

```bash
python3 Scripts/check_docs.py --output NanoHTTP.doccarchive
```

The examples in the documentation are compiled against the library by `Scripts/check_doc_examples.py`, so they
stay correct. The [CHANGELOG](CHANGELOG.md) lists what changed in every version.

## Demo servers

The framework comes with a [demo server](Sources/NanoHTTPDemo/NanoHTTPDemo.swift), which runs as a
[command-line tool on macOS](Sources/DemoServer/main.swift) (`swift run DemoServer`) and as a
[SwiftUI app on iOS](Sources/DemoServer%20iOS/ContentView.swift). It shows many features, and serves your
**Downloads folder** read-only on port 9080, to every device that can reach your machine. Run it on networks you
trust, or change the directory.

## Requirements

- macOS 12, iOS 15 or tvOS 15, or later
- [Xcode 15](https://developer.apple.com/xcode/) and [Swift 5.9](https://developer.apple.com/swift/) or later
- [Swift Package Manager](https://swift.org/package-manager/)

## Development

```bash
swift test                                        # the tests (see Tests/README.md)
swift test --sanitize=thread                      # also with --sanitize=address
python3 Scripts/check_xcodeproj.py                # the Xcode project lists every Swift file and matches Package.swift
python3 Scripts/check_doc_examples.py             # the examples of the documentation compile
python3 Scripts/check_docs.py                     # the DocC documentation builds without warnings
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to contribute.

## License

NanoHTTP is available under the BSD 3-Clause license, see [LICENSE](LICENSE).

## Copyright

Author: Matthias Zenger (<matthias@objecthub.com>)  
Copyright © 2024-2026 Matthias Zenger. All rights reserved.
