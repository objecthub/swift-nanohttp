# Migrating from 1.x to 2.0

Version 2.0 changes the API in many places, and a few defaults. Two kinds of change need your attention:

**What the compiler tells you.** Names that were renamed or moved are kept as unavailable declarations, so that the error
says what to use instead (Xcode offers a fix-it); things that were removed are listed below with their replacements. Build
your project first, and work through the errors with this guide at hand.

**What compiles, but behaves differently.** Check these, because nothing reports them:

- A server listens at the loopback address (`127.0.0.1`) only. A server that other devices reach needs
  `configuration.listenAddress = .allInterfaces` (*Server configuration*).
- Connections are persistent, and bodies that a function writes are sent in chunks. Clients and tests that relied on the server
  closing the connection after a response have to send `Connection: close` (*HTTP as clients expect it*).
- `request.path`, query values and route variables are decoded once. Code that decodes them again can be turned into path
  traversal (`%252e%252e`) (*Paths and query values are decoded*).
- `/users/:id` does not match `/users` any more (*Routing*).
- A request that does not arrive within the timeouts, and connections beyond the limit of 128, are answered with `408` and `503`
  (*Timeouts and the number of connections*).
- A handler that throws an error other than `NanoHTTPError` gets `500` without details.
- The messages of the server are not printed to the terminal any more: a command-line tool needs a `NanoConsoleLogger`
  (*Logging*).
- A write to a WebSocket session that fails ends the session, and writes to sessions time out after 5 seconds
  (*WebSockets*).

Every section says what to change.

## Server configuration

A server is configured with one object, `server.configuration` (`NanoHTTPServerIO.Configuration`), instead of
properties and parameters of `start`.

| 1.x | 2.0 |
|---|---|
| `server.listenAddressIPv4 = "127.0.0.1"` and `start(8080, forceIPv4: true)` | nothing: loopback is the default |
| no address (all network interfaces) | `server.configuration.listenAddress = .allInterfaces` |
| `server.listenAddressIPv4 = "192.168.1.20"` and `forceIPv4: true` | `server.configuration.listenAddress = .address("192.168.1.20")` |
| `server.listenAddressIPv6 = "::1"` | `server.configuration.listenAddress = .address("::1")` |
| `server.limits = NanoHTTPParser.Limits(...)` | `server.configuration.limits = NanoHTTPParser.Limits(...)` |
| `start(8080, priority: .userInitiated, handlerPriority: .utility)` | `configuration.acceptQoS = .userInitiated`, `configuration.connectionQoS = .utility`, `start(8080)` |
| `override func listen(priority:)` | `override func listen()` |
| `NanoSocket.tcpSocketForListen(port, true, 8, "127.0.0.1")` | `NanoSocket.tcpSocketForListen(port, .loopback, backlog: 8)` |

**Check who must reach the server.** A 1.x server without an address listened on all network interfaces. In 2.0 that
needs `.allInterfaces`; without it, devices on the network get "connection refused", and an iOS app that is meant to
be reached from another device stops working. A server that is only used by the same machine needs no change, and is
no longer exposed to the network by accident.

`forceIPv4` is gone: `.loopback` is an IPv4 socket (`127.0.0.1`), `.allInterfaces` is one socket for IPv4 and IPv6,
and `.address(_)` uses the family of the address. `.address("0.0.0.0")` listens on all IPv4 interfaces only.

`start` takes only the port, and returns after the server has started to listen.

**`priority: nil` is gone**, and with it the one-thread mode of 1.x. Use
`server.configuration.threading = .singleThread` instead (see below): `start(8080)` runs the whole server on one
thread of its own, and `run(8080)` on the calling thread, like `start(8080, priority: nil)` did. In 1.x, `priority: nil`
served the connections on the accepting thread (`handlerPriority: nil`) or accepted on the calling thread (`priority:
nil`); the new mode is better than both because connections that wait for a request no longer block the thread.
The one-thread mode does not use `connectionQoS`; `acceptQoS` is the priority of its thread.

