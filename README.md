# Swift NanoHTTP

[![Platforms: macOS, iOS, tvOS](https://img.shields.io/badge/Platforms-macOS,%20iOS,%20tvOS-blue.svg?style=flat)](https://developer.apple.com/osx/) [![Language: Swift 5.9](https://img.shields.io/badge/Language-Swift%205.9-green.svg?style=flat)](https://developer.apple.com/swift/) [![IDE: Xcode 15](https://img.shields.io/badge/IDE-Xcode%2015-orange.svg?style=flat)](https://developer.apple.com/xcode/) [![Package managers: SwiftPM](https://img.shields.io/badge/Package%20managers-SwiftPM-8E64B0.svg?style=flat)](https://swift.org/package-manager/) [![License: BSD 3-Clause](https://img.shields.io/badge/License-BSD%203--Clause-lightgrey.svg?style=flat)](LICENSE)

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
- **Responses**: text, HTML, JSON, bytes, redirects, streamed bodies (in chunks, so that connections are reused), any
  status code.
- **HTTP/1.1 as clients expect it**: persistent connections, chunked request bodies, `Expect: 100-continue`, `HEAD`,
  `405` with `Allow`, `OPTIONS`, a `Date` header.
- **Files**: `NanoFiles.share(file:)`, `NanoFiles.share(directory:)` and `NanoFiles.browse(directory:)`, which do not serve anything from outside
  the directory, with `ETag`, `Last-Modified`, `304 Not Modified` and byte ranges (`206`).
- **WebSockets** (RFC 6455): fragmented messages, ping/pong, close codes, thread-safe sending, size limits.
- **NanoHTML**, a second library for small pages: elements are Swift values (`Html { Body { H1("Hi") } }`), text and attributes are
  escaped, and building pages needs no locks.
- **Errors**: a handler can `throw NanoHTTPError.notFound("No such item")`, which becomes the response; other
  errors become a `500` without details.
- **Middleware** that wraps requests (check, change, log, catch errors), and subclassing for everything else:
  how requests are dispatched and how connections are handled.
- **Logging** with levels: what the server reports goes to a logger (the unified log by default, the console or your own),
  not to `print`.
- **Limits** for lines, headers and bodies, timeouts for idle and stalled connections, a limit for the number of
  connections, and answers (`400`, `408`, `413`, `414`, `431`, `503`) for requests that exceed them.

By default a thread serves each connection, so handlers of different connections run at the same time. Or the
server runs on **one thread** (`server.configuration.threading = .singleThread`): requests and WebSocket messages
are handled one at a time and handlers need no locks.

## Serving files

```swift
let server = NanoHTTPServer()
let directory = NSHomeDirectory() + "/Public"
server["/files/::path"] = NanoFiles.share(directory: directory)       // GET /files/photos/cat.jpg
server["/browse/::path"] = NanoFiles.browse(directory: directory)     // a listing of the directory
```

Requests with `..`, NUL characters or symbolic links that lead out of the directory are refused with `403`.

## WebSockets

```swift
let server = NanoHTTPServer()
server["/chat"] = NanoWebSocket.handler(
  text: { session, message in session.writeText("You said: \(message)") },
  connected: { session in session.writeText("Welcome!") })
```

Sessions can be written from any thread, which makes broadcasting to many clients simple.

## Security

A server accepts connections from **this machine only** unless you tell it otherwise. A server that other devices are
meant to reach has to say so:

```swift
let server = NanoHTTPServer()
server.configuration.listenAddress = .allInterfaces
try server.start(8080)
```

Even a server that listens at the loopback address can be reached by web pages in the user's browser. Two checks, off by
default, close the usual ways in: `server.configuration.hostPolicy = .automatic` refuses requests for other host names
(DNS rebinding), and `originPolicy = .sameOrigin` refuses requests that change something, and WebSocket handshakes, from
pages of other sites. `NanoMiddleware.cors` lets the pages that you trust use the server. There is no TLS, no authentication and no rate limiting: do not
expose a server to the internet without a reverse proxy that provides them. The documentation article *Security and Limits*
lists what to decide, with code. To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Installation

Add the package to your `Package.swift`:

```text
.package(url: "https://github.com/objecthub/swift-nanohttp.git", from: "1.0.2"),
```

and the product `NanoHTTP` (and `NanoHTML`, if you build pages with it) to the dependencies of your target. In Xcode, use File > Add Package Dependencies.

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
[command-line tool on macOS](Sources/DemoServer/main.swift) and as a
[SwiftUI app on iOS](Sources/DemoServer%20iOS/ContentView.swift). It shows many features, and serves a folder on
port 9080: the **Downloads folder** in the command-line tool. The tool is reachable from this machine only; start it
with `--network` to let other devices connect, on networks you trust:

```bash
swift run DemoServer                 # http://localhost:9080
swift run DemoServer --network       # reachable from the network
swift run DemoServer --single-thread # everything on one thread
```

The iOS app listens on all network interfaces, because its purpose is to be reached from other devices.

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
