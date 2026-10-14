# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.0.0] - 2026-10-14

2.0 is a major release. It changes the API in many places, which `MIGRATION-2.0.md` lists with what to do (the compiler reports
most old names and says what to use instead), and it changes a few defaults: servers listen at the loopback address,
connections are persistent, paths and query values are decoded once, and the server logs through a logger.

Highlights:

- **Faster:** a persistent connection costs about half the CPU of 1.0.2 per request: 1.3x the requests per second with one
  client and 4.8x with sixteen, a shared 100 KB file is served 11x faster, and WebSocket echo 1.05x to 1.15x. A new
  connection for every request is as fast as before and uses a third to more than half less CPU. Large responses and uploads
  are as fast as before. The one-thread mode gains about the same (README, *Performance*).
- **One-thread servers:** `configuration.threading = .singleThread` serves everything, WebSockets included, on one thread;
  handlers need no locks.
- **`NanoHTML`**, a second library: pages are built from Swift values, with escaping, without global state.
- **Safer:** loopback by default, optional Host/Origin policies and CORS, limits and timeouts, a connection limit.
- **A complete HTTP/1.1 server:** keep-alive, chunked bodies, `HEAD`, `OPTIONS`, `405`, conditional requests and ranges for files.
- **Handlers that throw, middleware that wraps**, decoded request values, a logger with levels, a WebSocket hub with subprotocols
  and origin checks.

### Added
- **WebSocket hub, subprotocols and origins** (W2). `NanoWebSocketHub` keeps the sessions of a chat and sends text and binary
  messages to all of them, except one if wanted; it is thread-safe, needs no locks on your side, and works on a server with
  one thread. `NanoWebSocket.handler` has three more parameters: `hub:` (sessions join and leave by themselves), `protocols:`
  (negotiates `Sec-WebSocket-Protocol`; `NanoWebSocketSession.subprotocol` is the result; offers of which none is known are
  answered with `400`) and `origins:` (an `OriginPolicy` for the handshake of this route). `Configuration.sessionWriteTimeout`
  (5 seconds) limits how long a write to a session may be blocked.
- **Host and Origin policies, and CORS** (S6), all off by default. `Configuration.hostPolicy` (`.any`, `.automatic`,
  `.hosts([...])`) refuses requests for other host names (DNS rebinding); `Configuration.originPolicy` (`.any`,
  `.sameOrigin`, `.origins([...])`) refuses requests that change something, and WebSocket handshakes, from pages of other
  sites. Refused requests get `403 Forbidden` before the middleware runs, and a warning in the log. `NanoMiddleware.cors`
  with a `NanoCORSPolicy` answers preflight requests and adds the permission headers; `NanoMiddleware.hostAllowlist` and
  `originAllowlist` are the same checks as middleware. See *Security and Limits*.
- `NanoHTTPLogger`, `NanoLogLevel` (`debug`, `info`, `warning`, `error`), `NanoOSLogger`, `NanoConsoleLogger` and
  `NanoSilentLogger`; `NanoHTTPServerIO.logger`, `log(_:_:)` (the message is only built if the logger wants it) and
  `NanoWebSocketSession.logger`. The documentation has an article, *Logging*.
- `NanoFile(path:mode:)` opens a file (`.read`, `.create`, `.update`) for a response body writer, and
  `NanoFiles.mimeType(forPath:)` is the public way to look up a MIME type.
