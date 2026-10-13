# Security and Limits

What to decide before a server is reachable by others, and what the framework does for you.

## Overview

NanoHTTP is made for servers inside apps and tools that are used by you, your own devices or a small trusted group.
It has **no TLS, no authentication, no rate limiting and no timeouts**. This article lists what you have to decide, and
what the framework guards against.

### 1. Who can connect

By default the server accepts connections on all network interfaces. To serve this machine only, set the address
(`start` throws if it is not an address, instead of listening everywhere):

```swift
let server = NanoHTTPServer()
server.listenAddressIPv4 = "127.0.0.1"
try server.start(8080, forceIPv4: true)
```

Even a server that listens on the loopback address can be reached by every web page that the user opens, because the
browser runs on the same machine. The next two points matter for such servers too.

### 2. Which sites may use it: `Host` and `Origin`

A web page can send requests to `http://localhost:8080` (and open WebSockets to it), and with *DNS rebinding* a
page can make its own domain point to your machine. The server does not look at the `Host` or `Origin` headers; do
that in middleware:

```swift
let server = NanoHTTPServer()
let allowedHosts: Set<String> = ["localhost:8080", "127.0.0.1:8080"]
server.middleware.append { request in
  guard let host = request.header("host")?.lowercased(), allowedHosts.contains(host) else {
    return .forbidden(.text("Unexpected Host header"))
  }
  // Browsers send `Origin` with WebSocket handshakes and with cross-site POSTs.
  if let origin = request.header("origin"), !allowedHosts.contains(where: { origin == "http://\($0)" }) {
    return .forbidden(.text("Unexpected Origin"))
  }
  return nil
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
server.limits = NanoHTTPParser.Limits(maxLineLength: 4 * 1024,
                                      maxHeaderBytes: 16 * 1024,
                                      maxBodyBytes: 1024 * 1024)
```

WebSocket messages are limited by `maxMessageSize` (16 MiB by default), see <doc:WebSockets>.

### 5. What the server does not limit

- **The number of idle connections**: each one occupies a thread, and around 64 of them stop the server from
  answering others (see <doc:ThreadingAndLifecycle>). There are no timeouts for reading a request or for idle
  connections.
- The time a handler takes, and the rate of requests.

For a server that strangers can reach, put a reverse proxy in front of it that provides TLS, timeouts and rate
limits, or use another server.

### 6. Output

- Text that is not under your control and is inserted into HTML must be escaped:
  ``Swift/String/htmlEscaped``. ``NanoHTTPResponse/Body/htmlBody(_:)`` and the `inner` of the HTML builder insert
  their content as it is. `browse` escapes file names itself.
- Values of response headers cannot inject headers: line breaks in them are replaced, and headers with invalid
  names are dropped. Still, validate a redirect target (`.movedTemporarily(location)`) that comes from a request:
  it may point to another site.
- Files: see <doc:ServingFiles>. Files outside the shared directory are not served, and links that lead out of it are
  refused unless you opt in.
- Never use a name from a request (an upload's file name, a route variable) as a file path without checking it.

## Topics

- ``NanoHTTPParser/Limits``
- ``NanoHTTPParserError``
- ``NanoHTTPServerIO/limits``
