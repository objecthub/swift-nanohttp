// A small load generator: N blocking client threads, each doing request after request.
//   loadgen PORT PATH [-c N] [-d SECONDS] [-w WARMUP] [-k] [--post BYTES] [--idle N] [--timeout SECONDS] [--ws]
// With --ws every client opens a WebSocket at PATH and sends 16-byte text messages one after the other, each
// of which the server echoes; a request is one message and its echo.
// Prints one JSON object: requests per second, MB/s, latency percentiles in microseconds, errors.
import Foundation

var port: UInt16 = 0
var path = "/"
var concurrency = 1
var duration = 5.0
var warmup = 1.0
var keepAlive = false
var postBytes = 0
var idleConnections = 0
var timeout = 3.0
var webSocket = false

var rest = Array(CommandLine.arguments.dropFirst())
port = UInt16(rest.removeFirst())!
path = rest.removeFirst()
while !rest.isEmpty {
  switch rest.removeFirst() {
    case "-c": concurrency = Int(rest.removeFirst())!
    case "-d": duration = Double(rest.removeFirst())!
    case "-w": warmup = Double(rest.removeFirst())!
    case "-k": keepAlive = true
    case "--post": postBytes = Int(rest.removeFirst())!
    case "--idle": idleConnections = Int(rest.removeFirst())!
    case "--timeout": timeout = Double(rest.removeFirst())!
    case "--ws": webSocket = true
    default: fatalError("bad argument")
  }
}

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

func connectToServer() -> Int32? {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  var one: Int32 = 1
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  let result = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  if result != 0 { close(fd); return nil }
  return fd
}

/// Closes with a reset instead of a FIN: no TIME_WAIT state, so that tens of thousands of short
/// connections do not use up the ephemeral ports. The same for every server that is measured.
func abortiveClose(_ fd: Int32) {
  var linger = linger(l_onoff: 1, l_linger: 0)
  setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
  close(fd)
}

func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
  var sent = 0
  while sent < bytes.count {
    let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
    if n <= 0 { return false }
    sent += n
  }
  return true
}

let connectionHeader = keepAlive ? "keep-alive" : "close"
var requestHead = (postBytes > 0 ? "POST" : "GET") + " \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: \(connectionHeader)\r\n"
if postBytes > 0 { requestHead += "Content-Length: \(postBytes)\r\n" }
requestHead += "\r\n"
let requestBytes = Array(requestHead.utf8) + [UInt8](repeating: 0x62, count: postBytes)

