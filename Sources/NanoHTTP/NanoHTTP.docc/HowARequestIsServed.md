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
   wait for the request (idleTimeout), NanoHTTPParser reads it            │
        │   too large or malformed ──► 400 / 413 / 414 / 431, connection closed
        │   stalls (readTimeout) ──► 408, connection closed
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
6. If the client asked to keep the connection and the response had a known length, the thread waits for the next
   request on it; otherwise the connection is closed. A WebSocket response keeps the thread: the session runs until
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
