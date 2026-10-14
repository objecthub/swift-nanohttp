# Examples

Six small programs that show how the pieces fit together, and that you can run.

## Overview

The package has six executable targets in its `Examples` folder. Every one is a complete program of one or two pages,
with comments that say why things are done the way they are; start the one that is closest to what you want to build
and change it. They are Swift package targets: in Xcode, choose the package scheme of the example, or run them from the
command line:

```bash
swift run ExampleHello
swift run ExampleTodoAPI --port 9000
swift run ExampleFileServer --directory ~/Downloads
```

All of them listen at the loopback address, so only programs on your machine can connect, and say where they listen. The
options are the same everywhere: `--port 8080` (`0` picks a free port) and `--network`, which makes the server reachable
from other devices (on a network that you trust). Ctrl-C stops the server: the examples use ``NanoProcess/watchSignals(_:)``
to stop it, so that the program ends normally.

| Example | What it shows |
|---|---|
| `ExampleHello` | The smallest useful server: routes, a route variable, a query parameter, a body, a page for unknown paths. |
| `ExampleTodoAPI` | A JSON API: `Codable` models in and out (``NanoHTTPResponse/json(_:status:headers:encoder:)``, ``NanoHTTPRequest/json(_:decoder:)``), status codes (`201` with `Location`, `204`, `422`), errors as JSON (``NanoHTTPServer/errorHandler``), middleware, and a lock around the state that the handlers share. |
| `ExampleFileServer` | A directory on the web: ``NanoFiles/share(directory:defaults:followSymlinks:)`` and ``NanoFiles/browse(directory:followSymlinks:)``, and the Host and Origin policies that keep web pages of other sites away. |
| `ExampleChat` | A chat room: ``NanoWebSocket``, a ``NanoWebSocketHub`` that sends to all sessions, a page built with NanoHTML, and the origin check for the WebSocket. |
| `ExampleStatus` | A server with **one thread** (``NanoHTTPServerIO/Configuration/Threading/singleThread``): counters that are plain variables, no locks, and a live display over a WebSocket. |
| `ExampleUpload` | A form with a file upload: ``NanoHTTPRequest/parseMultiPartFormData()``, the limits of the server, cookies (a message that is shown once), and post/redirect/get with ``NanoHTTPResponse/seeOther(_:_:)``. |

Everything that a request contains is treated as untrusted in them: pages escape it (NanoHTML does that for you),
file names are only displayed, and the limits of the server are set for what the example needs. Read
<doc:SecurityAndLimits> before you put a server of your own where others can reach it.

## Checking the examples

`python3 Scripts/check_examples.py` builds the examples, starts every one on a free port, makes real requests (including
WebSocket handshakes) and stops it with `SIGTERM`; `--sanitize=thread` does the same with the thread sanitizer. It is how the
examples are kept working.