/// Reads one response; returns the number of bytes of its body, or nil on failure.
func readResponse(_ fd: Int32, _ buffer: inout [UInt8]) -> (status: Int, body: Int)? {
  var data = [UInt8]()
  var headEnd = -1
  var contentLength = -1
  var status = 0
  var bodyRead = 0
  while true {
    let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    if n < 0 && errno == EINTR { continue }
    if n <= 0 { return headEnd >= 0 && contentLength < 0 ? (status, bodyRead) : nil }
    if headEnd < 0 {
      data.append(contentsOf: buffer[0..<n])
      if let r = data.firstRange(of: [13, 10, 13, 10]) {
        headEnd = r.upperBound
        let head = String(decoding: data[0..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        status = Int(lines[0].split(separator: " ").dropFirst().first ?? "0") ?? 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
          contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? -1
        }
        bodyRead = data.count - headEnd
        data = []
      }
    } else {
      bodyRead += n
    }
    if headEnd >= 0 && contentLength >= 0 && bodyRead >= contentLength { return (status, bodyRead) }
  }
}

// Idle connections: open, send nothing, hold.
var idle = [Int32]()
for _ in 0..<idleConnections { if let fd = connectToServer() { idle.append(fd) } }
if idleConnections > 0 { usleep(300_000) }

let start = now()
let measureFrom = start + UInt64(warmup * 1e9)
let end = measureFrom + UInt64(duration * 1e9)

final class Worker {
  var latencies = [UInt64]()
  var bytes = 0
  var errors = 0
  var requests = 0
  /// One WebSocket: handshake, then messages and their echoes until the end of the measurement.
  func runWebSocket() {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    guard let fd = connectToServer() else {
      errors += 1
      return
    }
    defer { close(fd) }
    let handshake = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    guard sendAll(fd, Array(handshake.utf8)) else {
      errors += 1
      return
    }
    var head = [UInt8]()
    while head.firstRange(of: [13, 10, 13, 10]) == nil {
      let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n <= 0 {
        errors += 1
        return
      }
      head.append(contentsOf: buffer[0..<n])
    }
    guard String(decoding: head.prefix(12), as: UTF8.self).contains("101") else {
      errors += 1
      return
    }
    let mask: [UInt8] = [1, 2, 3, 4]
    let payload = Array("0123456789abcdef".utf8)
    let frame: [UInt8] = [0x81, 0x80 | UInt8(payload.count)] + mask + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    let expected = 2 + payload.count
    while now() < end {
      let begin = now()
      guard sendAll(fd, frame) else {
        errors += 1
        return
      }
      var got = 0
      while got < expected {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, expected - got) }
        if n <= 0 {
          errors += 1
          return
        }
        got += n
      }
      let finish = now()
      if begin >= measureFrom && finish <= end {
        latencies.append(finish - begin)
        bytes += payload.count
        requests += 1
      }
    }
  }
  
  func run() {
    if webSocket {
      runWebSocket()
      return
    }
    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    var fd: Int32? = nil
    var reused = false // is the connection one that has served a request already?
    while now() < end {
      let begin = now()
      if fd == nil { fd = connectToServer(); reused = false }
      guard var current = fd else { errors += 1; usleep(1000); continue }
      var ok = false
      var bodyBytes = 0
      if sendAll(current, requestBytes), let response = readResponse(current, &buffer), response.status == 200 {
        ok = true
        bodyBytes = response.body
      } else if reused {
        // A connection that the server has closed since: what every HTTP client does is to open another one and
        // ask again (once), without calling that an error. 1.x servers close the connection after some responses.
        abortiveClose(current)
        fd = connectToServer()
        reused = false
        if let again = fd {
          current = again
          if sendAll(current, requestBytes), let response = readResponse(current, &buffer), response.status == 200 {
            ok = true
            bodyBytes = response.body
          }
        }
      }
      let finish = now()
      if !ok {
        abortiveClose(current); fd = nil
        if begin >= measureFrom { errors += 1 }
        continue
      }
      reused = true
      if !keepAlive { abortiveClose(current); fd = nil }
      if begin >= measureFrom && finish <= end {
        latencies.append(finish - begin)
        bytes += bodyBytes + (postBytes > 0 ? postBytes : 0)
        requests += 1
      }
    }
    if let current = fd { close(current) }
  }
}

let workers = (0..<concurrency).map { _ in Worker() }
let group = DispatchGroup()
for worker in workers {
  group.enter()
  let thread = Thread { worker.run(); group.leave() }
  thread.stackSize = 1 << 20
  thread.start()
}
group.wait()
idle.forEach { close($0) }

var all = workers.flatMap { $0.latencies }.sorted()
let requests = all.count
let errors = workers.reduce(0) { $0 + $1.errors }
let totalBytes = workers.reduce(0) { $0 + $1.bytes }
func percentile(_ p: Double) -> Double {
  guard !all.isEmpty else { return 0 }
  return Double(all[min(all.count - 1, Int(Double(all.count) * p))]) / 1000
}
let mean = all.isEmpty ? 0 : Double(all.reduce(0, +)) / Double(all.count) / 1000
print("""
{"requests": \(requests), "rps": \(Double(requests) / duration), "mbps": \(Double(totalBytes) / duration / 1_000_000), "mean_us": \(mean), "p50_us": \(percentile(0.5)), "p90_us": \(percentile(0.9)), "p99_us": \(percentile(0.99)), "max_us": \(Double(all.last ?? 0) / 1000), "errors": \(errors)}
""")
