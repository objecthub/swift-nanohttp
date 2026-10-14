# Architecture

How NanoHTTP is put together, for people who change it. (How to *use* it is in the DocC documentation; the article *How
a Request Is Served* follows one request through the same machinery, from the user's side.)

## What is in the package

| Product / target | What it is |
|---|---|
| `NanoHTTP` | The server: sockets, threads, the HTTP parser and serializer, routing, middleware, files, WebSockets, cookies, logging. No dependencies. |
| `NanoHTML` | A second library: pages built from Swift values, escaped by default. Depends on `NanoHTTP` (for `htmlHandler` and `NanoHTTPResponse.html`). |
| `NanoHTTPDemo`, `DemoServer` | The kitchen sink: a demo server that uses most features (command-line tool, and an iOS app in the Xcode project). |
| `Examples/` | Six small programs (`swift run ExampleHello`, ...), checked by `Scripts/check_examples.py`. Swift package targets only. |

The package keeps to what the code has always used: `Thread`, GCD, `NSLock`, `os_unfair_lock` and plain classes. There is
no `async`/`await`, no `Sendable` annotation and no actor, and the package builds in Swift 5 language mode. Apple
platforms only (macOS 12, iOS 15, tvOS 15).

## The layers

```text
          your code: handlers, middleware, NanoHTTPServer subclasses
 ───────────────────────────────────────────────────────────────────────────────
  NanoHTTPServer          routing (NanoHTTPSegmentRouter), middleware chain, errorHandler, notFoundHandler
  NanoHTTPServerIO        the server proper: listening socket, accept loop, threads, limits, timeouts, state
  NanoHTTPConnection      one request with its handler: response() runs it, send(_:) writes the answer
  NanoHTTPParser          bytes ──► NanoHTTPRequest (limits, chunked bodies, Expect)
  NanoHTTPResponseSerializer, NanoHTTPBodyWriters       NanoHTTPResponse ──► bytes (head, framing, cookies)
  NanoSocket              the file descriptor: buffered reads, writes, timeouts, close, sendfile
```

* **`NanoSocket`** wraps a descriptor and can be used from several threads: `close()` can be called while others
  read or write (they fail or return, and the descriptor number is not reused while any of them runs), and operations on
  a closed socket throw. Reads go through a 16 KB buffer; `hasBufferedData` tells a loop that data has been read ahead.
* **`NanoHTTPParser`** reads exactly as much as its `Limits` allow and turns everything else into a
  `NanoHTTPParserError`, which the server answers (`400`, `413`, `414`, `431`, `501`, `505`) before it closes the connection.
* **`NanoHTTPServerIO`** knows nothing about routes: `dispatch(request:)` returns the handler (a subclass decides; the
  implementation of `NanoHTTPServer` runs the middleware and the router), and `handle(connection:)` drives a connection.
* **`NanoHTTPConnection`** is a value: the parser (and so the socket), the request that was read, the handler chosen for
  it and the configuration of the run. `response()` checks the Host and Origin policies, calls the handler and turns errors
  into responses. `send(_:dontKeepAlive:)` writes the response, and, with threads per connection, waits for and reads the
  next request, which it returns as the next connection.

## Two ways to run: threads per connection, or one thread

`Configuration.threading` decides who does the work. Both modes serve the same requests with the same code above;
only the loop around it differs.

```text
 .perConnection (default)                      .singleThread
 ───────────────────────                       ──────────────
 accept thread                                 the one thread (`start` makes one, `run` is the calling thread):
   accept ──► admit (maxConnections?)            poll(listening socket, wake-up pipe, every waiting connection)
   ──► NanoThreadPool.submit {                     ├ listening socket readable ──► accept, admit, add to `waiting`
         server.handle(connection)                 ├ a connection readable ──► serve(socket): read one request,
         // the default handle loops:              │      handle(connection:), the response is written here
         //   connection.send(response)            │      then the connection goes back to `waiting`
         //   ──► waits for the next request       ├ a session readable ──► session.receive()
       }                                           └ idle connections are closed at their deadline
 the pool reuses threads (10 s idle, 32 kept)
```

* With one thread, **handlers, middleware, WebSocket closures and the loop never run at the same time**, so code that
  runs in them needs no locks. The price is that anything that blocks the thread blocks the server (`Configuration.threading`
  documents the limits). `Examples/Status` shows a server of this kind, and the thread sanitizer checks it.
* With threads per connection, handlers of different connections run at the same time and must protect what they share.
  A slow handler delays only its own connection.

### Sessions

A response can turn a connection over to a `NanoSocketSession` (`switchProtocols(_:session:)`): that is how WebSockets
work. With threads per connection the thread of the connection waits for the socket (`awaitData`) and calls
`session.receive()`. With one thread the loop polls the session's socket together with everything else (`adopt(session:on:)`),
so any number of WebSockets cost no thread. `NanoWebSocketHub` keeps sessions that belong together and is safe from any thread.

### Deferred responses

An override of `handle(connection:)` can answer later, from any thread: `connection.deferResponse()` returns a
`NanoHTTPDeferredResponse`, and `handle` returns without answering. The connection stays registered with the server but is
**not read and has no timer**. When the owner calls `send`, the server writes the answer itself:

* threads per connection: the answer is submitted to the pool; a pool thread calls `connection.send` (which writes it and
  reads the next request) and then `handle(connection:)` for that request;
* one thread: the answer is queued, a byte is written to the **wake-up pipe** (created on the first deferral of a run;
  slot 1 of the `pollfd` array), and the loop writes the answer and goes back to waiting for the next request.

So sockets are only ever touched by the server's threads, the sender never waits for a slow client, and a token that is
released without an answer closes the connection (and logs a warning).

## State, threads and locks

| What | Guarded by | Notes |
|---|---|---|
| Server state (`stopped` / `starting` / `running` / `stopping`), the listening socket, the active configuration, the pool | `stateLock` (`os_unfair_lock`) | `stop()` and the accept loop of an earlier run are told apart by the listening socket of the run (`shutDown(run:)`). |
| The set of open sockets (`openConnections`, `stop()` closes them) | `lock` (`NSLock`) | `remember(socket:)` / `forget(socket:)`. |
| Answers waiting for the loop of a one-thread server, the wake-up pipe | `completionLock` | Written by any thread, read by the loop. |
| The router | a lock to register routes; matching runs on an **immutable frozen copy** of the tree | Matching takes no lock. |
| `NanoSocket` | an `NSCondition` for `closed` and the count of running operations | `close()` waits (up to 2 s) for operations that run. |
| A WebSocket session's writes | a lock per session | Frames of different threads never interleave. |
| `NanoWebSocketHub` | a lock | |
| `NanoHTTPRequest` | nothing | One request is used by one thread at a time (handing it to a worker thread is fine, using it from two is not). |

The configuration is copied when a server starts (`activeConfiguration`): changing `server.configuration` of a running
server affects the next run, and connections read the copy once instead of locking.

## Design decisions that are easy to undo by accident

* **Loopback by default** (`127.0.0.1`), and the Host/Origin policies exist but are **off by default**. Behavior
  that a user did not ask for stays as it was.
* **Limits and timeouts are on by default** (`NanoHTTPParser.Limits`, idle/read/write timeouts, `maxConnections`): a
  single request cannot exhaust the process, and a silent connection cannot hold a thread for ever.
* **Strict parsing, lenient where it is safe.** Ambiguous framing (`Content-Length` with chunks) is refused; request
  values (`path`, query, route variables, cookies) are **decoded exactly once**, which is why code must not decode them again.
  A multipart body that is not well-formed gives no parts at all.
* **Everything a response writes is sanitized at the last moment** (`NanoHTTPResponseSerializer`): header names must be
  tokens, line breaks in values become spaces, and a cookie that could add attributes is dropped and logged.
* **Errors become responses in one place.** A handler throws; `NanoHTTPServerIO.response(for:to:)` decides (a
  `NanoHTTPError` is answered as it says, everything else is a `500` without details, which are logged).
* **The server reports through a logger** (`NanoHTTPLogger`, messages are built lazily); nothing is printed.
* **NanoHTML has no global state**: pages are values, text and attributes are escaped, and `Raw` is the only way around that.
* **Performance is a requirement**, measured against 1.0.2 with `Benchmarks/run.py` (paired runs; see `Benchmarks/README.md`).
  What matters on the request path: reads in blocks, head and small bodies written in one call, `TCP_NODELAY`,
  nothing allocated that is not needed. Changes there are benchmarked, in both threading modes.

## Where things are

| File | Responsibility |
|---|---|
| `NanoHTTPServerIO.swift` | `Configuration`, start/stop/run, the accept loop, the one-thread loop, deferred-response hand-over, logging entry points |
| `NanoHTTPServer.swift` | routes (`get`, `post`, ...), middleware, `errorHandler`, `notFoundHandler`, `dispatch` |
| `NanoHTTPConnection.swift` | `response()`, `send(_:)`, reading the next request, refusing bad requests |
| `NanoHTTPDeferredResponse.swift` | `deferResponse()` and its token |
| `NanoHTTPParser.swift` | reading requests, `Limits`, chunked bodies, `Expect` |
| `NanoHTTPRequest.swift`, `NanoHTTPMultipart.swift`, `NanoHTTPCookie.swift` | the request (headers, query, forms, JSON, cookies); multipart bodies; cookies in both directions |
| `NanoHTTPResponse.swift`, `NanoHTTPResponseSerializer.swift`, `NanoHTTPBodyWriters.swift`, `NanoHTTPResponseBodyWriter.swift` | responses and their helpers; the head, framing and dates; chunked and length-limited bodies |
| `NanoHTTPRouter.swift`, `NanoHTTPSegmentRouter.swift` | the router protocol and the default router (segments with `:var`, `::path`, `*`, `**`) |
| `NanoMiddleware.swift`, `NanoRequestPolicy.swift`, `NanoHTTPError.swift` | CORS and the allowlists; the Host/Origin matcher; errors with a status |
| `NanoFiles.swift`, `NanoFile.swift` | sharing and browsing directories (ranges, `ETag`, `304`); file handles |
| `NanoWebSockets.swift`, `NanoWebSocketHub.swift`, `NanoSocketSession.swift` | WebSocket handler and session, the hub, the session protocol |
| `NanoSocket.swift`, `NanoSocketError.swift`, `NanoThreadPool.swift`, `NanoNetworkInterface.swift`, `NanoProcess.swift`, `NanoLogger.swift` | sockets, the thread pool, network interfaces, signal handling, loggers |
| `Renamed.swift`, `String+Extensions.swift` | unavailable declarations for names that 2.0 renamed; string helpers |
| `Sources/NanoHTML/` | `HTMLNode`, `HTMLElement` and the element table, attribute modifiers, `htmlHandler` |

## How it is checked

* `swift test`, also with `--sanitize=address` and `--sanitize=thread` (see `Tests/README.md` for the layout): the tests start
  servers on free loopback ports and talk to them with a raw-socket client, so that the exact bytes are tested. Every
  feature has a test in both threading modes. There is no CI: these are run by hand before every commit (CONTRIBUTING.md).
* `Scripts/check_xcodeproj.py` (the hand-maintained Xcode project lists every Swift file), `check_doc_examples.py` (every
  example in the documentation compiles), `check_docs.py` (DocC builds without warnings), `check_examples.py` (the
  programs in `Examples/` run and stop on `SIGTERM`).
* `Benchmarks/run.py`: throughput, latency and CPU per request against a release, with paired runs, in both modes.