```swift
let server = NanoHTTPServer()
server.configuration.threading = .singleThread
try server.run(8080)
```

## Timeouts and the number of connections

New defaults in `server.configuration`: `idleTimeout` 60 s, `readTimeout` 30 s, `writeTimeout` 30 s and
`maxConnections` 128. A client that is silent for a minute is disconnected, a request that stalls for 30 seconds gets
`408`, and the 129th simultaneous connection gets `503`. Raise or disable (`nil`) what does not fit, for example for
clients that keep many connections open for a long time:

```swift
let server = NanoHTTPServer()
server.configuration.idleTimeout = nil
server.configuration.maxConnections = 512
```

WebSocket sessions are not disconnected for being silent, but each one counts towards `maxConnections` and occupies a
thread.

## Handlers can throw

`NanoHTTPRequestHandler` is now `(NanoHTTPRequest) throws -> NanoHTTPResponse`. Handlers that you write as closures
need no change: a closure that cannot throw is accepted where a throwing one is expected. What changes is the code
that *calls* a handler, in tests for example, and the handlers that `htmlHandler`, `NanoFiles.share`, `NanoFiles.browse` and
`NanoWebSocket.handler` return:

```swift
let handler = htmlHandler { _ in P("hi") }
let request = NanoHTTPRequest(method: "GET", path: "/")
let response = try handler(request)                   // 1.x: handler(request)
```

A subclass of `NanoHTTPServerIO` that overrides `handle(connection:)` and calls `connection.handler(connection.request)`
by itself should call `connection.response()` instead, which also answers the errors that the handler throws.

Throwing is optional. Where a handler built an error response, it can throw an error:

```swift
let items = ["1": "pen"]
let server = NanoHTTPServer()
server.get["/items/:id"] = { request in
  guard let item = items[request.params["id"] ?? ""] else {
    throw NanoHTTPError.notFound("No such item")      // 1.x: return .notFound(.text("No such item"))
  }
  return .ok(.text(item))
}
```

`NanoHTTPError` has a status code, headers and a message (a plain text body), and a function for every usual
status (`.badRequest`, `.unauthorized(wwwAuthenticate:)`, `.forbidden`, `.notFound`, `.methodNotAllowed(allow:)`,
`.conflict`, `.payloadTooLarge`, `.unprocessableContent`, `.tooManyRequests(retryAfter:)`, ...). Every other error
that a handler throws is answered with `500 Internal Server Error` and no details; the details are logged.
`server.errorHandler` changes how errors are answered, for example as JSON.

## Sessions

`NanoHTTPResponse.Body` has a new case, `.session(NanoSocketSession)`; a `switch` over a body needs to handle it.
`websocket(...)` and `switchProtocols(_:_:)` work as before. A server that runs on one thread
(`threading = .singleThread`) serves WebSockets without blocking: see `NanoSocketSession` for protocols of your
own, and the article about WebSockets for a chat that needs no locks.

## Middleware wraps the request

The type of `server.middleware` changed from `(NanoHTTPRequest) -> NanoHTTPResponse?`, which could only answer a
request or let it pass, to `NanoHTTPMiddleware`, `(NanoHTTPRequest, next) throws -> NanoHTTPResponse`: it gets the
rest of the chain as `next`, so that it can change the response, catch errors, and measure how long the handler took.

| 1.x | 2.0 |
|---|---|
| `return nil` (let the request pass) | `return try next(request)` |
| `return .unauthorized(.text("denied"))` (answer) | the same, or `throw NanoHTTPError.unauthorized("denied")`; do not call `next` |
| `{ request in ... }` | `{ request, next in ... }` |

```swift nocompile
// 1.x
server.middleware.append { request in
  request.header("x-api-key") == "secret" ? nil : .unauthorized(.text("An API key is required"))
}
```

```swift
// 2.0
let server = NanoHTTPServer()
server.middleware.append { request, next in
  request.header("x-api-key") == "secret" ? try next(request) : .unauthorized(.text("An API key is required"))
}
```

