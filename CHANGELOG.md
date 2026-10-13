# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

### Changed
- Existing tests no longer use fixed ports (8080, 9081), no longer ignore bind failures, and the
  flaky `testShouldHandleTheSameRequestConcurrently` waits for all of its requests.
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
- `String.htmlEscaped`: escapes `& < > " '` for use as the text or an attribute value of an HTML element.

### Fixed
- `share(file:) and `share(directory:defaults:followSymlinks:)` sent the length of a symbolic link
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

[Unreleased]: https://github.com/objecthub/swift-nanohttp/compare/1.0.1...HEAD
[1.0.1]: https://github.com/objecthub/swift-nanohttp/compare/1.0...1.0.1
[1.0]: https://github.com/objecthub/swift-nanohttp/releases/tag/1.0
