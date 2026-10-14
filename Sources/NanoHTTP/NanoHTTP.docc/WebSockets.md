# WebSockets

Exchange messages with browsers and apps over a connection that stays open.

## Overview

``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:origins:protocols:hub:)`` creates a handler that upgrades a request
to a WebSocket connection (RFC 6455) and calls closures for what happens on it. Register it like any other handler:

```swift
let server = NanoHTTPServer()
server["/echo"] = NanoWebSocket.handler(
  text: { session, text in session.writeText(text) },
  binary: { session, bytes in session.writeBinary(bytes) })
```

Each closure receives the ``NanoWebSocketSession`` of the connection. A session sends text with
``NanoWebSocketSession/writeText(_:)`` and binary data with ``NanoWebSocketSession/writeBinary(_:)-([UInt8])``. Pings are answered
automatically; the `pong` closure sees the pongs that the client sends.

From a page, the server of the example is reached with:

```javascript
const socket = new WebSocket("ws://localhost:8080/echo");
socket.onmessage = event => console.log(event.data);
socket.onopen = () => socket.send("hello");
```

### Threads

Every connection runs on a thread of its own, and the closures of one connection are called one after another, on
that thread. A closure that blocks delays the messages of its own connection only.

Sessions may be written from **any thread** at any time: concurrent writes are serialized, so frames never
interleave.

### Sending to many sessions: the hub

A ``NanoWebSocketHub`` keeps the sessions that belong together, a chat for example, and sends a message to all of them.
Give it to the handler: the sessions join when they are connected and leave when their connections have ended.

```swift
let server = NanoHTTPServer()
let chat = NanoWebSocketHub()
server["/chat"] = NanoWebSocket.handler(
  text: { session, message in chat.broadcast(text: message, except: session) },   // to everybody else
  hub: chat)
server.post["/announce"] = { request in
  chat.broadcast(text: request.bodyString ?? "")      // an HTTP handler can send to the sessions, too
  return .ok(.text("sent to \(chat.count) clients"))
}
```

The hub is thread-safe: use it from the closures, from handlers and from any thread, without a lock of your own.
``NanoWebSocketHub/sessions`` is the list of the sessions at this moment, and ``NanoWebSocketHub/broadcast(binary:except:)``
sends binary messages. A hub writes to the sessions one after the other. A client that stops reading would hold up the
ones behind it, so a write that makes no progress for ``NanoHTTPServerIO/Configuration/sessionWriteTimeout`` (5 seconds
by default) ends that session: its connection is closed, and it leaves the hub. If you need something that the hub does not
offer (rooms, users), keep your own collections: sessions are `Hashable`, and a session that has ended must be removed
in `disconnected`.

Writing to a session whose connection has ended does nothing harmful (the first failed write is logged at the level
``NanoLogLevel/info``).

### On a server with one thread

A server that runs on one thread (``NanoHTTPServerIO/Configuration/Threading/singleThread``) serves WebSockets on that
thread as well: it waits for all sockets together, and handles the messages of the sessions one at a time between the
requests of the other connections. A session does not hold the thread while it waits for the next message. The
closures of all sessions, the handlers and the middleware therefore never run at the same time, so the code above
works unchanged, and a collection of your own needs **no lock**, also when HTTP handlers write to the sessions:

```swift
let server = NanoHTTPServer()
server.configuration.threading = .singleThread
var sessions = [NanoWebSocketSession]()           // used by all closures and handlers: they all run on one thread
server["/chat"] = NanoWebSocket.handler(
  text: { _, message in sessions.forEach { $0.writeText(message) } },
  connected: { session in sessions.append(session) },
  disconnected: { session in sessions.removeAll { $0 === session } })
server.post["/announce"] = { request in
  let message = String(decoding: request.body, as: UTF8.self)
  sessions.forEach { $0.writeText(message) }
  return .ok(.text("sent to \(sessions.count) clients"))
}
```

What the one thread cannot do is more than one thing at a time: a closure that takes a second delays all other
messages and requests by a second, and a client that sends the beginning of a message and then stops delays the server
until the ``NanoHTTPServerIO/Configuration/readTimeout`` has passed, after which its session is closed. The same is true
for a client that does not read what is sent to it, for ``NanoHTTPServerIO/Configuration/sessionWriteTimeout``. Sessions
are not subject to the idle timeout, but they count towards ``NanoHTTPServerIO/Configuration/maxConnections``.

### Messages and limits

- Messages may arrive in several frames; the closures receive complete messages. Text must be valid UTF-8.
- A message (or a single frame) larger than `maxMessageSize` (16 MiB unless you pass another value) ends the
  connection with close code 1009.
- Violations of the protocol (unmasked frames, unknown operation codes, control frames above 125 bytes, invalid
  close codes) end it with 1002; text that is not UTF-8 with 1007. When the client closes, the server answers with the
  code of the client.
- The handshake must be a `GET` request with `Sec-WebSocket-Version: 13`; other versions get `426 Upgrade Required`.
  Extensions (compression) are not negotiated; subprotocols are, see below.
- A write that fails ends the session, because a frame that was written in part would make the client misread all that
  follows.

### Subprotocols

A page can say which protocols it speaks on top of WebSocket: `new WebSocket(url, ["chat.v2", "chat.v1"])`. Give the handler
the ones that it speaks, in the order that it prefers them:

```swift
let server = NanoHTTPServer()
server["/chat"] = NanoWebSocket.handler(
  connected: { session in
    // session.subprotocol is "chat.v2" or "chat.v1"
  },
  protocols: ["chat.v2", "chat.v1"])
```

The handler answers with the first of its protocols that the client offers. A client that offers protocols of which the
handler knows none is refused with `400 Bad Request` (a browser would not accept an answer without a protocol anyway), and
a client that offers none is accepted without a protocol: ``NanoWebSocketSession/subprotocol`` is `nil`. Without `protocols`
the handler ignores what the client offers. The names are compared as they are written, upper and lower case differ.

### Security

A web page in any browser tab can open a WebSocket to a server that is reachable from the browser, including one on the
user's own machine or network, and use it with the privileges of the user. By default the handshake does not look at the
`Origin` header, which a browser sends with it. Servers that are not meant for such pages switch on the origin check:
`server.configuration.originPolicy = .sameOrigin` refuses handshakes of pages of other sites (and lists the origins that
are allowed with `.origins([...])`), for every route; see <doc:SecurityAndLimits>.

To protect one WebSocket on a server whose other routes are open to other sites, give its handler the `origins`:

```swift
let server = NanoHTTPServer()
server["/chat"] = NanoWebSocket.handler(
  text: { session, message in session.writeText(message) },
  origins: .origins(["https://app.example"]))       // pages of the server itself, and of this site
```

A handshake from a page of another site is answered with `403 Forbidden`. Clients that are no browsers send no `Origin`
and are served.

## Topics

- ``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:origins:protocols:hub:)``
- ``NanoWebSocketHub``
- ``NanoWebSocketSession``
- ``NanoWebSocketSession/CloseCode``
- ``NanoWebSocketSession/WsError``
