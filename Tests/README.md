# NanoHTTP tests

```
swift test                                  # everything (about 45 s)
swift test --filter SecurityTests           # one area
swift test --sanitize=address               # also: --sanitize=thread
swift test --enable-code-coverage && python3 Scripts/coverage_summary.py "$(swift test --show-codecov-path)"
NANOHTTP_CRASH_TESTS=1 swift test --filter <one test>   # see "Crash tests" below
```

## Layout

| File | Covers |
|---|---|
| `SecurityTests.swift` | path traversal, size limits, WebSocket frame limits, bind address, header injection |
| `RobustnessTests.swift` | accept loop, descriptor leaks, idle connections, stop/restart, empty bodies, `NetworkInterface`, malformed requests |
| `HTTPProtocolTests.swift` | behavior of a running server over a raw socket: framing, keep-alive, HEAD, 405, charset, file responses |
| `RequestParsingTests.swift` | request line, query, headers, url-encoded forms, multipart |
| `MultipartParserTests.swift` | the `multipart/form-data` parser (H9): boundaries and their lookalikes, binary content, headers and parameters (`filename*`), refused bodies and limits, a random round trip and random bytes; the limits of a server |
| `RouterBehaviorTests.swift` | routing precedence, parameters, mounting, concurrency (complements `HTTPRouterTests.swift`) |
| `WebSocketIntegrationTests.swift` | RFC 6455 handshake and frames against a real server; concurrent writers |
| `HostAndOriginTests.swift` | the Host and Origin policies and middleware: parsing, DNS rebinding, requests of other sites, WebSocket handshakes (both threading modes) |
| `WebSocketHubTests.swift` | origins and subprotocols of the WebSocket handler, the hub (join and leave, broadcast, 100 sessions, clients that do not read) in both threading modes |
| `CORSTests.swift` | the CORS middleware: preflight requests, permission headers, credentials, errors |
| `DeferredResponseTests.swift` | answers sent later from other threads (`deferResponse()`): the sender never waits, no timeouts while an answer is pending, dropped tokens, pipelining, limits, a slow client, a switch to a session; both threading modes; plus the worker-pool example of the documentation, run end to end |
| `LoggerTests.swift` | the logger: levels, the built-in loggers, lazy messages, what the server and WebSocket sessions report (both threading modes) |
| `HTMLDSLTests.swift` | the NanoHTML module: elements, attributes, block syntax, escaping, pages as responses |
| `Support/` | `RawClient` (blocking raw TCP client), `withTestServer`, `FileSocket`, `FileFixture`, `expectKnownIssue` |

`HTTPParserTests`, `HTTPRouterTests`, `WebSocketTests`, `StringExtensionsTests`, `MimeTypeTests`,
`IOSafetyTests` and `ServerThreadingTests` predate this layout (inherited from Swifter).

## Conventions

* **No fixed ports.** Use `withTestServer { server, port in … }`; it binds `127.0.0.1:0`.
* **Raw bytes, not `URLSession`**, whenever the exact wire format matters (`..` segments,
  malformed lines, keep-alive, HEAD). `URLSession` normalizes and retries behind your back.
* **Every read has a timeout** (`RawClient` defaults to 3 s), so a broken server fails a test
  instead of hanging it.

### Known issues: `expectKnownIssue(id, summary) { … }`

A test wrapped in `expectKnownIssue` asserts the **correct** behavior. While the defect exists the
assertion fails, XCTest records an *expected* failure and the suite stays green. When the defect is
fixed the assertion passes, XCTest reports "expected failure did not occur", and the test goes red:
**delete the wrapper**, and the test becomes a regression test. `id` refers to the finding in the
assessment (S = security, R = robustness, H = HTTP, W = WebSocket, N = NanoHTML).
`strict: false` is for timing-dependent defects (races).

### Crash tests: `requireCrashTests(id, summary)`

Some defects abort the whole test process, so they cannot be expected failures. Such a test is skipped unless
`NANOHTTP_CRASH_TESTS=1` is set; run it on its own (the process dies). **No test uses this at the moment**: all
defects that crashed the process (S2, S3, N1) are fixed and their tests run normally. The helper stays for the next one;
remove the gate from a test as soon as its defect is fixed.

## Phase 0 results: what the tests established

Fixed since (their tests are plain regression tests now): **S1** path traversal in `share(directory:)` /
`browse(directory:)` (literal `..`, `%2e%2e`, `..%2f`, listing and reading, symlink escape, `%00`).
**H12** (found while adding `followSymlinks`): `Content-Length` of a symlinked file was the length of the link.
**W1** interleaved WebSocket frames (the push tests fail on every run without the write lock) · **W2** NUL cut text, close codes, handshake checks · **R7** `NetworkInterface` (garbled IPv6, crash on entries without an address, unstable `localIP`) · **S4** an invalid listen address bound all interfaces · **S5** unescaped file names / attribute quotes (`inner` stays raw HTML, documented; `htmlEscaped` added) · **S7** CR/LF in header values and invalid header names · **H2** form decoding · **H3** header parsing (empty values, repeated headers, trimmed names) · **H5** unserializable JSON gave `200` · **H6** charset, reason phrases (`200 no error`), default index without `Content-Type` · **R4** closing a socket while other threads used it (stale reads/writes hit an unrelated socket that had reused the descriptor number; double close) · **R5** the non-atomic server state (also: a failed `start` left the server `starting`, a late accept loop of an earlier run could stop a restarted server) · **R1** the accept loop ended on any `accept()` error, e.g. when out of descriptors (now it backs off and keeps running) · **R2** file descriptors leaked when a response was never written (`String.File` closes itself) · **N1** concurrent NanoHTML rendering aborted the process (rendering is serialized now) · **S2** unbounded request line / header block / `Content-Length` (a single request could abort the process;
now `NanoHTTPParser.Limits`, answers 414/431/413/400) · **S3** WebSocket frame length (the claimed length was
allocated up front; the 64-bit decode had a `<< 54` typo; now a payload/message limit) · **R9** garbage requests
now get `400` instead of a silent close. (After refusing, the connection is closed only once the peer had a
chance to read the answer: closing with unread data made TCP reset the connection and the peer lost the response.)

