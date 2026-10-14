# ``NanoHTTP``

A small HTTP/1.1 server for apps and tools: routing, files, forms, uploads and WebSockets, without dependencies.

## Overview

NanoHTTP runs a web server inside your process: a command-line tool, a Mac app or an iOS app. You register
functions for methods and paths, and the framework takes care of sockets, threads and the protocol.

```swift
let server = NanoHTTPServer()
server.get["/hello/:name"] = { request in
  .ok(.text("Hello, \(request.params["name"] ?? "stranger")!"))
}
try server.start(8080)
```

Pages are built with the companion library NanoHTML (a second product of the package), which escapes text for you.

It is meant for servers that are used by you, your own devices or a small trusted group: tools, local
user interfaces, companion apps, test servers. It does not provide TLS, authentication or protection against
many hostile clients; <doc:SecurityAndLimits> says what to take care of.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Routing>
- <doc:HandlersAndResponses>
- <doc:ReadingRequests>

### Running a server

- ``NanoHTTPServer``
- ``NanoHTTPServerIO``
- ``NanoHTTPServerDelegate``
- <doc:ThreadingAndLifecycle>
- <doc:MiddlewareAndExtending>
- <doc:HowARequestIsServed>

### Requests and responses

- ``NanoHTTPRequest``
- ``NanoHTTPResponse``
- ``NanoHTTPRequestHandler``
- ``NanoHTTPMiddleware``
- ``NanoHTTPError``
- ``NanoHTTPResponseBodyWriter``
- ``NanoHTTPParser``
- ``NanoHTTPParserError``

### Routing

- ``NanoHTTPSegmentRouter``
- ``NanoHTTPRouter``
- ``NanoHTTPRouterError``

### Files

- <doc:ServingFiles>
- ``NanoFiles``
- ``NanoFiles/share(file:)``
- ``NanoFiles/share(directory:defaults:followSymlinks:)``
- ``NanoFiles/browse(directory:followSymlinks:)``
- ``NanoFile``

### WebSockets

- <doc:WebSockets>
- ``NanoWebSocket``
- ``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:)``
- ``NanoWebSocketSession``
- ``NanoSocketSession``

### Security

- <doc:SecurityAndLimits>

### Platforms and testing

- <doc:UsingNanoHTTPOnIOS>
- <doc:TestingYourHandlers>

### Sockets and utilities

- ``NanoSocket``
- ``NanoSocketError``
- ``NanoNetworkInterface``
- ``NanoProcess``