What stays: the first middleware runs first, middleware sees every request before it is routed (and can rewrite
`request.path`), and the order of several checks is the same. What is new: middleware also sees the response, and it
sees the requests that no route matches together with their `404`. Variables of the route (`request.params`) are known
after `next` has returned.

## Paths and query values are decoded (H1)

In 1.x, `request.path` and the values of `request.queryParams` were still percent-encoded, a `+` in a query stayed a `+`,
the router decoded the values of `:variables` but not those of `::variables`, and the file handlers decoded the rest.
In 2.0 everything that you read from a request is decoded text, once:

| | 1.x | 2.0 |
|---|---|---|
| `request.path` for `/caf%C3%A9` | `"/caf%C3%A9"` | `"/café"` |
| `request.queryParams` for `?q=a%20b+c` | `("q", "a%20b+c")` | `("q", "a b c")` |
| `request.params` for `:name` | decoded | decoded |
| `request.params` for `::path` | **not** decoded | decoded |
| the path as sent | `request.path` | `request.rawPath` |
| the query as sent | (not available) | `request.rawQuery` |

New: `request.query("q")` (the first value of a parameter), `request.queries("tag")` (all values),
`request.bodyString` and `request.json(Type.self)`, which throws `NanoHTTPError.badRequest` with a message that says what is wrong
with the body. The router routes on `rawPath`; setting `request.path` (or `rawPath`) in middleware re-routes the request.

**Remove the decoding that you did yourself.** This is the one change that can open a hole if it is overlooked:

```swift nocompile
// 1.x
let name = request.queryParams.first { $0.0 == "name" }?.1.removingPercentEncoding   // decoded by you
let file = request.params["path"]?.removingPercentEncoding                           // decoded by you
// 2.0: both are decoded already; decoding again turns %252e%252e into %2e%2e, and a second time into ".."
let name = request.query("name")
let file = request.params["path"]
```

Code that checked a value for `..` and decoded it afterwards was already unsafe in 1.x; code that decodes a value of 2.0
again has the same flaw. Search your code for `removingPercentEncoding`, `replacingOccurrences(of: "+"` and
`addingPercentEncoding` next to `request.path`, `queryParams` and `params`, and delete the decoding of values
that you got from the framework. `share(directory:)` and `browse(directory:)` are changed already.

Two smaller things that come with it: the decoded path can contain line breaks and NUL characters (`%0A`, `%00`), so log
`request.rawPath` instead of `request.path`, and `NanoHTTPRequest(method:path:queryParams:)` takes decoded text now
(`path: "/a b"`, not `"/a%20b"`); use `NanoHTTPRequest(method:rawPath:rawQuery:)` for the encoded form.

Targets with bytes that are not ASCII (a client that sends `é` as UTF-8 without encoding it), the absolute form (`GET http://host/a`) and
`*` are handled by the parser now; `URLComponents` is no longer involved in reading a request.

## HTTP as clients expect it (H4, H7, H10)

The server does what HTTP/1.1 clients assume. Most of it is invisible; these are the changes that are not:

- **Connections are persistent.** After a response the server waits for the next request on the connection (it
  used to close it unless the request said `Connection: keep-alive`), until the client says `Connection: close`, the
  connection is idle for the `idleTimeout` (60 seconds), or the server stops. Idle connections count towards
  `maxConnections` and, with threads per connection, occupy a thread each: a server that many browsers use can set a
  shorter `idleTimeout` (the one-thread mode does not have this cost). Tests and tools that relied on the server
  closing the connection have to send `Connection: close`.
- **The server says what it does with the connection**: `Connection: close` in the response before it closes, and
  `Connection: keep-alive` for a client that asked for that. Every response has a `Date` header, and `204` and `304`
  responses have no `Content-Length`.
- **Bodies that a function writes are sent in chunks** (`Transfer-Encoding: chunked`) to HTTP/1.1 clients, and the
  connection goes on; they used to end with the connection. A handler that knows the length sets `Content-Length` and
  gets a body without chunks (it has to write exactly that many bytes, or the connection is closed). HTTP/1.0 clients
  still get a body that ends with the connection.