**2.0:** **R3** idle connections starved the server (between 60 and 70 of them pinned all threads of the dispatch
pool): connections have threads of their own now, and there are idle/read/write timeouts and `maxConnections`
(`TimeoutTests.swift`: `RequestTimeoutTests`, `WriteTimeoutTests`, `ConnectionLimitTests`; the idle-connection test in
`RobustnessTests.swift` is a plain test again). `SingleThreadTests.swift` covers the one-thread mode: all code runs on
one thread, handlers need no locks (plain variables; the thread sanitizer is the judge), the process gets no thread
per connection, idle and keep-alive connections do not block others, timeouts, limits, `run(_:)`.
`BufferedReadingTests.swift` (the read buffer, and the pipelined requests and WebSocket frames that wait in it: with
the buffer awareness of the one-thread loop removed, the pipelining tests fail), `ResponseSerializerTests.swift` (the head
of a response as a function, `Date`, bodies in memory), `ConnectionSemanticsTests.swift` (H4: keep-alive by version,
`Connection: close`, chunked requests and responses, `Expect`, declared lengths), `HeadAndOptionsTests.swift` (H7) and
`FileServingTests.swift` (H10: `ETag`, `304`, ranges, directories) cover **H4, H7 and H10** (fixed).
**H9** (multipart, fixed in 2.0.1: the parser works on bytes and is tested with random bodies) was the last known issue; none is left. `HTMLDSLTests.swift` tests the new NanoHTML module (**N1**, **N2**, **N3** and **S5** are fixed by its design: pages are values without shared state, element types do not clash with member names, void elements have no end tag, and everything is escaped except `Raw`). `RequestSemanticsTests.swift` covers H1 (**fixed in 2.0**: `path`, query values and route variables are decoded once, `rawPath`/`rawQuery`
keep what was sent, routing works on the raw path, the file handlers do not decode again, `bodyString`, `json`).
`SocketSessionTests.swift` covers WebSockets on the one thread (**W3**, fixed: sessions are driven by the server;
chat and broadcast without locks, close handshake, protocol errors, stalls, `stop()`, limits) and the
`NanoSocketSession` protocol in both modes. The tests of `ConfigurationTests.swift` cover the listen address
(loopback by default) and the `Configuration` object. The timeout tests wait for real time (the suite takes about 45 s). `HandlerErrorTests.swift` (`NanoHTTPError`, the `500` without details, `errorHandler`, errors on a one-thread server) and
`MiddlewareTests.swift` (order, short-circuit, response changes, errors, requests without a route, rewriting the
path, one thread) cover handlers that throw and middleware. `ThreadPoolTests.swift` covers the pool that reuses the
threads of connections (reuse, no limit for the number of threads, idle lifetime, `close`, exactly-once execution).
Performance is not tested by the suite: `Benchmarks/` is the tool for that.

Confirmed by execution and still open (each is an `expectKnownIssue` or crash test): none.

Hypotheses that did **not** reproduce (kept as plain regression tests):
the leak of the listening socket after `stop()` (the port is released, restart on the same port works 25/25) · R6 (empty writes do not crash).

ThreadSanitizer (`swift test --sanitize=thread`) and AddressSanitizer report nothing; run both before a change is
considered done (there is no CI). Earlier,
TSan reported 79-124 races, all in two places that are fixed now: the non-atomic `NanoHTTPServerIO.state` (R5) and the
unsynchronized `shutdown` flag of `NanoSocket.close` (R4). R4 had a practical effect that showed up under TSan's slowdown:
a thread of an earlier test used a file descriptor *number* that a later test had reused, which broke an unrelated
connection. `SocketCloseTests` reproduces such reuse deterministically.

**H8** (fixed in 2.0): a `:variable` or `*` matches exactly one segment, so `/users/:id` no longer answers `/users` (only
`::path` and `**` can match nothing); variables at the same position are tried in the order of their registration; matching is
lock-free. `RouterBehaviorTests` covers it, including a thread that registers routes while others route (thread sanitizer).
**H11** (fixed by removing `NanoHTTPServerDelegate`).

## Not covered yet

Performance (R8), signal handling (S8), `NanoHTTPDemo`.

## Keeping the Xcode project in sync

SwiftPM finds files by itself, `NanoHTTP.xcodeproj` does not. Whenever a Swift file is added, removed
or renamed, update the project too (new test files go into the `NanoHTTPTests` target, new files in
`Support/` into its `Support` group). `python3 Scripts/check_xcodeproj.py` verifies that every Swift file
is referenced exactly once; run it whenever Swift files change.

The same script checks that the project's deployment targets match the platforms declared in
`Package.swift` (project level and the library targets must be equal; the test bundle and the demo apps may be higher), so
raise them in both places together.
