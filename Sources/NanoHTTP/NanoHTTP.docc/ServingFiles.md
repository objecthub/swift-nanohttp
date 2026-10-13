# Serving Files

Share a file, a directory, or a browsable listing.

## Overview

Three handler factories serve files from disk:

```swift
let server = NanoHTTPServer()
let directory = NSHomeDirectory() + "/Public"
server["/logo"] = share(file: directory + "/logo.png")
server["/static/::path"] = share(directory: directory)
server["/browse/::path"] = browse(directory: directory)
```

- ``share(file:)`` serves one file.
- ``share(directory:defaults:followSymlinks:)`` serves the files below a directory. The route must end in a
  path variable (`::path`): its value selects the file. The request for the route itself (`/static/`) serves
  the first existing file of `defaults` (`index.html`, `default.html`).
- ``browse(directory:followSymlinks:)`` is like it, but answers requests for a directory with an HTML list of
  links. Everything in the directory is listed, hidden files included.

The `Content-Type` comes from the extension of the file (`.html` gives `text/html`, an unknown extension gives
`application/octet-stream`), and `Content-Length` is the size of the file. A missing file is answered with `404`.

### Files are only served from inside the directory

Requests that try to reach beyond the directory are answered with `403 Forbidden`: paths with `..` segments
(also percent-encoded, as `%2e%2e` or `..%2f`), paths with a NUL character, and paths that lead out of the
directory through a symbolic link. Symbolic links that stay inside the directory are followed, and so is a shared
directory that is itself a symbolic link.

If you really want links that lead outside to be served, opt in:

```swift
let server = NanoHTTPServer()
server["/static/::path"] = share(directory: "/var/www", followSymlinks: true)
```

Only do this if everyone who can create files in the directory is trusted: a link in it can expose any file that
the process can read. `..` and NUL characters in the request are refused in either case.

### Limits

- Files are streamed from disk, so their size does not matter for the memory of the server. The connection is
  closed after each file response, which is cheap for single files and slow for pages with many assets.
- Requests for a byte range (`Range`), conditional requests (`If-Modified-Since`, `ETag`) and compression are not
  supported: the whole file is always sent.
- A request for a directory that is not the route itself (`/static/sub`) opens the directory like a file and
  produces an empty answer. Link to files, or use ``browse(directory:followSymlinks:)``.

## Topics

- ``share(file:)``
- ``share(directory:defaults:followSymlinks:)``
- ``browse(directory:followSymlinks:)``