- **`HEAD`** is answered by the handler of the `GET` route, without a body (it used to be `404`, or the body was sent
  for a handler that is registered for all methods). **A path that has routes, but not for the method of the request,
  is `405`** with an `Allow` header (it was `404`), and **`OPTIONS` is answered by the server** (`204` and `Allow`)
  unless there is a handler: `server.options[...]`. A custom `NanoHTTPRouter` can offer `allowedMethods(path:)`, which a
  router that does not leaves as it is (always `404`).
- **Requests**: bodies in chunks are decoded (the handler sees the body, `Content-Length` of its size and no
  `Transfer-Encoding`), `Expect: 100-continue` is answered, and requests that cannot be handled safely are refused: a
  `Content-Length` together with chunks (`400`), another `Transfer-Encoding` (`501`), a version that is not HTTP/1.0 or
  HTTP/1.1 (`505`), another expectation (`417`). `request.httpVersion` is new, and `supportsKeepAlive` follows the
  version of the protocol.
- **Files** (`share`, `browse`) are sent with `ETag`, `Last-Modified` and `Accept-Ranges`, answer conditional requests
  with `304` and ranges with `206` and `416`, and keep the connection. A directory is redirected to the address with a
  slash and serves its index file (it was an empty `200`, or only for the root), and the listing of `browse` no longer has
  the entries `.` and `..`.
- `NanoHTTPResponseBodyWriter` has a new function, `write(_:offset:length:)`, with an implementation for all writers, so
  that existing ones need no change; `NanoSocket.writeFile(_:offset:length:)` sends a part of a file exactly.

Under the hood, sockets read in blocks of 16 KB (a `NanoSocket` reads from a buffer: code that waits for the descriptor
of a socket itself has to look at `NanoSocket.hasBufferedData` first, which `NanoSocket` subclasses of the framework
and the sessions of `NanoSocketSession` need not do), and `TCP_NODELAY` is set on accepted connections.

## Names and namespaces

A few public names were too general for a framework that is imported into every file of a server. They got the `Nano`
prefix or moved into a namespace. The old names still exist in 2.x, marked unavailable, so that the compiler says what
to use instead (Xcode offers to make the change); they are removed in the next major version.

| 1.x | 2.0 |
|---|---|
| `share(file:)`, `share(directory:defaults:followSymlinks:)` | `NanoFiles.share(file:)`, `NanoFiles.share(directory:defaults:followSymlinks:)` |
| `browse(directory:followSymlinks:)` | `NanoFiles.browse(directory:followSymlinks:)` |
| `websocket(text:binary:pong:connected:disconnected:maxMessageSize:)` | `NanoWebSocket.handler(text:binary:pong:connected:disconnected:maxMessageSize:)` |
| `WebSocketSession` | `NanoWebSocketSession` |
| `NetworkInterface` | `NanoNetworkInterface` |
| `String.File`, `String.FileError` | `NanoFile`, `NanoFileError` |
| `"a.png".mimeType()` | `NanoFiles.mimeType(forPath: "a.png")` |

`NanoFile` is opened with `try NanoFile(path: path)` (it was `try path.openForReading()`); the modes `.create` and
`.update` replace `openNewForWriting()` and `openForWritingAndReading()`.

The helpers that the framework inherited from Swifter are not public any more, and have no replacement in the
framework: `String.exists()`, `directory()`, `files()`, `openFileForMode(_:_:)`, `String.pathSeparator`,
`String.File.currentWorkingDirectory()` (use `FileManager.default.currentDirectoryPath`), `String.unquote()`,
`String.sha1()` and `String.toBase64(_:)`. `FileManager`, `CryptoKit` and `Data.base64EncodedString()` do the same
jobs.

## NanoHTML is a library of its own, and it is new