- **HTTP/1.1 behavior:**
  - Keep-alive by default (H4): connections are persistent unless `Connection: close` (HTTP/1.0: unless
    `keep-alive`); the server answers `Connection: close` when it closes; `Date` on every response; no
    `Content-Length` on `204` and `304`.
  - Bodies of requests in chunks (`Transfer-Encoding: chunked`) are decoded, `Expect: 100-continue` is answered
    (`417` for other expectations), and ambiguous requests are refused: `Content-Length` with chunks (`400`),
    another `Transfer-Encoding` (`501`), a version other than HTTP/1.0 and HTTP/1.1 (`505`). New
    `NanoHTTPParserError` cases and `request.httpVersion`.
  - Bodies that a function writes (`.custom`) are sent in chunks, or with the `Content-Length` that the handler
    declares (checked: a body of another length ends the connection).
  - `HEAD` is answered by the `GET` handler without a body (H7); `405` with `Allow` for a path that has routes, but
    not for the method; automatic `OPTIONS`; `server.options[...]`; `NanoHTTPRouter.allowedMethods(path:)`.
  - Files (H10): `ETag`, `Last-Modified`, `If-None-Match`/`If-Modified-Since` (`304`), `Range`/`If-Range` (`206`, `416`),
    keep-alive for files, `301` for a directory without a slash and its index file inside, `404` instead of an empty `200`.
    `NanoSocket.writeFile(_:offset:length:)` and `NanoHTTPResponseBodyWriter.write(_:offset:length:)`.
  - `Benchmarks/` has scenarios for files and WebSockets, and the load generator retries a request on a connection that
    the server has closed in between, like a client does.
- **Request helpers** (H1): `NanoHTTPRequest.query(_:)` and `queries(_:)`, `rawPath` and `rawQuery` (what the client
  sent), `bodyString` (in the charset of the `Content-Type`), `json(_:decoder:)` (decodes the body; a body that is empty,
  no JSON or does not fit the type throws `NanoHTTPError.badRequest` with a message that says what is wrong) and
  `jsonObject()`. `NanoHTTPRequest.init(method:rawPath:rawQuery:headers:body:)` creates a request from a target that is
  still percent-encoded.
- **`NanoSocketSession`**: a conversation over a connection that has been switched away from HTTP, which the
  server drives: it calls `start`, then `receive()` whenever the socket has something to read, and `end`.
  `NanoHTTPResponse.switchProtocols(_:session:)` (and the new case `NanoHTTPResponse.Body.session`) turns a
  connection over to one. A server with threads per connection runs the session on the thread of the connection; a
  server with one thread waits for the sockets of all sessions together with all its other connections, so
  `NanoWebSocket.handler(...)` and sessions of your own no longer occupy the only thread (W3). The WebSocket protocol logic of
  `NanoWebSocket.handler(...)` is such a session now. `switchProtocols(_:_:)` with a function still exists; on a server with
  one thread, the function has the thread until it returns.
- **Errors:** `NanoHTTPError`, which a handler or middleware throws to answer with a status code,
  headers and a message (`throw NanoHTTPError.notFound("No such item")`), with a function for every usual status.
  Any other error becomes `500 Internal Server Error` without details; the details are logged with the method and
  path. `NanoHTTPServer.errorHandler` decides how errors are answered (for JSON errors, say), and
  `NanoHTTPServerIO.response(for:to:)` can be overridden. `NanoHTTPConnection.response()` calls the handler and
  answers its errors.
- `NanoHTTPMiddleware`: the type of middleware, see below.
- `Benchmarks/`: `python3 Benchmarks/run.py` compares the throughput, latency and CPU use of the working copy
  with a release (default: 1.0.2), with paired runs so that machine noise does not decide; see
  `Benchmarks/README.md`.
- **One-thread servers.** `server.configuration.threading = .singleThread` makes one thread do everything:
  accepting connections, reading requests, the middleware, the handlers and writing the responses. Requests are served
  one at a time, and handlers need no locks. `start(_:)` starts that thread; the new `run(_:)` uses the calling thread
  and returns when the server is stopped (it is also available with threads per connection, where it accepts
  connections on the calling thread). The thread waits for the listening socket and all connections together, so
  idle and keep-alive connections do not block anything, and idle connections are closed after the idle timeout.
  WebSockets work on the one thread too (see `NanoSocketSession` below): their closures, the handlers and the
  middleware never run at the same time, so a chat needs no lock, not even when HTTP handlers write to the sessions.
  Limits: a slow handler or closure delays everything, and a stalled request or message, or a client that does
  not read, delays the server up to the read or write timeout.
