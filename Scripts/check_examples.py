#!/usr/bin/env python3
"""Builds the examples (Examples/) and runs each of them against real requests.

For every example the script starts the program on a free port (`--port 0`), waits for the line that says where it
listens, makes requests that show what the example is for (including WebSocket handshakes, with a small client of its
own), and then sends SIGTERM: the example has to stop and exit with status 0, which is what NanoProcess.watchSignals
is for. A failed check prints what the program wrote.

    python3 Scripts/check_examples.py                          # all examples
    python3 Scripts/check_examples.py Chat Upload              # some of them
    python3 Scripts/check_examples.py --sanitize=thread        # built with the thread (or address) sanitizer:
                                                               # a report of the sanitizer fails the example

Everything is done with the Python standard library.
"""

import base64, http.client, json, os, re, signal, socket, struct, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


# MARK: Requests

def request(port, method, path, body=None, headers=None):
    """One request on a new connection: (status, headers, body bytes). The path is sent as it is."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, response, response.read()
    finally:
        connection.close()


def text(body):
    return body.decode("utf-8", "replace")


# MARK: WebSocket client (RFC 6455, only what the checks need)

class WebSocket:
    def __init__(self, port, path, origin=None):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
        lines = [f"GET {path} HTTP/1.1", f"Host: 127.0.0.1:{port}", "Upgrade: websocket", "Connection: Upgrade",
                 f"Sec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}", "Sec-WebSocket-Version: 13"]
        if origin:
            lines.append(f"Origin: {origin}")
        self.socket.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.socket.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, self.buffer = data.partition(b"\r\n\r\n")
        self.status = int(head.split(b" ", 2)[1]) if head else 0

    def send(self, message):
        payload = message.encode()
        mask = os.urandom(4)
        header = bytes([0x81])
        if len(payload) < 126:
            header += bytes([0x80 | len(payload)])
        else:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
        self.socket.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _need(self, count):
        while len(self.buffer) < count:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise Failure("the WebSocket was closed")
            self.buffer += chunk

    def receive(self):
        """The text of the next message."""
        self._need(2)
        length = self.buffer[1] & 0x7F
        offset = 2
        if length == 126:
            self._need(4)
            length = struct.unpack(">H", self.buffer[2:4])[0]
            offset = 4
        self._need(offset + length)
        payload = self.buffer[offset:offset + length]
        self.buffer = self.buffer[offset + length:]
        return payload.decode()

    def close(self):
        self.socket.close()


# MARK: The checks of the examples

def hello(port, _):
    status, _, body = request(port, "GET", "/")
    check(status == 200 and "Hello from NanoHTTP" in text(body), "GET /")
    status, _, body = request(port, "GET", "/hello/Ada")
    check(status == 200 and text(body) == "Hello, Ada!\n", f"GET /hello/Ada: {status} {body!r}")
    status, _, body = request(port, "GET", "/search?q=a%20b%26c")
    check("a b&c" in text(body), f"the query is decoded: {body!r}")
    status, _, body = request(port, "POST", "/echo", body=b"xyz")
    check(status == 200 and body == b"xyz", f"POST /echo: {status} {body!r}")
    status, _, body = request(port, "GET", "/nothing")
    check(status == 404 and "There is nothing at /nothing" in text(body), f"the not-found page: {status} {body!r}")


def todo_api(port, _):
    status, response, body = request(port, "POST", "/todos", body=b'{"title":"Buy milk"}')
    check(status == 201 and response.getheader("Location") == "/todos/1", f"POST /todos: {status} {body!r}")
    check(json.loads(body) == {"id": 1, "title": "Buy milk", "done": False}, f"the new todo: {body!r}")
    status, _, body = request(port, "GET", "/todos")
    check(status == 200 and len(json.loads(body)) == 1, f"GET /todos: {body!r}")
    status, _, body = request(port, "PATCH", "/todos/1", body=b'{"done":true}')
    check(status == 200 and json.loads(body)["done"] is True, f"PATCH: {status} {body!r}")
    status, _, body = request(port, "POST", "/todos", body=b'{"title":"  "}')
    check(status == 422 and "error" in json.loads(body), f"an empty title: {status} {body!r}")
    status, _, body = request(port, "POST", "/todos", body=b"this is not json")
    check(status == 400 and "error" in json.loads(body), f"a body that is no JSON: {status} {body!r}")
    status, _, body = request(port, "GET", "/todos/99")
    check(status == 404 and json.loads(body) == {"error": "There is no todo 99"}, f"an unknown todo: {status} {body!r}")
    status, _, body = request(port, "GET", "/todos/abc")
    check(status == 400, f"an id that is no number: {status}")
    status, _, body = request(port, "DELETE", "/todos/1")
    check(status == 204 and body == b"", f"DELETE: {status} {body!r}")
    status, _, _ = request(port, "GET", "/todos/1")
    check(status == 404, "the todo is gone")


def file_server(port, directory):
    status, response, body = request(port, "GET", "/files/hello.txt")
    check(status == 200 and body == b"hi there", f"GET /files/hello.txt: {status} {body!r}")
    check(response.getheader("ETag") is not None, "files have an ETag")
    status, response, body = request(port, "GET", "/files/hello.txt", headers={"Range": "bytes=0-1"})
    check(status == 206 and body == b"hi", f"a range: {status} {body!r}")
    status, _, body = request(port, "GET", "/browse/")
    check(status == 200 and "hello.txt" in text(body), f"the listing: {status}")
    status, response, _ = request(port, "GET", "/")
    check(status == 303 and response.getheader("Location") == "/browse/", f"the root redirects: {status}")
    for path in ["/files/../../../../etc/passwd", "/files/%2e%2e/%2e%2e/etc/passwd", "/files/sub/../../etc/passwd"]:
        status, _, body = request(port, "GET", path)
        check(status in (400, 403, 404) and b"root:" not in body, f"{path} must not leave the directory: {status}")
    status, _, _ = request(port, "GET", "/files/hello.txt", headers={"Host": "evil.example"})
    check(status == 403, f"a request for another host name is refused: {status}")


def chat(port, _):
    status, _, body = request(port, "GET", "/")
    check(status == 200 and "WebSocket" in text(body) and "/chat" in text(body), "the page")
    origin = f"http://127.0.0.1:{port}"
    first, second = WebSocket(port, "/chat", origin), WebSocket(port, "/chat", origin)
    check(first.status == 101 and second.status == 101, f"the handshakes: {first.status}, {second.status}")
    check(first.receive().startswith("Welcome!"), "a welcome for the first")
    check(second.receive().startswith("Welcome!"), "a welcome for the second")
    check("joined" in first.receive(), "the first hears that somebody joined")
    first.send("guest 1: hello")
    check(first.receive() == "guest 1: hello" and second.receive() == "guest 1: hello", "a message goes to everybody")
    first.close()
    check("left" in second.receive(), "the second hears that somebody left")
    second.close()
    foreign = WebSocket(port, "/chat", "http://evil.example")
    check(foreign.status == 403, f"a page of another site cannot open the WebSocket: {foreign.status}")
    foreign.close()


def status_page(port, _):
    status, _, body = request(port, "GET", "/")
    check(status == 200 and "Requests served" in text(body), "the page")
    live = WebSocket(port, "/live", f"http://127.0.0.1:{port}")
    check(live.status == 101, f"the handshake: {live.status}")
    current = int(live.receive())
    status, _, body = request(port, "GET", "/ping")
    check(status == 200 and body == b"pong", "ping")
    check(int(live.receive()) == current + 1, "the page is told about every request")
    live.close()
    status, _, body = request(port, "GET", "/")
    check("/ping" in text(body) and "(other)" not in text(body), "the counts per path")
    request(port, "GET", "/unknown/1")
    request(port, "GET", "/unknown/2")
    status, _, body = request(port, "GET", "/")
    check("(other)" in text(body) and "/unknown" not in text(body), "unknown paths are counted together")


def upload(port, _):
    status, _, body = request(port, "GET", "/")
    check(status == 200 and "multipart/form-data" in text(body), "the form")
    boundary = "----example-boundary-1234"
    form = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nmy <b>note</b>\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; filename=\"a<i>.txt\"\r\n"
            f"Content-Type: text/plain\r\n\r\nhello\r\n--{boundary}--\r\n").encode()
    status, response, _ = request(port, "POST", "/upload", body=form,
                                  headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    cookie = response.getheader("Set-Cookie")
    check(status == 303 and response.getheader("Location") == "/", f"the redirect: {status}")
    check(cookie and cookie.startswith("flash=") and "HttpOnly" in cookie, f"the cookie with the message: {cookie}")
    status, response, body = request(port, "GET", "/", headers={"Cookie": cookie.split(";")[0]})
    page = text(body)
    check("Received 1 file(s)" in page, "the message of the cookie is shown")
    check("a&lt;i&gt;.txt: 5 bytes (text/plain)" in page, "the file is listed, with its name escaped")
    check("<b>note</b>" not in page and "my &lt;b&gt;note&lt;/b&gt;" in page, "the note is escaped")
    check("Max-Age=0" in (response.getheader("Set-Cookie") or ""), "the message is shown once: the cookie is deleted")
    status, _, body = request(port, "GET", "/")
    check("Received 1 file" not in text(body) and "a&lt;i&gt;.txt" in text(body), "without the cookie there is no message")
    status, _, _ = request(port, "POST", "/upload", body=b"a=b",
                           headers={"Content-Type": "application/x-www-form-urlencoded"})
    check(status == 400, f"a form that is no multipart form: {status}")


EXAMPLES = {
    "Hello": ("ExampleHello", hello),
    "TodoAPI": ("ExampleTodoAPI", todo_api),
    "FileServer": ("ExampleFileServer", file_server),
    "Chat": ("ExampleChat", chat),
    "Status": ("ExampleStatus", status_page),
    "Upload": ("ExampleUpload", upload),
}


# MARK: Running

def run(name, program, checks, binaries):
    directory = tempfile.mkdtemp(prefix="nano-example-")
    arguments = ["--port", "0"]
    if name == "FileServer":
        with open(os.path.join(directory, "hello.txt"), "w") as handle:
            handle.write("hi there")
        os.mkdir(os.path.join(directory, "sub"))
        arguments += ["--directory", directory]
    process = subprocess.Popen([os.path.join(binaries, program)] + arguments, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    output = []
    try:
        port = None
        deadline = time.time() + 15
        while port is None and time.time() < deadline:
            line = process.stdout.readline()
            if not line:
                break
            output.append(line)
            match = re.search(r"http://[^:\s]+:(\d+)", line)
            if match:
                port = int(match.group(1))
        check(port, "the program did not say where it listens")
        checks(port, directory)
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            raise Failure("the program did not stop after SIGTERM")
        output.append(process.stdout.read())
        check(process.returncode == 0, f"the program ended with status {process.returncode}")
        check("Sanitizer" not in "".join(output), "the sanitizer has reported something")
    except Exception:
        print("".join(output) + (process.stdout.read() if process.poll() is not None else ""), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()


def main():
    flags = [argument for argument in sys.argv[1:] if argument.startswith("--")]
    names = [argument for argument in sys.argv[1:] if not argument.startswith("--")] or list(EXAMPLES)
    for name in names:
        if name not in EXAMPLES:
            sys.exit(f"unknown example {name!r}; the examples are {', '.join(EXAMPLES)}")
    build = subprocess.run(["swift", "build"] + flags, cwd=ROOT, capture_output=True, text=True)
    if build.returncode != 0:
        sys.exit("swift build failed:\n" + build.stdout + build.stderr)
    binaries = subprocess.run(["swift", "build", "--show-bin-path"] + flags, cwd=ROOT, capture_output=True,
                              text=True).stdout.strip()
    failed = []
    for name in names:
        program, checks = EXAMPLES[name]
        try:
            run(name, program, checks, binaries)
            print(f"ok: {program}")
        except Failure as failure:
            print(f"FAILED: {program}: {failure}")
            failed.append(name)
    if failed:
        sys.exit(f"the examples do not work: {', '.join(failed)}")
    print(f"all {len(names)} examples work")


if __name__ == "__main__":
    main()
