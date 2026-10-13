# NanoHTTP tests

```
swift test                                  # everything (about 10 s)
swift test --filter SecurityTests           # one area
swift test --sanitize=address               # also: --sanitize=thread
swift test --enable-code-coverage && python3 Scripts/coverage_summary.py "$(swift test --show-codecov-path)"
NANOHTTP_CRASH_TESTS=1 swift test --filter <one test>   # see "Crash tests" below
```

## Layout

| File | Covers |
|---|---|
| `SecurityTests.swift` | path traversal, size limits, WebSocket frame limits, bind address, HTML escaping, header injection |
| `RobustnessTests.swift` | accept loop, descriptor leaks, idle connections, stop/restart, empty bodies, `NetworkInterface`, malformed requests |
| `HTTPProtocolTests.swift` | behavior of a running server over a raw socket: framing, keep-alive, HEAD, 405, charset, file responses |
| `RequestParsingTests.swift` | request line, query, headers, url-encoded forms, multipart |
| `RouterBehaviorTests.swift` | routing precedence, parameters, mounting, concurrency (complements `HTTPRouterTests.swift`) |
| `WebSocketIntegrationTests.swift` | RFC 6455 handshake and frames against a real server; concurrent writers |
| `HTMLDSLTests.swift` | the NanoHTML builder |
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
**R4** closing a socket while other threads used it (stale reads/writes hit an unrelated socket that had reused the descriptor number; double close) · **R5** the non-atomic server state (also: a failed `start` left the server `starting`, a late accept loop of an earlier run could stop a restarted server) · **R1** the accept loop ended on any `accept()` error, e.g. when out of descriptors (now it backs off and keeps running) · **R2** file descriptors leaked when a response was never written (`String.File` closes itself) · **N1** concurrent NanoHTML rendering aborted the process (rendering is serialized now) · **S2** unbounded request line / header block / `Content-Length` (a single request could abort the process;
now `NanoHTTPParser.Limits`, answers 414/431/413/400) · **S3** WebSocket frame length (the claimed length was
allocated up front; the 64-bit decode had a `<< 54` typo; now a payload/message limit) · **R9** garbage requests
now get `400` instead of a silent close. (After refusing, the connection is closed only once the peer had a
chance to read the answer: closing with unread data made TCP reset the connection and the peer lost the response.)

Confirmed by execution and still open (each is an `expectKnownIssue` or crash test):
S4 invalid listen address binds all interfaces · S5 unescaped file names, attributes, inner text ·
S7 CR/LF header injection · R3 idle
connections starve the server (**between 60 and 70 idle connections**) · R7 IPv6 addresses wrong ·
H1 query values stay percent-encoded · H2 `%2B` → space, `=` in values,
bogus pairs · H3 header parsing · H4 persistent connections, `Connection: close`, chunked bodies ·
H5 JSON failure is 200 · H6 no charset, **reason phrases `no error` / `not found`**, index without
Content-Type · H7 HEAD sends a body, 405 · H9 multipart · H10 file responses disable keep-alive,
directory → empty 200 · W1 interleaved frames · W2 NUL truncation · N3 void elements.

Hypotheses that did **not** reproduce (kept as plain regression tests):
the leak of the listening socket after `stop()` (the port is released, restart on the same port works 25/25) · R6 (empty writes do not crash).

ThreadSanitizer (`swift test --sanitize=thread`) and AddressSanitizer report nothing, and CI enforces both. Earlier,
TSan reported 79-124 races, all in two places that are fixed now: the non-atomic `NanoHTTPServerIO.state` (R5) and the
unsynchronized `shutdown` flag of `NanoSocket.close` (R4). R4 had a practical effect that showed up under TSan's slowdown:
a thread of an earlier test used a file descriptor *number* that a later test had reused, which broke an unrelated
connection. `SocketCloseTests` reproduces such reuse deterministically.

Pinned current behavior that is probably wrong but needs a decision (not marked as an issue):
`/users/:id` also matches `/users` with `id == ""` (H8), see `RouterBehaviorTests`.

## Not covered yet

Performance (R8), Host/Origin validation and CORS (feature gaps, S6), signal handling (S8), the
delegate callback semantics (H11), `NanoHTTPDemo`.

## Keeping the Xcode project in sync

SwiftPM finds files by itself, `NanoHTTP.xcodeproj` does not. Whenever a Swift file is added, removed
or renamed, update the project too (new test files go into the `NanoHTTPTests` target, new files in
`Support/` into its `Support` group). `python3 Scripts/check_xcodeproj.py` verifies that every Swift file
is referenced exactly once; CI runs it.

The same script checks that the project's deployment targets match the platforms declared in
`Package.swift` (project level and the library targets must be equal; the test bundle and the demo apps may be higher), so
raise them in both places together.