- **Timeouts and a limit for connections** (R3), in `NanoHTTPServerIO.Configuration`: `idleTimeout` (60 s; a
  connection that sends no request is closed), `readTimeout` (30 s; a request that stalls is answered with
  `408 Request Timeout`), `writeTimeout` (30 s; a peer that does not read is dropped) and `maxConnections` (128;
  further connections get `503 Service Unavailable` with `Retry-After`). `nil` disables a limit. WebSocket sessions are
  not subject to the idle and read timeouts, but count as connections.
- `NanoHTTPServerIO.NanoListenAddress`, `NanoSocketError.timedOut`, `NanoSocket.setReceiveTimeout(_:)`, `setSendTimeout(_:)` and
  `waitUntilReadable(timeout:)`.

### Changed
- **Breaking: a variable needs its segment** (H8). `/users/:id` (and `*`) no longer matches `/users` with an empty `id`; only
  the path variables `::name` and `**` match nothing. Variables at the same position are tried in the order of their
  registration (it was the order of a dictionary). Matching is faster (fixed segments are found in a dictionary, the tree is
  matched without a lock): about 2.5 times faster for one thread with 200 routes, and 6 times faster with 8 threads that do
  nothing but route. See *Routing* in `MIGRATION-2.0.md`.
- **A WebSocket session ends when a write to it fails:** the connection is closed, `disconnected` is called and the failure is
  logged once (`info`); later writes do nothing. A write to a session has the `sessionWriteTimeout` of 5 seconds, not the
  30 seconds of `writeTimeout`. See *WebSockets* in `MIGRATION-2.0.md`.
- **Breaking: the server logs through a logger, with levels, and no longer prints.** `Configuration.logger` takes a
  `NanoHTTPLogger`; the default, `NanoOSLogger`, writes to the unified logging system (Xcode console, Console app), so a
  command-line tool has to set a `NanoConsoleLogger` to see the messages in its terminal. `NanoHTTPServerIO.log(_:)` is no
  longer `open` (it logs at the level `info`; `log(_:_:)` takes a level), so subclasses that overrode it do not compile
  until they use a logger. `NanoSocketSession.start(socket:drainTimeout:)` has a third parameter, `logger:`. The messages of
  WebSocket sessions go to the logger instead of `print`. See *Logging* in `MIGRATION-2.0.md`.
- **Breaking: NanoHTML is a library of its own, and it is a new builder** (N1, N2, N3, S5). Add the product `NanoHTML` and
  `import NanoHTML`. Pages are built from values: `Html { Body { H1("Hi"); A("Home").href("/") } }`; text and attribute
  values are escaped (`Raw(_:)` inserts HTML as it is), void elements have no end tag, attributes are written in the
  order in which they were set, and there is no global state, no lock and no clash with member names. `htmlHandler`'s
  block receives the request, `NanoHTTPResponse.html(_:status:headers:)` answers with any node, and `Html` writes the
  document type. `String.htmlEscaped` stays in `NanoHTTP`. See *Names and namespaces* and *NanoHTML is a library of its
  own* in `MIGRATION-2.0.md`.
- **Breaking: general names got a `Nano` prefix or a namespace.** `share(file:)`, `share(directory:...)` and
  `browse(directory:...)` are `NanoFiles.share(...)` and `NanoFiles.browse(...)`, `websocket(...)` is
  `NanoWebSocket.handler(...)`, `WebSocketSession` is `NanoWebSocketSession`, `NetworkInterface` is
  `NanoNetworkInterface`, `String.File` is `NanoFile` and `String.mimeType()` is `NanoFiles.mimeType(forPath:)`. The old
  names are kept as unavailable declarations in 2.x so that the compiler says what to use (`MIGRATION-2.0.md`, *Names
  and namespaces*).
