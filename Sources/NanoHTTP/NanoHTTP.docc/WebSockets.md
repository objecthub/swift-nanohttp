# WebSockets

Exchange messages with browsers and apps over a connection that stays open.

## Overview

``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:)`` creates a handler that upgrades a request
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
interleave. This makes broadcasting simple: keep the sessions of the connected clients, protect the collection with a
lock, and write to all of them:

```swift
// file scope
final class ExampleChatRoom {
  private let lock = NSLock()
  private var sessions = Set<NanoWebSocketSession>()

  func join(_ session: NanoWebSocketSession) {
    lock.lock(); sessions.insert(session); lock.unlock()
  }

  func leave(_ session: NanoWebSocketSession) {
    lock.lock(); sessions.remove(session); lock.unlock()
  }

  func broadcast(_ message: String) {
    lock.lock(); let all = sessions; lock.unlock()
    for session in all { session.writeText(message) }
  }
}
```

```swift
let chat = ExampleChatRoom()
let server = NanoHTTPServer()
server["/chat"] = NanoWebSocket.handler(
  text: { _, message in chat.broadcast(message) },
  connected: { session in chat.join(session) },
  disconnected: { session in chat.leave(session) })
```

Always remove a session in `disconnected`. Writing to a session whose connection has ended does nothing harmful (it
is logged at the level ``NanoLogLevel/info``), but a collection that keeps such sessions grows forever.

### On a server with one thread

A server that runs on one thread (``NanoHTTPServerIO/Configuration/Threading/singleThread``) serves WebSockets on that
thread as well: it waits for all sockets together, and handles the messages of the sessions one at a time between the
requests of the other connections. A session does not hold the thread while it waits for the next message. The
closures of all sessions, the handlers and the middleware therefore never run at the same time, and the collection
of sessions needs **no lock**, also when HTTP handlers write to the sessions:

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
  sessions.forEach { $0.writeText(message) }  // an HTTP handler can send to the sessions, too
  return .ok(.text("sent to \(sessions.count) clients"))
}
```

What the one thread cannot do is more than one thing at a time: a closure that takes a second delays all other
messages and requests by a second, and a client that sends the beginning of a message and then stops delays the server
until the ``NanoHTTPServerIO/Configuration/readTimeout`` has passed, after which its session is closed. Sessions are not
subject to the idle timeout, but they count towards ``NanoHTTPServerIO/Configuration/maxConnections``.

### Messages and limits

- Messages may arrive in several frames; the closures receive complete messages. Text must be valid UTF-8.
- A message (or a single frame) larger than `maxMessageSize` (16 MiB unless you pass another value) ends the
  connection with close code 1009.
- Violations of the protocol (unmasked frames, unknown operation codes, control frames above 125 bytes, invalid
  close codes) end it with 1002; text that is not UTF-8 with 1007. When the client closes, the server answers with the
  code of the client.
- The handshake must be a `GET` request with `Sec-WebSocket-Version: 13`; other versions get `426 Upgrade Required`.
  Subprotocols and extensions (compression) are not negotiated.

### Security

A web page in any browser tab can open a WebSocket to a server that is reachable from the browser, including one on the
user's own machine or network, and use it with the privileges of the user. By default the handshake does not look at the
`Origin` header, which a browser sends with it. Servers that are not meant for such pages switch on the origin check:
`server.configuration.originPolicy = .sameOrigin` refuses handshakes of pages of other sites (and lists the origins that
are allowed with `.origins([...])`); see <doc:SecurityAndLimits>.

## Topics

- ``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:)``
- ``NanoWebSocketSession``
- ``NanoWebSocketSession/CloseCode``
- ``NanoWebSocketSession/WsError``
