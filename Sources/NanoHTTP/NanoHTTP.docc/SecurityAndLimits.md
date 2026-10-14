# Security and Limits

What to decide before a server is reachable by others, and what the framework does for you.

## Overview

NanoHTTP is made for servers inside apps and tools that are used by you, your own devices or a small trusted group.
It has **no TLS, no authentication and no rate limiting**. This article lists what you have to decide, and what the
framework guards against.

### 1. Who can connect

By default the server accepts connections from this machine only (the loopback address `127.0.0.1`). A server that is
meant to be reached from other devices has to say so:

```swift
let server = NanoHTTPServer()
server.configuration.listenAddress = .allInterfaces      // everybody who can reach this machine
try server.start(8080)
```

Or listen at the address of one network interface, `.address("192.168.1.20")`. `start` throws if the address is not an
address of this machine, instead of listening everywhere.

Even a server that listens on the loopback address can be reached by every web page that the user opens, because the
browser runs on the same machine. The next two points matter for such servers too.

### 2. Which sites may use it: `Host` and `Origin`

A web page can send requests to `http://localhost:8080` (and open WebSockets to it), and with *DNS rebinding* a
page can make its own domain point to your machine. The server does not look at the `Host` or `Origin` headers; do
that in middleware:

```swift
let server = NanoHTTPServer()
let allowedHosts: Set<String> = ["localhost:8080", "127.0.0.1:8080"]
server.middleware.append { request, next in
  guard let host = request.header("host")?.lowercased(), allowedHosts.contains(host) else {
    throw NanoHTTPError.forbidden("Unexpected Host header")
  }
  // Browsers send `Origin` with WebSocket handshakes and with cross-site POSTs.
  if let origin = request.header("origin"), !allowedHosts.contains(where: { origin == "http://\($0)" }) {
    throw NanoHTTPError.forbidden("Unexpected Origin")
  }
  return try next(request)
}
```

### 3. Who is it: authentication and encryption

There is no TLS: everybody on the network path can read and change what is sent. For anything secret, terminate TLS
in front of the server (a reverse proxy) or do not use the network. Authentication is yours to do, for example with a
token in a middleware as in <doc:MiddlewareAndExtending>. Compare secrets in constant time if they protect something
valuable.

### 4. Limits on requests

A single request cannot exhaust the memory of the process. Requests are limited, and requests that exceed a limit are
answered and the connection is closed:

| Limit (``NanoHTTPParser/Limits``) | Default | Answer |
|---|---|---|
| `maxLineLength`: request line, header line | 8 KiB | `414 URI Too Long` / `431` |
| `maxHeaderBytes`: request line and all headers | 64 KiB | `431 Request Header Fields Too Large` |
| `maxBodyBytes`: body (`Content-Length`) | 64 MiB | `413 Content Too Large` |

A request that cannot be parsed (an invalid request line, a `Content-Length` that is not a number) is answered with
`400 Bad Request`. Set the limits before starting the server; the body is held in memory, so lower the limit if you
do not expect big uploads:

```swift
let server = NanoHTTPServer()
server.configuration.limits = NanoHTTPParser.Limits(maxLineLength: 4 * 1024,
                                                    maxHeaderBytes: 16 * 1024,
                                                    maxBodyBytes: 1024 * 1024)
```

WebSocket messages are limited by `maxMessageSize` (16 MiB by default), see <doc:WebSockets>.

### 5. Time and the number of connections

Every connection occupies a thread, so connections that do nothing are limited as well
(``NanoHTTPServerIO/Configuration``, see <doc:ThreadingAndLifecycle>):

- `idleTimeout` (60 s): a connection that sends no request is closed.
- `readTimeout` (30 s): a request that stalls half way is answered with `408 Request Timeout`.
- `writeTimeout` (30 s): a peer that does not read its response is dropped.
- `maxConnections` (128): further connections are answered with `503 Service Unavailable`.

```swift
let server = NanoHTTPServer()
server.configuration.idleTimeout = 15
server.configuration.maxConnections = 64
```

The timeouts are pauses, not total times: a client that sends one byte every 29 seconds is not stopped, so this does
not make the server safe against slow-request attacks. What is not limited: the time a handler takes, and the rate of
requests.

For a server that strangers can reach, put a reverse proxy in front of it that provides TLS, timeouts and rate
limits, or use another server.

### 6. Output

- The decoded ``NanoHTTPRequest/path``, the query values and the values of route variables are decoded once, and can
  contain anything: line breaks (`%0A`), NUL characters (`%00`), `..`. Log ``NanoHTTPRequest/rawPath`` instead, and
  never decode the values again: a check that sees `%2e%2e` while the use decodes it to `..` is a way out of a
  directory. See <doc:ReadingRequests>.
- Text that is not under your control and is inserted into HTML must be escaped:
  ``Swift/String/htmlEscaped``. ``NanoHTTPResponse/Body/htmlBody(_:)`` inserts its content as it is. The NanoHTML
  module escapes text and attribute values itself; only `Raw` inserts HTML as it is. `browse` escapes file names itself.
- Values of response headers cannot inject headers: line breaks in them are replaced, and headers with invalid
  names are dropped. Still, validate a redirect target (`.movedTemporarily(location)`) that comes from a request:
  it may point to another site.
- Files: see <doc:ServingFiles>. Files outside the shared directory are not served, and links that lead out of it are
  refused unless you opt in.
- Never use a name from a request (an upload's file name, a route variable) as a file path without checking it.

## Topics

- ``NanoHTTPParser/Limits``
- ``NanoHTTPParserError``
- ``NanoHTTPServerIO/Configuration``