- **Faster:** sockets are read in 16 KB blocks (not byte by byte), the head of a response and a small body are written
  together, the parser is faster, `TCP_NODELAY` is set, and files keep the connection open. Against 1.0.2 a
  persistent connection costs about half the CPU per request; the figures are in the README (*Performance*), measured
  with `Benchmarks/run.py`.
- **Breaking: connections are persistent and `.custom` bodies are chunked**, see `MIGRATION-2.0.md` (*HTTP as clients
  expect it*): code and tests that relied on the server closing the connection after a response have to send
  `Connection: close`; a path with routes for other methods answers `405` instead of `404`; `HEAD` is no longer answered
  with a body; a directory in `share(directory:)` is redirected or answered with its index file instead of an empty `200`;
  the listing of `browse` no longer has the entries `.` and `..`; `NanoHTTPRequest.supportsKeepAlive` follows the version
  of the protocol.
- **Breaking: paths and query values are decoded** (H1). `request.path`, the names and values of `request.queryParams`
  and the values of `request.params` are percent-decoded text, once (`/caf%C3%A9?q=a%20b+c` is the path `/café` and
  `q` = `a b c`; a `+` is a space in a query, not in a path). `::path` variables are decoded too (they were not), and
  `share(directory:)` and `browse(directory:)` no longer decode them again (decoding twice would turn `%252e%252e`
  into `..`). Code that decodes the values itself has to stop doing that, see `MIGRATION-2.0.md`. The router routes on
  the new `rawPath`, so that an encoded slash stays inside its segment; setting `path` encodes it into `rawPath`.
  Invalid percent sequences are kept in `path` and query values (they used to be, too) and match no route. `NanoHTTPRequest(method:path:queryParams:)`
  now takes decoded text. The decoded path can contain line breaks and NUL
  characters: the server logs `rawPath`.
- The parser splits the request target itself instead of with `URLComponents`: bytes that are not ASCII in a target
  are read as UTF-8, a target in absolute form (`GET http://host/a?b HTTP/1.1`) gives its path and query, and a
  fragment is dropped.
- **Breaking: handlers can throw.** `NanoHTTPRequestHandler` is `(NanoHTTPRequest) throws -> NanoHTTPResponse`.
  Closures that do not throw still work; code that calls a handler needs `try`. A server whose
  `handle(connection:)` calls `connection.handler(connection.request)` has to call `try` or use the new
  `connection.response()`.
- **Breaking: middleware wraps the handling of requests.** `server.middleware` is `[NanoHTTPMiddleware]`, functions
  `(request, next) throws -> response` that can change the request, the response and the errors, or answer without
  calling `next`. A 1.x middleware `{ request in cond ? nil : response }` becomes
  `{ request, next in cond ? try next(request) : response }`. Middleware still runs before routing; it sees every
  request, including those without a route, and the responses.
- **Breaking: servers listen at the loopback address (`127.0.0.1`) by default.** They accepted connections on all
  network interfaces. A server that other devices are meant to reach needs
  `server.configuration.listenAddress = .allInterfaces`. The command-line demo is reachable from this machine only
  unless it is started with `--network`, and with `--single-thread` it runs on one thread.
- **Breaking: `NanoHTTPServerIO.Configuration`** (`server.configuration`, or `NanoHTTPServer(configuration:)`)
  replaces the settings that were spread over properties and parameters: `listenAddressIPv4`, `listenAddressIPv6`
  and the `forceIPv4` parameter of `start` become `listenAddress` (`.loopback`, `.allInterfaces`,
  `.address("192.168.1.20")`; the address family follows the address), `limits` moves into the configuration, and
  the `priority` and `handlerPriority` parameters of `start` become `acceptQoS` and `connectionQoS`.
  `start(_ port:)` takes only the port. A running server keeps the configuration it was started with.
