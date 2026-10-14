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
browser runs on the same machine. The next point matters for such servers too.

### 2. Which sites may use it: `Host` and `Origin`

A web page can send requests to `http://localhost:8080` (and open WebSockets to it). Two attacks use that:

- **DNS rebinding:** the page's own domain is made to point to `127.0.0.1`. The browser then treats your server as part of
  the page's site and lets the page read every answer, with the domain of the attacker in the `Host` header.
- **Requests of other sites:** a page makes the browser send a form, a `fetch` or a WebSocket handshake to your server;
  the request carries the `Origin` of the page. A server that changes something when it is asked to (a `POST` that
  deletes a file) does so for any page the user has open.

The server can refuse both. The checks are **off by default**, so that nothing changes for servers that are reached under other
names, and you switch them on in the configuration:

```swift
let server = NanoHTTPServer()
server.configuration.hostPolicy = .automatic       // only localhost, 127.0.0.1 and [::1] (a server on the loopback address)
server.configuration.originPolicy = .sameOrigin    // pages of the server itself, not the pages of other sites
try server.start(8080)
```

- ``NanoHTTPServerIO/Configuration/HostPolicy/automatic`` accepts the names of the loopback address (`localhost`,
  `127.0.0.1`, `[::1]`, at any port, so that a tunnel works) when the server listens only there, and every name when it
  listens at other addresses, because it cannot know the names under which it is reached. For those servers use
  ``NanoHTTPServerIO/Configuration/HostPolicy/hosts(_:)``: `.hosts(["mac.local", "192.168.1.20:8080"])`; an entry without a
  port accepts every port.
- ``NanoHTTPServerIO/Configuration/OriginPolicy/sameOrigin`` looks at the requests that change something (everything but
  `GET`, `HEAD` and `OPTIONS`) and at WebSocket handshakes: when such a request has an `Origin` header, the origin has to be the
  address that the request was sent to. Requests without an `Origin` (`curl`, apps, other tools) are served, and so are the
  reads of pages of other sites: the browser keeps those pages from reading the answer, unless you allow it with CORS (below).
  ``NanoHTTPServerIO/Configuration/OriginPolicy/origins(_:)`` adds the pages of other origins that you trust:
  `.origins(["https://app.example", "http://localhost:3000"])`.
- A request that is refused is answered with `403 Forbidden` before the middleware sees it, and logged as a warning with
  the offending header. A request without a `Host` (HTTP/1.0) is served.

The same checks exist as middleware, for the parts of a server that need other rules than the rest: ``NanoMiddleware/hostAllowlist(_:)``
and ``NanoMiddleware/originAllowlist(_:)``.

**Sites that may use the server:** if a page of another site is meant to talk to your server, the browser has to be told so:
add ``NanoMiddleware/cors(_:)``, which answers the preflight requests of browsers and adds the headers that give the page access.
CORS decides what a page may *read*; it does not keep the request from reaching your server, which is what the `originPolicy`
is for. List the same origins in both:

```swift
let server = NanoHTTPServer()
let trusted = ["https://app.example", "http://localhost:3000"]
server.configuration.originPolicy = .origins(trusted)
server.middleware.append(NanoMiddleware.cors(NanoCORSPolicy(allowedOrigins: trusted)))
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
