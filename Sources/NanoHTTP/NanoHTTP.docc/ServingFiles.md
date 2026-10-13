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
  path variable (`::path`): its value selects the file. A request for a directory is redirected to the same
  address with a `/` at the end (so that the relative links of its pages work: `301`, the query is kept); with the `/`
  it serves the first existing file of `defaults` (`index.html`, `default.html`) in the directory, or answers `404`.
- ``browse(directory:followSymlinks:)`` is like it, but answers requests for a directory with an HTML list of
  links (without the entries `.` and `..`). Everything in the directory is listed, hidden files included.

The `Content-Type` comes from the extension of the file (`.html` gives `text/html`, an unknown extension gives
`application/octet-stream`), and `Content-Length` is the size of the file, so that the connection can be used for the
next request. A missing file is answered with `404`.

### Validators, conditional requests and ranges

Every file is sent with an `ETag` (it changes when the file is replaced or modified, also without a change of its
size) and `Last-Modified`. A client that has a copy asks whether it is good with `If-None-Match` or `If-Modified-Since`
and gets `304 Not Modified`, without the body, if it is: pages that are reloaded cost the headers only.

A client can ask for a part of a file with a `Range` header (`bytes=0-1023`, `bytes=1024-`, `bytes=-500`), which is
what video players, download managers and clients that resume a download do. The answer is `206 Partial Content` with
a `Content-Range` header and the bytes, or `416 Range Not Satisfiable` if the file has nothing there (with
`Content-Range: bytes */size`). `If-Range` makes the range depend on the file being the version that the client has
(otherwise the whole file is sent). Only one range per request is served; a header with several ranges, or one that is
not understood, is ignored, which the protocol allows (the whole file is sent). The parts are sent without the
bytes passing through the process, where the system has `sendfile`.

`HEAD` requests get the headers of these responses, including `Content-Length`, without a body.

### Files are only served from inside the directory

The part of the path that selects the file is the value of the route's path variable. The router has percent-decoded it
once (`a%20b.txt` is the file `a b.txt`); the handlers do not decode it again, so `%252e%252e` is a file that is called
`%2e%2e`, and not a way to `..`.

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