- **Breaking:** `NanoHTTPServerIO.listen(priority:)` is `listen()`; `NanoSocket.tcpSocketForListen` takes a
  `NanoHTTPServerIO.NanoListenAddress` and a `backlog` instead of `forceIPv4`, `maxPendingConnection` and `listenAddress`.
- Connections and the accept loop run on threads of their own instead of the global dispatch queues. The threads
  of connections are reused (a thread that has served a connection waits up to 10 seconds for the next one; at most
  32 wait), so a connection does not cost the creation of a thread. A thread with `.userInitiated` priority accepts
  connections (it was `.background`, which the system may throttle).
- The `priority` and `handlerPriority` parameters of `start` are gone, and so are their `nil` values, which
  made the server accept connections on the calling thread (`priority: nil`) and serve them one after another on
  the accepting thread (`handlerPriority: nil`). `threading = .singleThread` and `run(_:)` replace them.
- `NanoSocket.read()` retries when it is interrupted by a signal, and a closed connection is reported as
  "connection closed by peer" instead of "Undefined error: 0".

### Removed
- `NanoHTTPServerDelegate` and `NanoHTTPServerIO.delegate` (H11): it was called for the first request of a connection only, and
  twice for connections that became WebSockets. Middleware, `handle(connection:)` and the logger do its job.
- The closure-based HTML builder of 1.x: its ~150 global attribute variables (`href`, `name`, `inner`, ...), the element
  functions (`html`, `body`, `a`, ...), `element(_:_:_:)`, `NanoHTMLClosure` and the elements that HTML has removed
  (`center`, `font`, `marquee`, `blink`, ...).
- The helpers that Swifter had left on `String` are not public any more: `exists()`, `directory()`, `files()`,
  `openForReading()`, `openNewForWriting()`, `openForWritingAndReading()`, `openFileForMode(_:_:)`, `pathSeparator`,
  `File.currentWorkingDirectory()`, `unquote()`, `sha1()` and `toBase64(_:)`. `NanoFile(path:mode:)` and `FileManager`
  replace the first ones.
- The GitHub Actions workflow (`.github/workflows/ci.yml`): the project has no continuous integration. The checks it ran
  are scripts and commands that are run by hand, listed in `CONTRIBUTING.md`.

### Fixed
- A WebSocket session no longer writes a second close frame to a connection that has been closed when it is released: that
  write always failed, and the failure was printed as `writeFailed("Bad file descriptor")` for every connection.
- A server that is stopped no longer reports the accept that its closed listening socket made fail.
- Idle connections no longer starve the server: between 60 and 70 silent connections used up the threads of the
  dispatch pool, and no request was served after that (R3).

### Security
- Servers listen at the loopback address by default (they accepted connections on all interfaces).
- Host and Origin policies and a CORS middleware (off by default), `403` before the middleware runs.
- NanoHTML escapes text and attribute values (S5, N3); the old builder inserted `inner` as it was and shared global state (N1).
- Paths, query values and route variables are decoded once, and the file handlers do not decode again, which closes a way
  to path traversal through double-encoded input (`%252e%252e`) that decoding in two places had opened.
- Requests with ambiguous framing (`Content-Length` and chunks together, unknown transfer encodings) are refused.

## [1.0.2] - 2026-10-13

### Added
- Test harness: servers on ephemeral loopback ports, a raw-socket HTTP/WebSocket client,
  file-descriptor and leak helpers (`Tests/NanoHTTPTests/Support`).
- More than 130 new tests: security, robustness, HTTP protocol, request parsing, router behavior,
  WebSocket end-to-end, HTML builder. Defects that are known but not yet fixed are recorded as
  *expected failures* (see `Tests/README.md`), so the suite is green and flips red when one is fixed.
- Continuous integration (GitHub Actions): build and test, coverage summary, Address/Thread
  sanitizer runs, iOS demo app build.
- `Scripts/check_xcodeproj.py` (run in CI): fails when a Swift file is missing from, duplicated in or
  stale in `NanoHTTP.xcodeproj`. The new test files were added to the project; duplicate references to
  `IOSafetyTests`, `PingServer` and `ServerThreadingTests` were removed.

