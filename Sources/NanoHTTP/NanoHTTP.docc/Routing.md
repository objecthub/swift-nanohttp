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

`server.get`, `post`, `put`, `patch`, `delete` and `head` register for one method (``NanoHTTPServer/MethodRoute``);
`server[...]` registers for every method. A handler for a specific method wins over one for every method.
Assigning `nil` removes a registration. A HEAD request is only answered by a handler registered for HEAD or for
every method, not by the handler of a GET route.

### Patterns

| In the route | Matches | Value |
|---|---|---|
| `about` | the segment `about` | |
| `:id` | exactly one segment | `request.params["id"]`, percent-decoded |
| `::path` | any number of segments, also none | `request.params["path"]`, **not** decoded, segments joined by `/` |
| `*` | exactly one segment | |
| `**` | any number of segments, also none | |

Paths are split at `/`. Empty segments are ignored, so `/a//b/` matches the route `/a/b`, and the query
(`?x=1`) is not part of the path.

### Which route wins

Fixed segments are tried before variables, and the search backtracks: with the routes `/a/b/c` and
`/a/:x/d`, the request `/a/b/d` first follows the fixed `b`, finds no `d` after it, and then tries the
variable. Two variable routes that could both match the same request (`/a/:x` and `/a/*`) are tried in no
defined order: avoid such overlaps.

### Percent-encoding

The router matches the path as the client sent it, and decodes each segment before it compares it or binds it to a
`:variable`:

```text
GET /users/J%C3%BCrgen%20M     params["id"]   == "Jürgen M"
GET /files/a/b%20c.txt         params["path"] == "a/b%20c.txt"   (kept as sent)
```

A segment that is not valid percent-encoding does not match anything.

### A variable at the end of a route

A `:variable` or `*` at the end of a route also matches when the segment is missing: with only the route
`/users/:id`, the request `/users` is handled with `id` set to the empty string. Register `/users` itself if you
need to treat it differently (the fixed route wins), or check for the empty value.

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
