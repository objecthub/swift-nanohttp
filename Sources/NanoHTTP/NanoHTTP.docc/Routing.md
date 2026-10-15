# Routing

Match the method and path of a request to a handler, and capture parts of the path.

## Overview

Handlers are registered with the method of the request and a *route*: a path pattern.

```swift
let server = NanoHTTPServer()
server.get["/about"] = { _ in .ok(.text("About")) }                       // a fixed path
server.get["/users/:id"] = { request in .ok(.text(request.params["id"] ?? "")) }
server.get["/files/::path"] = { request in .ok(.text(request.params["path"] ?? "")) }
server.get["/a/*/c"] = { _ in .ok(.text("anything in the middle")) }
server.get["/docs/**"] = { _ in .ok(.text("anything below /docs")) }
server.post["/items"] = { _ in .created() }
server.delete["/items/:id"] = { _ in .ok(.empty) }
server["/status", "/health"] = { _ in .ok(.text("ok")) }                  // every method, two paths
```

`server.get`, `post`, `put`, `patch`, `delete`, `head` and `options` register for one method (``NanoHTTPServer/MethodRoute``);
`server[...]` registers for every method. A handler for a specific method wins over one for every method.
Assigning `nil` removes a registration. A HEAD request is answered by a handler registered for HEAD, else by the
handler of a GET route (without the body), else by one for every method. A request with a method that a path does not
have gets `405` and the methods that it has, and `OPTIONS` requests list them, see <doc:HandlersAndResponses>;
`server.options[...]` registers handlers for `OPTIONS`.

### Patterns

| In the route | Matches | Value |
|---|---|---|
| `about` | the segment `about` | |
| `:id` | exactly one segment | `request.params["id"]`, percent-decoded; `request.rawParams["id"]`, as sent |
| `::path` | any number of segments, also none | `request.params["path"]`, the percent-decoded segments joined by `/`; `request.rawParams["path"]`, the segments as sent, joined by `/` |
| `*` | exactly one segment | |
| `**` | any number of segments, also none | |

Paths are split at `/`. Empty segments are ignored, so `/a//b/` matches the route `/a/b`, and the query
(`?x=1`) is not part of the path.

### Which route wins

Fixed segments are tried before variables, and the search backtracks: with the routes `/a/b/c` and
`/a/:x/d`, the request `/a/b/d` first follows the fixed `b`, finds no `d` after it, and then tries the
variable. Two variable routes that could both match the same request (`/a/:x` and `/a/*`) are tried in the order in
which they were registered, the first one that matches wins. Avoid such overlaps all the same: they are hard to read.

### Percent-encoding

The router matches the path as the client sent it (``NanoHTTPRequest/rawPath``): the path is split at `/` first, and
then every segment is decoded before it is compared with a fixed segment or becomes the value of a variable. An encoded
slash therefore stays inside its segment:

```text
GET /users/J%C3%BCrgen%20M     params["id"]   == "Jürgen M"
GET /files/a/b%20c.txt         params["path"] == "a/b c.txt"
GET /files/a%2Fb               params["path"] == "a/b"        (one segment, which contains a slash)
GET /a%2Fb                     does not match the route /a/b  (but does match /:x, with x == "a/b")
```

All values are decoded once, also those of path variables: do not decode them again (see <doc:ReadingRequests>).
A segment that is not valid percent-encoding (`%zz`, or bytes that are no UTF-8) does not match anything.

### The values as the client sent them

A decoded value cannot tell `a%2Fb/c` from `a/b/c`: both are `a/b/c`. ``NanoHTTPRequest/rawParams`` has the same
variables with their values as the client sent them, still percent-encoded and not decoded at all (a `+` stays a `+`):
a variable `:name` gets its segment, and a path variable `::name` its segments joined by `/`. Use it where the
difference matters, for example to pass a path on to another service in the form that the client sent it.

```swift
let server = NanoHTTPServer()
server.get["/files/::path"] = { request in
  let decoded = request.params["path"] ?? ""     // "a/b/c" for GET /files/a%2Fb/c
  let raw = request.rawParams["path"] ?? ""      // "a%2Fb/c"
  return .ok(.text("\(decoded) was sent as \(raw)"))
}
```

```text
GET /users/caf%C3%A9         params["id"]   == "café"        rawParams["id"]   == "caf%C3%A9"
GET /users/a%2Fb             params["id"]   == "a/b"         rawParams["id"]   == "a%2Fb"
GET /users/%252e%252e        params["id"]   == "%2e%2e"      rawParams["id"]   == "%252e%252e"
GET /files/caf%C3%A9/x%20y   params["path"] == "café/x y"    rawParams["path"] == "caf%C3%A9/x%20y"
GET /files                   params["path"] == ""            rawParams["path"] == ""
```

The names are those of ``NanoHTTPRequest/params``: the anonymous `*` and `**` have no entry in either. As there, empty
segments are left out, a path variable that matches no segment has the value `""`, and the query is not part of a
value. The raw value is that of the segments that the route matched, also where the search backtracks
(`/files/::path/edit`). Like ``NanoHTTPRequest/params``, ``NanoHTTPRequest/rawParams`` is known in the handler, and in
middleware after `next` has returned; a `HEAD` request answered by the route for `GET` has both.

A raw value is untrusted input, too: decode it at most once, and do not use it as a file path without checking it
(see <doc:ReadingRequests>). A router that does not offer raw values (see <doc:MiddlewareAndExtending>) leaves
``NanoHTTPRequest/rawParams`` empty, and so does a request that you create yourself in a test.

### A variable at the end of a route

A `:variable` or `*` needs its segment: with only the route `/users/:id`, the request `/users` matches nothing, and is
answered like any other unknown path (`404`, or the `405` that tells which methods the path has). Only the path variables
`::name` and `**` can stand for nothing: `/files/::path` answers `/files`, with `params["path"] == ""`. (In
1.x a variable at the end of a route matched a missing segment too, with the empty string; see `MIGRATION-2.0.md`.)

### Groups of routes

A group of routes can be built on its own and mounted below a prefix. The routes are copied when they are
mounted:

```swift
let api = NanoHTTPSegmentRouter()
api.register("GET", path: "/items/:id") { request in
  .ok(.text("item \(request.params["id"] ?? "")"))
}
let server = NanoHTTPServer()
try server.use("/api/v1", router: api)          // GET /api/v1/items/7
```

### Unknown paths

A request that matches no route is passed to ``NanoHTTPServer/notFoundHandler``; without one the server answers
`404 Not Found` with an empty body. A request for a known path with another method is answered the same way,
with `404`, not with `405`.

```swift
let server = NanoHTTPServer()
server.notFoundHandler = { request in
  .notFound(.text("There is nothing at \(request.path)"))
}
```

``NanoHTTPServer/routes`` lists the registered patterns, which is handy for an index page.

## Topics

- ``NanoHTTPServer``
- ``NanoHTTPServer/MethodRoute``
- ``NanoHTTPSegmentRouter``
- ``NanoHTTPRouter``