- `followSymlinks` parameter for `share(directory:defaults:followSymlinks:)` and
  `browse(directory:followSymlinks:)` (default `false`): serve symbolic links even if they lead out of
  the shared directory. Links that stay inside the directory are always followed.

- Documentation: a DocC catalog (`Sources/NanoHTTP/NanoHTTP.docc`) with thirteen articles (getting started, routing,
  handlers and responses, reading requests, serving files, WebSockets, middleware and extending, threading and
  lifecycle, security and limits, the HTML builder, iOS, testing, how a request is served) and documentation comments
  for the public API, including the guarantees the code relies on (threading, percent-encoding of `path` and
  `queryParams`, what the server closes and when). The catalog is part of the Xcode project; `.spi.yml` publishes it
  on the Swift Package Index.
- `Scripts/check_doc_examples.py` compiles every Swift example of the README, the articles and the documentation
  comments against the library, and `Scripts/check_docs.py` builds the documentation and fails on warnings
  (unresolved links, missing symbols). Both run in CI.
- `SECURITY.md` (how to report a vulnerability, what is in scope) and `CONTRIBUTING.md`.

### Changed
- Existing tests no longer use fixed ports (8080, 9081), no longer ignore bind failures, and the
  flaky `testShouldHandleTheSameRequestConcurrently` waits for all of its requests.
- README rewritten: what the framework is for and not for, a quick start, installation, security notes and a
  warning that the demo server shares the Downloads folder with the network.
- README: removed the Linux claim (the package never built there; it uses CryptoKit and
  UniformTypeIdentifiers), listed tvOS (declared in `Package.swift`), corrected the license badge
  (BSD 3-Clause, not Apache).

- **Minimum deployment targets raised to macOS 12, iOS 15 and tvOS 15** (`Package.swift` and the Xcode
  project, kept in sync; `Scripts/check_xcodeproj.py` enforces it). Current Xcode versions no longer
  support the previous minimums (macOS 11, iOS 14, tvOS 14), so the Xcode project did not build.
  This is a source-compatibility change for clients that still target the older systems.

- **Requests are refused instead of crashing or being dropped silently.** A request line longer than the
  limit gets `414`, too long or too many headers `431`, a body above `maxBodyBytes` `413`, and a request
  that cannot be parsed (invalid request line, non-numeric or negative `Content-Length`) `400`; the
  connection is closed afterwards. Bodies above 64 MiB, which were accepted before, are refused unless
  `server.limits.maxBodyBytes` is raised. A non-numeric `Content-Length` used to be ignored.
- WebSocket messages (single frames or assembled from fragments) above 16 MiB, and control frames with more
  than 125 bytes, end the connection unless `maxMessageSize` is raised.
- `NanoSocket.read(length:)` allocates with the data that arrives instead of the announced length.
- `start` throws `NanoSocketError.bindFailed` for a `listenAddressIPv4`/`listenAddressIPv6` that is not an address
  (it silently listened on all network interfaces).
- The `Content-Type` of `.text` and `.html` bodies and of `htmlHandler` pages has the parameter `; charset=utf-8`.
- Reason phrases are the standard ones (`200 OK`, `404 Not Found`); `HTTPURLResponse.localizedString` gave `200 no error`.
- Request headers: the value of a header without value is empty (it was the name), a line without a colon is
  ignored, spaces around the name are removed, and repeated headers are combined with `, ` (the last one used to win).
- WebSocket: a connection that ends because of an error is closed with a status code (1002 protocol error, 1007 invalid
  UTF-8, 1009 message too big), and the status code of a close frame of the client is answered with the same code;
  invalid status codes and one-byte close payloads are protocol errors. The handshake must be a `GET` request
  (`405` otherwise) with `Sec-WebSocket-Version: 13` (`426` with that header otherwise, as RFC 6455 4.4 requires).