The HTML builder is not part of the `NanoHTTP` module any more. It is the product `NanoHTML` (add it to the dependencies
of your target, and `import NanoHTML`), and it is a different builder: pages are values, text and attributes are
escaped, and nothing is global. The closures and global variables of 1.x (`html { body { ... } }`, `href = "/"`,
`inner = "text"`) are gone, so the names `name`, `title`, `type`, `value` and about 150 more do not clash with your own
any more, and pages are not rendered one at a time behind a lock.

```swift nocompile
// 1.x
server["/greeting"] = { request in
  try htmlHandler {
    html {
      body {
        h1 { inner = "Hello, \(request.params["name"] ?? "world")".htmlEscaped }
        a { href = "/"; inner = "Home" }
      }
    }
  }(request)
}
```

```swift
// 2.0
let server = NanoHTTPServer()
server["/greeting"] = htmlHandler { request in
  Html {
    Body {
      H1("Hello, \(request.params["name"] ?? "world")")      // escaped by itself
      A("Home").href("/")
    }
  }
}
```

The article *Building Pages* in the documentation of NanoHTML has the complete table. The main differences: element
types are capitalized (`Div`, `Ul`, `Td`); attributes are methods that follow the element (`.href("/")`,
`.class("card")`, `.autofocus()`); `for` and `if` replace the helpers for sequences; `Raw("...")` replaces `inner` for
HTML that you wrote; `htmlHandler`'s block receives the request; and `Html` writes the document type itself. The
obsolete elements (`center`, `font`, `marquee`, ...) have no type, `Data` and `Progress` are `DataValue` and
`ProgressBar`, and `String.htmlEscaped` is still in `NanoHTTP`.

## Logging

What the server reports (a handler that threw, a response that could not be written, a pause in accepting connections, a
WebSocket client that broke the protocol) goes to a **logger** with a level, no longer to `print`. The messages are the same
ones, but their destination changed:

- The default logger, `NanoOSLogger`, writes to the unified logging system: you see the messages in the console of Xcode
  and in the Console app, but **a command-line tool does not print them to its terminal any more**. Set a `NanoConsoleLogger`
  for that (`server.configuration.logger = NanoConsoleLogger()`), or a `NanoSilentLogger` to switch logging off.
- `NanoHTTPServerIO.log(_:)` is not `open` any more. Subclasses that overrode it (to show the messages in a window, to
  collect them in a test) no longer compile; write a type that conforms to `NanoHTTPLogger` and set it in the configuration:

```swift nocompile
// 1.x
final class MyServer: NanoHTTPServer {
  override func log(_ str: String) { output += str + "\n" }
}
```

```swift
// 2.0
final class MyLogger: NanoHTTPLogger {
  func log(_ level: NanoLogLevel, _ message: @autoclosure () -> String) {
    print("[\(level)] \(message())")
  }
}
let server = NanoHTTPServer()
server.configuration.logger = MyLogger()
server.log("calling the logger from your own code")   // as before: logs at the level info
```

- `NanoSocketSession.start` got a third parameter, the logger of the server (`start(socket:drainTimeout:logger:)`); sessions of
  your own that implement the protocol have to add it.
