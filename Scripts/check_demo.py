#!/usr/bin/env python3
"""Runs the demo server (the DemoServer tool) in both threading modes and tests it with real clients.

The demo is the framework's kitchen sink, and has no unit tests of its own. This script starts it on a free port,
sharing a temporary folder, and uses `curl` for what browsers and tools do: ranges and conditional requests, HEAD and
OPTIONS, forms (also with a chunked body), a file upload that makes curl send `Expect: 100-continue`, keep-alive
reuse, HTTP/1.0, `--compressed`, a streamed response, redirects, attempts to leave the shared folder, and requests
for another host name or from another origin; a WebSocket echo is tested with the client of check_examples.py.

    python3 Scripts/check_demo.py

Needs curl (it is part of macOS). Everything else is the Python standard library.
"""

import http.client, os, re, signal, subprocess, sys, tempfile, threading, time

from check_examples import Failure, WebSocket, check, request, text

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = bytes((index * 7 + index // 256) % 256 for index in range(100_000))


def curl(port, path, *arguments, verbose=False):
    """Runs curl against the server: (status code, headers of the last response in lower case, body, stderr)."""
    with tempfile.TemporaryDirectory() as directory:
        head, body = os.path.join(directory, "head"), os.path.join(directory, "body")
        command = ["curl", "-s", "-S", "--max-time", "30", "-D", head, "-o", body, "-w", "%{http_code}"]
        if verbose:
            command.append("-v")
        result = subprocess.run(command + list(arguments) + [f"http://127.0.0.1:{port}{path}"],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise Failure(f"curl {' '.join(arguments)} {path} failed ({result.returncode}): {result.stderr.strip()}")
        blocks = [block for block in open(head, "rb").read().decode("latin-1").split("\r\n\r\n") if block.strip()]
        headers = {}
        for line in (blocks[-1].split("\r\n")[1:] if blocks else []):
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        data = open(body, "rb").read() if os.path.exists(body) else b""      # curl writes no file for an empty body
        return int(result.stdout.strip()[-3:] or 0), headers, data, result.stderr     # (the last of several URLs)


def checks(port, directory):
    # Files: a complete response, ETag and Last-Modified, a range, a conditional request, HEAD.
    status, headers, body, _ = curl(port, "/public/data.bin")
    check(status == 200 and body == DATA, f"GET a file: {status}, {len(body)} bytes")
    check("etag" in headers and "last-modified" in headers, f"caching headers: {headers}")
    status, headers, body, _ = curl(port, "/public/data.bin", "-r", "100-199")
    check(status == 206 and body == DATA[100:200], f"a range: {status}")
    check(headers.get("content-range") == "bytes 100-199/100000", f"Content-Range: {headers.get('content-range')}")
    head_status, head, head_body, _ = curl(port, "/public/data.bin", "-I")      # HEAD
    # (curl writes the headers of a HEAD response to its output file: what must not arrive is the 100000 bytes.)
    check(head_status == 200 and head.get("content-length") == "100000" and len(head_body) < 1000,
          f"HEAD: {head_status} {head} {len(head_body)} bytes")
    status, _, body, _ = curl(port, "/public/data.bin", "-H", f"If-None-Match: {head['etag']}")
    check(status == 304 and body == b"", f"a conditional request: {status}")
    status, _, body, _ = curl(port, "/files/")
    check(status == 200 and "data.bin" in text(body), f"the listing: {status}")

    # Methods: OPTIONS and 405 are answered by the framework.
    status, headers, body, _ = curl(port, "/upload", "-X", "OPTIONS")
    check(status == 204 and "GET" in headers.get("allow", "") and "POST" in headers.get("allow", ""),
          f"OPTIONS: {status} {headers.get('allow')}")
    status, headers, _, _ = curl(port, "/upload", "-X", "PUT", "-d", "x")
    check(status == 405 and "POST" in headers.get("allow", ""), f"405 with Allow: {status} {headers.get('allow')}")

    # Forms: urlencoded, chunked, and escaped on the way out.
    status, _, body, _ = curl(port, "/login", "-d", "email=a%40b.c&password=x%3Cb%3E")
    check(status == 200 and "email = a@b.c" in text(body) and "password = x&lt;b&gt;" in text(body),
          f"a form: {status} {body!r}")
    status, _, body, _ = curl(port, "/login", "-H", "Transfer-Encoding: chunked", "-d", "email=chunked")
    check(status == 200 and "email = chunked" in text(body), f"a form in chunks: {status} {body!r}")

    # An upload of 2 MB: curl asks `Expect: 100-continue` and waits for the answer.
    big = os.path.join(directory, "upload.bin")
    with open(big, "wb") as handle:
        handle.write(bytes(range(256)) * 8192)
    status, _, body, verbose = curl(port, "/upload", "-F", f"my_file1=@{big};filename=big<1>.bin", verbose=True)
    check(status == 200 and "File name: big&lt;1&gt;.bin Size: 2097152" in text(body), f"an upload: {status} {body!r}")
    check("Expect: 100-continue" in verbose and "100 Continue" in verbose, "curl used Expect: 100-continue")

    # Connections: reused for several requests, HTTP/1.0, compression asked for but not applied.
    _, _, _, verbose = curl(port, "/public/small.txt", f"http://127.0.0.1:{port}/public/small.txt",
                            f"http://127.0.0.1:{port}/public/small.txt", verbose=True)
    check(len(re.findall(r"[Rr]e-?using existing", verbose)) >= 2, "curl reused the connection for three requests")
    status, headers, body, _ = curl(port, "/public/small.txt", "-0")
    check(status == 200 and body == b"small file", f"HTTP/1.0: {status}")
    status, headers, body, _ = curl(port, "/public/small.txt", "--compressed")
    check(status == 200 and body == b"small file" and "content-encoding" not in headers, f"--compressed: {status} {headers}")

    # Responses: streamed in chunks, with a custom writer, redirects.
    status, headers, body, _ = curl(port, "/stream")
    check(status == 200 and body.startswith(b"[chunk 0]") and body.endswith(b"[chunk 100]"), f"/stream: {status}")
    check(headers.get("transfer-encoding") == "chunked", f"/stream is chunked: {headers}")
    status, _, body, _ = curl(port, "/custom")
    check(status == 200 and body == b"test", f"/custom: {status} {body!r}")
    status, headers, _, _ = curl(port, "/redirect/permanently")
    check(status == 301 and headers.get("location", "").startswith("http"), f"a redirect: {status}")

    # Leaving the shared folder, and the policies of the demo (hostPolicy .automatic, originPolicy .sameOrigin).
    for path in ["/public/../../../../etc/passwd", "/public/%2e%2e/%2e%2e/etc/passwd", "/public/..%2f..%2fetc/passwd"]:
        status, _, body, _ = curl(port, path, "--path-as-is")
        check(status in (400, 403, 404) and b"root:" not in body, f"{path} must not leave the folder: {status}")
    status, _, _, _ = curl(port, "/", "-H", "Host: evil.example")
    check(status == 403, f"another host name is refused: {status}")
    status, _, _, _ = curl(port, "/login", "-d", "a=b", "-H", "Origin: http://evil.example")
    check(status == 403, f"a form from another site is refused: {status}")
    status, _, _, _ = curl(port, "/login", "-d", "a=b", "-H", f"Origin: http://127.0.0.1:{port}")
    check(status == 200, f"a form from the site itself works: {status}")
    status, _, _, _ = curl(port, "/", "-H", "Origin: http://evil.example")
    check(status == 200, f"a request that changes nothing is not refused: {status}")

    # A WebSocket echo, and one from another origin.
    socket = WebSocket(port, "/websocket-echo", f"http://127.0.0.1:{port}")
    check(socket.status == 101, f"the WebSocket handshake: {socket.status}")
    socket.send("hello, demo")
    check(socket.receive() == "hello, demo", "the echo")
    socket.close()
    foreign = WebSocket(port, "/websocket-echo", "http://evil.example")
    check(foreign.status == 403, f"a WebSocket from another site is refused: {foreign.status}")
    foreign.close()

    # Many clients at the same time.
    results = []

    def fetch():
        results.append(request(port, "GET", "/long")[0])
    threads = [threading.Thread(target=fetch) for _ in range(40)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    check(results == [200] * 40, f"40 requests at the same time: {sorted(set(results))}")


def run(mode, binary):
    directory = tempfile.mkdtemp(prefix="nano-demo-")
    with open(os.path.join(directory, "data.bin"), "wb") as handle:
        handle.write(DATA)
    with open(os.path.join(directory, "small.txt"), "wb") as handle:
        handle.write(b"small file")
    arguments = ["--port", "0", "--directory", directory] + (["--single-thread"] if mode else [])
    process = subprocess.Popen([binary] + arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = []

    def read_output():
        # The demo logs every request: if nobody reads, the pipe fills up and the demo blocks in `print`.
        for line in process.stdout:
            output.append(line)
    threading.Thread(target=read_output, daemon=True).start()
    try:
        port, deadline = None, time.time() + 15
        while port is None and time.time() < deadline:
            match = re.search(r"port = (\d+)", "".join(output))
            port = int(match.group(1)) if match else None
            time.sleep(0.05)
        check(port, "the demo did not say where it listens")
        checks(port, directory)
    except Exception:
        print("".join(output), file=sys.stderr)
        raise
    finally:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()


def main():
    build = subprocess.run(["swift", "build", "--product", "DemoServer"], cwd=ROOT, capture_output=True, text=True)
    if build.returncode != 0:
        sys.exit("swift build failed:\n" + build.stdout + build.stderr)
    binaries = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    failed = False
    for name, single in (("threads per connection", False), ("one thread", True)):
        try:
            run(single, os.path.join(binaries, "DemoServer"))
            print(f"ok: {name}")
        except Failure as failure:
            print(f"FAILED: {name}: {failure}")
            failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