- `NetworkInterface.localIP` does not depend on the order in which the system lists interfaces any more: `en0`, `en1`,
  ... come first (numerically), link-local addresses last. An address without a netmask is reported with an empty
  netmask (it was skipped).
- `parseUrlencodedForm` decodes `+` before the percent sequences (so `%2B` stays a plus), keeps `=` inside values and
  turns a field without `=` into a name with an empty value (it was a bogus empty pair); the content type is
  matched case-insensitively.
- A `.json` body that cannot be serialized gives `500 Internal Server Error` (it was `200` with the error text);
  details are logged.
- Response headers: a name that is not a valid header name drops the header (and is logged); carriage return, line
  feed and NUL in a value become spaces.
- `browse(directory:)` and the default index file of `share(directory:)` send `Content-Type` and `Content-Length`.
- `NanoHTTPServerIO.start` returns without effect if the server is not stopped (it is already running, or being started or stopped by another thread).
- `closeAndforgetAllConnections()` shuts connections down and releases them as their threads finish.

### Removed
- Carthage: dropped from the README (badge and requirements) and the `.gitignore` template block.
  No `Cartfile` or shared framework scheme ever existed, so Carthage could not build the package;
  Swift Package Manager is the supported way to depend on NanoHTTP.

- Request size limits: `NanoHTTPParser.Limits` and `NanoHTTPServerIO.limits` (set before `start`) with
  `maxLineLength` (8 KiB), `maxHeaderBytes` (64 KiB) and `maxBodyBytes` (64 MiB).
- `websocket(..., maxMessageSize:)` (default 16 MiB) and `WebSocketSession.maxPayloadSize`.
- `NanoHTTPParserError` is public (it was internal) and has new cases for the limits.
- `WebSocketSession.writeCloseFrame(code:reason:)` and `WebSocketSession.CloseCode` (status codes of close frames).
- `WebSocketSession.WsError.messageTooBig`: a frame or a message above the size limit (it was a `protocolError`).
- `String.htmlEscaped`: escapes `& < > " '` for use as the text or an attribute value of an HTML element.

### Fixed
- `NanoHTTPSegmentRouter()` and `NanoHTTPServerIO()` can be created from other modules (their implicit
  initializers were internal, although the classes are `open`).
- `share(file:)` and `share(directory:defaults:followSymlinks:)` sent the length of a symbolic link
  (the length of its target path) as `Content-Length` instead of the size of the file it points to.
  Linked files longer than that were truncated, shorter ones left clients waiting.

- WebSocket: the most significant byte of a 64-bit frame length was shifted by 54 bits instead of 56.
- After a refused request or a failed WebSocket session the connection is now closed only after the peer
  had a chance to read the answer. Closing with unread data made TCP reset the connection, and the peer
  could lose the response.
- A failed `accept()` no longer stops the server for good. An interrupted or aborted attempt is retried; running
  out of file descriptors or memory pauses accepting (with a delay that grows to one second) and logs it, and the
  server keeps running. Only a closed or unusable listening socket ends the accept loop. Connections that arrive
  during such a shortage can be lost, because macOS discards a pending connection whose `accept` failed.
- A file that was opened for a response that is never written (client gone, server stopping) is closed when the
  response is released; before, its file descriptor leaked, which eventually exhausted the process. `String.File`
  closes itself in `deinit`, and `close()` may be called more than once.
- NanoHTML: concurrent requests could corrupt each other's pages and abort the process, because the builder keeps its
  state in process-wide variables. `htmlHandler` now builds one document at a time (and sends the finished page),
  so a closure passed to it should only build the page. A proper fix, without shared state, needs the redesign
  planned for 2.0.