- A WebSocket session no longer prints `Unkown error ...` or `Protocol error: ...`; those lines are messages at the level
  `info` (a client's mistake) or `warning` now.

## Host, Origin and CORS (new, off by default)

Nothing changes for your server unless you switch these on. A server that web pages can reach (every server on the loopback
address, since the browser is on the same machine) can refuse the two kinds of requests that pages of other sites make it
receive:

```swift
let server = NanoHTTPServer()
server.configuration.hostPolicy = .automatic       // DNS rebinding: only localhost, 127.0.0.1 and [::1] on the loopback address
server.configuration.originPolicy = .sameOrigin    // requests that change something, and WebSocket handshakes, of other sites
```

A refused request gets `403 Forbidden` before the middleware runs, and a warning in the log. `.hosts([...])` and `.origins([...])`
list the names and the pages that are allowed on a server that listens at other addresses or is used by other sites.
`NanoMiddleware.cors(NanoCORSPolicy(...))` answers the preflight requests of browsers and gives the pages that you trust
access to the answers. If you wrote middleware for this in 1.x (the example of the article *Security and Limits* checked
`request.header("host")` and `request.header("origin")`), the policies replace it; they also handle IPv6 hosts, ports, the
case of host names and `Origin: null`, which a hand-written comparison usually does not. The article has the details.

## WebSockets: hub, subprotocols, origins, and sessions that end when a write fails

- `NanoWebSocket.handler` has three more parameters, after `maxMessageSize`, so that existing calls do not change:
  `origins:` (which pages may connect, the same `OriginPolicy` as the server's, default `.any`), `protocols:` (the
  subprotocols that the handler speaks) and `hub:` (a `NanoWebSocketHub`). A client that offers subprotocols of which the handler
  knows none is refused with `400`; `session.subprotocol` tells the closures which one was chosen.
- Code that keeps the sessions of a chat in a collection of its own, with a lock, can use a `NanoWebSocketHub` instead:
  `NanoWebSocket.handler(text: { session, text in hub.broadcast(text: text, except: session) }, hub: hub)`.
- **A write that fails now ends the session.** A frame that is written in part (the client stopped reading, the connection
  broke) cannot be followed by another one, so the connection is closed, `disconnected` is called, and the failure is logged
  once at the level `info`. Later writes to that session do nothing. In 1.x every failed write printed the error and the
  session went on.
- **Writes to sessions have a shorter timeout:** `Configuration.sessionWriteTimeout` (default 5 seconds) applies to
  connections that have been turned over to a session, instead of the `writeTimeout` (30 seconds) of requests. A client that takes
  nothing for that long is dropped, which keeps a stalled client from holding up a broadcast, and, on a server with one
  thread, the whole server. Set it higher (or `nil`) if your clients can be silent for longer while you send them messages.

## Routing: variables need their segment, and the delegate is gone

- **`/users/:id` no longer matches `/users`.** In 1.x a `:variable` or `*` at the end of a route also matched when its segment
  was missing, and `id` was the empty string; now such a request matches nothing (`404`, or `405` if the path has routes for
  other methods). Only the path variables `::name` and `**` match nothing. A route that relied on the empty `id` needs a
  route of its own: `server.get["/users"] = ...`. Search your code for handlers that check `params["id"]?.isEmpty`.
- Variables at the same position that could both match a path are tried in the order in which they were registered (they were
  tried in an order that changed from run to run).
- Routing is faster (it looks fixed segments up in a dictionary and does not lock while matching), which you can only notice
  with many routes and many threads.
- **`NanoHTTPServerDelegate` and `NanoHTTPServerIO.delegate` are removed.** The delegate was told when a connection had
  received its first request, but not about later requests of the same connection, and twice about a connection that became a
  WebSocket. What it was used for is done better by other means: middleware sees every request
  (`server.middleware.append { request, next in ... }`), `handle(connection:)` wraps a connection, and the logger
  reports what goes wrong.

## Smaller changes that the compiler reports

- `NanoHTTPParserError` has new cases (`unsupportedVersion`, `conflictingFraming`, `unsupportedTransferEncoding`, `invalidChunk`,
  `expectationFailed`), `NanoSocketError` has `timedOut`, and `NanoHTTPResponse.Body` has `session`: a `switch` over these types
  that has no `default` has to handle them.
- `NanoHTTPServer(configuration:)` and `NanoHTTPServerIO(configuration:)` are the designated initializers (`NanoHTTPServer()` still
  works: the configuration has a default). A subclass that has an initializer of its own calls `super.init(configuration:)`
  or `super.init()`.
- `NanoHTTPRequest(method:path:queryParams:headers:body:)` has one more parameter, `httpVersion:`, which has a default: calls
  do not change. The parameters take decoded text (see *Paths and query values are decoded*).
- `NanoNetworkInterface` replaces `NetworkInterface` (*Names and namespaces*); `NanoSocket.tcpSocketForListen` takes a
  `NanoHTTPServerIO.NanoListenAddress` and a `backlog`; `NanoHTTPServerIO.listen(priority:)` is `listen()`.

