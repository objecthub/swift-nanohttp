# How a Request Is Served

Follow a request from the socket to your handler and back.

## Overview

```text
start()  ──►  listening socket  ──►  accept loop (a thread of its own)
                                           │ accepts a connection (over maxConnections ──► 503)
                                           ▼
                              a thread of its own serves the connection:
                                           │
        ┌──────────────────────────────────┴───────────────────────────────┐
        ▼                                                                  │
   wait for the request (idleTimeout), NanoHTTPParser reads it             │
        │   Expect: 100-continue ──► 100 Continue                          │
        │   chunked bodies are put together                                │
        │   too large or malformed ──► 400 / 413 / 414 / 417 / 431 / 501 / 505,
        │   connection closed; stalls (readTimeout) ──► 408, connection closed
        ▼                                                                  │
   dispatch(request:)                                                      │
        │   middleware, outermost first, each around the rest              │
        │   router: method + path ──► handler and route variables          │
        │   HEAD ──► the GET handler; other methods of the path ──► 405    │
        │   OPTIONS answered; no route ──► notFoundHandler, else 404       │
        ▼                                                                  │
   the handler returns a NanoHTTPResponse (or throws: NanoHTTPError)       │
        ▼                                                                  │
   the response is written: head and body in one piece, or the body        │
        in chunks, or with the length that the handler declared            │
        │   a socket session (WebSocket) runs now, then the connection ends│
        ▼                                                                  │
   does the client want to keep the connection, and is the end of the      │
   response known? (HTTP/1.1: yes, unless it said Connection: close) ──────┘
        │ no
        ▼
   Connection: close was sent, and the connection is closed
```

1. ``NanoHTTPServerIO/start(_:)`` creates the listening socket (at the address of the
   ``NanoHTTPServerIO/Configuration/listenAddress``) and starts the accept loop
   (``NanoHTTPServerIO/listen()``). Failures to accept do not end the loop, unless the listening socket is gone.
2. Each accepted connection is registered with the server, so that ``NanoHTTPServerIO/stop()`` can close it, and
   counted: when ``NanoHTTPServerIO/Configuration/maxConnections`` connections are open, the new one is answered with
   `503` and closed. Otherwise a thread of its own serves the connection.
3. The thread waits for the first byte of a request for at most the ``NanoHTTPServerIO/Configuration/idleTimeout``
   (a silent connection is closed). A ``NanoHTTPParser`` then reads the request. It reads exactly as much as its
   ``NanoHTTPParser/Limits`` allow, and waits at most the ``NanoHTTPServerIO/Configuration/readTimeout`` for more.
   Requests that exceed a limit, are malformed or stall are answered by the server with `400`, `408`, `413`, `414` or
   `431`; the connection is closed after the answer, once the client has had the chance to read it.
4. ``NanoHTTPServerIO/dispatch(request:)`` finds the handler. ``NanoHTTPServer`` runs the middleware, then the
   router, then the `notFoundHandler`.
5. The handler returns a response; the response is written. A body that cannot be produced (invalid JSON) becomes a
   `500`.
6. If the client wants to keep the connection (HTTP/1.1: unless it said `Connection: close`) and the end of the response is
   known, the thread waits for the next request on it; otherwise the connection is closed. A WebSocket response keeps the thread: the session runs until
   the connection ends.
7. With ``NanoHTTPServerIO/Configuration/Threading/singleThread`` there are no threads for connections: the accepting
   thread waits for the listening socket and all connections together, serves the connection that has data (one
   request, then back to waiting), and closes those that stay silent for the idle timeout.
8. ``NanoHTTPServerIO/stop()`` closes the listening socket and all registered connections: threads that wait for
   a request return, and threads that are writing fail.

The types involved: ``NanoHTTPServerIO`` (sockets and threads), ``NanoHTTPServer`` (routing),
``NanoHTTPConnection`` (one request with its handler), ``NanoHTTPParser`` (reading), ``NanoSocket`` (the
connection), ``NanoHTTPRequest`` and ``NanoHTTPResponse``.

## Topics

- ``NanoHTTPServerIO``
- ``NanoHTTPConnection``
- ``NanoHTTPParser``
- ``NanoSocket``