- Closing a socket is safe while other threads read or write it. A closed socket's file descriptor number is
  handed out again by the system, and a thread that still used it could read from or write to an unrelated
  connection (a late `WebSocketSession.writeText` after the connection had ended, a connection thread running when
  `stop()` closed its socket, two threads closing the same socket). `NanoSocket.close()` now shuts the connection down
  (this wakes blocked reads and writes), waits for running operations (at most two seconds), and only then releases the
  descriptor; operations on a closed socket fail instead of touching the descriptor.
- `NanoSocket` instances are compared by identity instead of by descriptor number, so forgetting a stale socket can no
  longer forget a live one that has the same number.
- `NanoHTTPServerIO.state` changes atomically (it used a compare-and-swap with a freshly read expected value, which
  protected nothing, and a deprecated API). Concurrent calls of `start` and `stop` now do the work exactly once. A
  `start` that fails (port in use, invalid address) leaves the server `stopped` instead of `starting`, and the accept
  loop of an earlier run can no longer stop a server that has been started again.
- WebSocket: frames that several threads send through one session (a broadcast, a pong in reply to a ping) were
  written in parts and could interleave, which corrupted the stream. Frames are written one at a time now, and small
  ones (up to 64 KiB) in a single write.
- WebSocket: a text message that contained a NUL character was cut off at it.
- `NetworkInterface`: IPv6 addresses (and netmasks) were garbled, because the address was copied into a `sockaddr`
  that is smaller than `sockaddr_in6`; an entry without an address (some tunnel interfaces) crashed the process;
  netmasks that the system stores without their trailing zero bytes were misread.

### Security
- `share(directory:defaults:)` and `browse(directory:)` no longer serve files outside the shared
  directory. Requests with `..` segments (also percent-encoded), NUL characters, or paths that lead
  out of the directory through symbolic links are answered with `403 Forbidden`. Symbolic links that
  stay inside the directory, and shared directories that are themselves symbolic links, keep working.
- Response splitting: a header value that contained a line break (a redirect to a location taken from a request, for
  example) could inject headers or start the body. Line breaks are replaced, invalid header names are dropped.
- HTML injection: `browse(directory:)` inserted file names (and the request path) into its listing unescaped, and
  `NanoHTML` attribute values could end their attribute with a quote. Both are escaped now. `inner` is still inserted
  as it is, because it may contain markup: escape untrusted text with `htmlEscaped`. The demo servers do.
- A server that is given a `listenAddressIPv4`/`listenAddressIPv6` with a typo no longer listens on all network
  interfaces instead.
- A single request could abort the process: the value of `Content-Length`, and the length announced by a
  WebSocket frame, were used as an allocation size without any limit. Request lines, headers, bodies and
  WebSocket messages are now bounded (see Added), and memory is only used for data that actually arrives.

## [1.0.1] - 2024-08-09

### Fixed
- Computation of the local IP address (`NetworkInterface.localIP`).

## [1.0] - 2024-08-08

First release (replaces the former `0.1 (2024-07-19)` entry, which was never tagged).

### Added
- HTTP/1.1 server (`NanoHTTPServer`) based on Swifter, with keep-alive and a pluggable router
  (`NanoHTTPRouter`, default `NanoHTTPSegmentRouter` with `:var`, `::pathvar`, `*` and `**`
  placeholders and sub-router mounting; empty matches for path variables).
- Responses that force closing the connection (`dontKeepAlive`).
- WebSocket support, file sharing (`share`, `browse`), HTML builder (`NanoHTML`).
- `NetworkInterface` and `NetworkInterface.localIP`; the demo servers log the URL under which
  they are reachable.
- Swift Package Manager support; demo server for macOS (command line) and iOS (SwiftUI app).

[Unreleased]: https://github.com/objecthub/swift-nanohttp/compare/2.0.0...HEAD
[2.0.0]: https://github.com/objecthub/swift-nanohttp/compare/1.0.2...2.0.0
[1.0.2]: https://github.com/objecthub/swift-nanohttp/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/objecthub/swift-nanohttp/compare/1.0...1.0.1
[1.0]: https://github.com/objecthub/swift-nanohttp/releases/tag/1.0
