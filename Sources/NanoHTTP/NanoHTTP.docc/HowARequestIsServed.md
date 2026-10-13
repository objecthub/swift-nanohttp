# How a Request Is Served

Follow a request from the socket to your handler and back.

## Overview

```text
start()  ──►  listening socket  ──►  accept loop (one background thread)
                                           │ accepts a connection
                                           ▼
                              a thread of the global dispatch queue serves the connection:
                                           │
        ┌──────────────────────────────────┴───────────────────────────────┐
        ▼                                                                  │
   NanoHTTPParser reads the request: line, headers, body                   │
        │   too large or malformed ──► 400 / 413 / 414 / 431, connection closed
        ▼                                                                  │
   dispatch(request:)                                                      │
        │   middleware, in order ──► a response? done                      │
        │   router: method + path ──► handler and route variables          │
        │   no route ──► notFoundHandler, else 404                         │
        ▼                                                                  │
   the handler returns a NanoHTTPResponse                                  │
        ▼                                                                  │
   the response is written: status line, headers, body                     │
        │   a socket session (WebSocket) runs now, then the connection ends│
        ▼                                                                  │
   keep-alive requested and the length of the response known? ─── yes ─────┘
        │ no
        ▼
   the connection is closed
```

1. ``NanoHTTPServerIO/start(_:forceIPv4:priority:handlerPriority:)`` creates the listening socket and starts the
   accept loop (``NanoHTTPServerIO/listen(priority:)``). Failures to accept do not end the loop, unless the
   listening socket is gone.
2. Each accepted connection is served by a thread from the global dispatch queues. The connection is registered with
   the server, so that ``NanoHTTPServerIO/stop()`` can close it.
3. A ``NanoHTTPParser`` reads the request. It reads exactly as much as its ``NanoHTTPParser/Limits`` allow. Requests
   that exceed a limit or are malformed are answered by the server with `400`, `413`, `414` or `431`; the connection
   is closed after the answer, once the client has had the chance to read it.
4. ``NanoHTTPServerIO/dispatch(request:)`` finds the handler. ``NanoHTTPServer`` runs the middleware, then the
   router, then the `notFoundHandler`.
5. The handler returns a response; the response is written. A body that cannot be produced (invalid JSON) becomes a
   `500`.
6. If the client asked to keep the connection and the response had a known length, the thread waits for the next
   request on it; otherwise the connection is closed. A WebSocket response keeps the thread: the session runs until
   the connection ends.
7. ``NanoHTTPServerIO/stop()`` closes the listening socket and all registered connections: threads that wait for
   a request return, and threads that are writing fail.

The types involved: ``NanoHTTPServerIO`` (sockets and threads), ``NanoHTTPServer`` (routing),
``NanoHTTPConnection`` (one request with its handler), ``NanoHTTPParser`` (reading), ``NanoSocket`` (the
connection), ``NanoHTTPRequest`` and ``NanoHTTPResponse``.

## Topics

- ``NanoHTTPServerIO``
- ``NanoHTTPConnection``
- ``NanoHTTPParser``
- ``NanoSocket``
