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

Some defects abort the whole test process, so they cannot be expected failures. Those tests are
skipped unless `NANOHTTP_CRASH_TESTS=1`. Run them one at a time (the process dies):

| Test | Observed on macOS (Phase 0) |
|---|---|
| `RequestSizeLimitTests/testHugeContentLengthIsRejectedWithoutAllocating` | `Fatal error: failed to allocate 9223372036854775839 bytes` |
| `WebSocketFrameLimitTests/testHugeFrameLengthDoesNotCrash` | `Fatal error: failed to allocate 2305843009213693984 bytes` (length decoded as 2^61: `<< 54` typo) |
| `WebSocketFrameLimitTests/testOneTerabyteFrameLengthFailsCleanly` | passes on plain macOS, aborts under AddressSanitizer |
| `HTMLDSLTests/testConcurrentRenderingDoesNotMixUpRequests` | abort (signal 6) in 3 of 3 runs |

When a defect is fixed, remove the gate from its test.

## Phase 0 results: what the tests established

Fixed since (their tests are plain regression tests now): **S1** path traversal in `share(directory:)` /
`browse(directory:)` (literal `..`, `%2e%2e`, `..%2f`, listing and reading, symlink escape, `%00`).
**H12** (found while adding `followSymlinks`): `Content-Length` of a symlinked file was the length of the link.

Confirmed by execution and still open (each is an `expectKnownIssue` or crash test):
S2 unbounded request line / header block / `Content-Length` · S3 WebSocket frame length ·
S4 invalid listen address binds all interfaces · S5 unescaped file names, attributes, inner text ·
S7 CR/LF header injection · R1 accept loop dies on EMFILE · R2 descriptor leak · R3 idle
connections starve the server (**between 60 and 70 idle connections**) · R7 IPv6 addresses wrong ·
R9 no 400 for garbage · H1 query values stay percent-encoded · H2 `%2B` → space, `=` in values,
bogus pairs · H3 header parsing · H4 persistent connections, `Connection: close`, chunked bodies ·
H5 JSON failure is 200 · H6 no charset, **reason phrases `no error` / `not found`**, index without
Content-Type · H7 HEAD sends a body, 405 · H9 multipart · H10 file responses disable keep-alive,
directory → empty 200 · W1 interleaved frames · W2 NUL truncation · N1 crash · N3 void elements.

Hypotheses that did **not** reproduce (kept as plain regression tests):
R4 (listening socket survives `stop()`; port is released, restart on the same port works 25/25,
keep-alive connections are closed) · R6 (empty writes do not crash).

ThreadSanitizer (`swift test --sanitize=thread`) reports 79 races, all in two places:
`NanoHTTPServerIO.state` getter/setter (76; finding R5) and `NanoSocket.close` (3; the unsynchronized
`shutdown` flag, finding R4). AddressSanitizer reports nothing.

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
`Package.swift` (project level and the library/test targets equal, demo apps equal or higher), so
raise them in both places together.
