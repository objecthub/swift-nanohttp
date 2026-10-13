# Testing Your Handlers

Test a handler on its own, or the whole server over a real connection.

## Overview

### Call the handler directly

A handler is a function. Create a request and call it:

```swift
let handler: NanoHTTPRequestHandler = { request in
  .ok(.text("Hello, \(request.params["name"] ?? "stranger")!"))
}
let request = NanoHTTPRequest(method: "GET", path: "/hello/Ada")
request.params = ["name": "Ada"]                         // what the router would have set (decoded)
let response = try handler(request)
assert(response.statusCode == 200)
if case .text(let text) = response.body {
  assert(text == "Hello, Ada!")
}
```

A handler that throws a ``NanoHTTPError`` is tested by catching it; the server turns it into a response, which
a test of a running server sees as a status code:

```swift
let handler: NanoHTTPRequestHandler = { request in
  guard request.params["id"] != nil else {
    throw NanoHTTPError.badRequest("No id")
  }
  return .ok(.text("fine"))
}
do {
  _ = try handler(NanoHTTPRequest(method: "GET", path: "/items"))
} catch let error as NanoHTTPError {
  assert(error.status == 400)
  assert(error.response.statusCode == 400)
}
```

This is fast and needs no network. It does not test routing, headers that the server adds, or limits.

### Run a server on a free port

To test everything, start a server on port `0` (the system chooses a free port). A server listens on the loopback
address only unless you configure it otherwise, so tests neither collide with each other nor open your machine to the
network:

```swift
let server = NanoHTTPServer()
server.get["/ping"] = { _ in .ok(.text("pong")) }
try server.start(0)
defer { server.stop() }
let url = URL(string: "http://127.0.0.1:\(try server.port())/ping")!
let (data, response) = try await URLSession.shared.data(from: url)
assert((response as? HTTPURLResponse)?.statusCode == 200)
assert(String(decoding: data, as: UTF8.self) == "pong")
```

Start a new server for each test and stop it at the end (`tearDown`, or `defer`). A stopped server releases its port.

### Tips

- `URLSession` cleans up what it sends (it resolves `..` in paths, retries failed requests and adds headers). To test
  how the server reacts to odd or hostile requests, send the bytes yourself with a socket. The tests of NanoHTTP do
  this with a small client (`RawClient` in `Tests/NanoHTTPTests/Support`), which you can copy.
- Handlers run on other threads than the test. Collect results in thread-safe variables, and wait for them with an
  `XCTestExpectation`.
- Set ``NanoHTTPServerIO/Configuration/limits`` to small values to test how your handlers cope with the answers `413`, `414` and
  `431` of the server.
