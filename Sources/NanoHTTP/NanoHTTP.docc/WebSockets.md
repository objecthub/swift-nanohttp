# WebSockets

Exchange messages with browsers and apps over a connection that stays open.

## Overview

``websocket(text:binary:pong:connected:disconnected:maxMessageSize:)`` creates a handler that upgrades a request
to a WebSocket connection (RFC 6455) and calls closures for what happens on it. Register it like any other handler:

```swift
let server = NanoHTTPServer()
server["/echo"] = websocket(
  text: { session, text in session.writeText(text) },
  binary: { session, bytes in session.writeBinary(bytes) })
```

Each closure receives the ``WebSocketSession`` of the connection. A session sends text with
``WebSocketSession/writeText(_:)`` and binary data with ``WebSocketSession/writeBinary(_:)-([UInt8])``. Pings are answered
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
  private var sessions = Set<WebSocketSession>()

  func join(_ session: WebSocketSession) {
    lock.lock(); sessions.insert(session); lock.unlock()
  }

  func leave(_ session: WebSocketSession) {
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
server["/chat"] = websocket(
  text: { _, message in chat.broadcast(message) },
  connected: { session in chat.join(session) },
  disconnected: { session in chat.leave(session) })
```

Always remove a session in `disconnected`. Writing to a session whose connection has ended does nothing harmful (it
logs an error), but a collection that keeps such sessions grows forever.

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

The handshake does not look at the `Origin` header. A web page in any browser tab can open a WebSocket to a server
that is reachable from the browser, including one on the user's own machine or network, and use it with the
privileges of the user. Servers that are not meant for such pages should check the origin; see
<doc:SecurityAndLimits>.

## Topics

- ``websocket(text:binary:pong:connected:disconnected:maxMessageSize:)``
- ``WebSocketSession``
- ``WebSocketSession/CloseCode``
- ``WebSocketSession/WsError``
