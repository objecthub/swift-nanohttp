//
//  RawClient.swift
//  NanoHTTPTests
//
//  Test support: a minimal *blocking* TCP client that speaks raw bytes to a test server.
//
//  Unlike `URLSession`, it never normalizes anything (`..` segments, malformed request lines,
//  odd headers, huge lengths all go over the wire exactly as written), and it can keep one
//  connection open to test keep-alive and pipelining behavior. Every read has a timeout, so a
//  misbehaving server fails a test instead of hanging it.
//

import Foundation
import Darwin

enum RawClientError: Error, CustomStringConvertible {
  case socket(String)
  case connect(String)
  case noResponse(String)

  var description: String {
    switch self {
      case .socket(let msg): return "socket(): \(msg)"
      case .connect(let msg): return "connect(): \(msg)"
      case .noResponse(let msg): return "no response: \(msg)"
    }
  }
}

/// A parsed HTTP response as seen on the wire.
struct RawResponse {
  let statusLine: String
  let headerFields: [(name: String, value: String)]
  var body: [UInt8]

  var status: Int {
    let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    return parts.count > 1 ? (Int(parts[1]) ?? -1) : -1
  }

  var reason: String {
    let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    return parts.count > 2 ? String(parts[2]) : ""
  }

  /// First header with the given (case-insensitive) name.
  func header(_ name: String) -> String? {
    return self.headerFields.first { $0.name.lowercased() == name.lowercased() }?.value
  }

  /// All headers with the given (case-insensitive) name.
  func headers(_ name: String) -> [String] {
    return self.headerFields.filter { $0.name.lowercased() == name.lowercased() }.map { $0.value }
  }

  var bodyString: String {
    return String(decoding: self.body, as: UTF8.self)
  }
}

final class RawClient {
  private var fd: Int32
  private let host: String
  private var buffer = [UInt8]()
  private(set) var reachedEOF = false

  /// Creates a client socket and (by default) connects it to `127.0.0.1:port`.
  /// Pass `connect: false` to reserve the file descriptor first and connect later.
  /// `receiveBuffer` sets the size of the receive buffer of the socket before it connects; a small one
  /// lets a client that does not read stall the sender after a few kilobytes.
  init(port: Int, host: String = "127.0.0.1", timeout: TimeInterval = 3, connect: Bool = true,
       receiveBuffer: Int? = nil) throws {
    self.host = host
    self.fd = socket(AF_INET, SOCK_STREAM, 0)
    guard self.fd >= 0 else {
      throw RawClientError.socket(String(cString: strerror(errno)))
    }
    var one: Int32 = 1
    setsockopt(self.fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    self.setReceiveTimeout(timeout)
    if var size = receiveBuffer.map({ Int32($0) }) {
      setsockopt(self.fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }
    if connect {
      try self.connect(port: port)
    }
  }

  deinit {
    self.close()
  }

  func connect(port: Int) throws {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr(self.host)
    let result = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(self.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if result != 0 {
      let message = String(cString: strerror(errno))
      self.close()
      throw RawClientError.connect(message)
    }
  }

  func close() {
    if self.fd >= 0 {
      Darwin.close(self.fd)
      self.fd = -1
    }
  }

  private func setReceiveTimeout(_ timeout: TimeInterval) {
    var tv = timeval(tv_sec: Int(timeout),
                     tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
    setsockopt(self.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  }

  // MARK: - Writing

  func send(_ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count && self.fd >= 0 {
      let written = bytes.withUnsafeBytes {
        Darwin.write(self.fd, $0.baseAddress! + offset, bytes.count - offset)
      }
      if written <= 0 {
        return
      }
      offset += written
    }
  }

  func send(_ text: String) {
    self.send(Array(text.utf8))
  }

  // MARK: - Reading

  /// Reads once from the socket. Returns `false` on EOF, timeout or error.
  @discardableResult
  private func fill() -> Bool {
    guard self.fd >= 0, !self.reachedEOF else {
      return false
    }
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    let count = chunk.withUnsafeMutableBytes { Darwin.read(self.fd, $0.baseAddress, $0.count) }
    if count > 0 {
      self.buffer.append(contentsOf: chunk[0..<count])
      return true
    }
    // EOF, or the peer closed with unread data and the OS answered with a reset.
    if count == 0 || (count < 0 && [ECONNRESET, EPIPE, ENOTCONN].contains(errno)) {
      self.reachedEOF = true
    }
    return false
  }

  private static func index(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count else {
      return nil
    }
    for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
      if Array(haystack[start..<(start + needle.count)]) == needle {
        return start
      }
    }
    return nil
  }

  /// Reads one response (head + body). Returns `nil` if the connection closes or times out
  /// before a complete head arrived. `head: true` means "response to a HEAD request": no body
  /// is read even if `Content-Length` is present.
  func readResponse(head: Bool = false) -> RawResponse? {
    let delimiter: [UInt8] = [13, 10, 13, 10]
    var headEnd: Int? = nil
    while headEnd == nil {
      headEnd = RawClient.index(of: delimiter, in: self.buffer)
      if headEnd == nil && !self.fill() {
        return nil
      }
    }
    let headText = String(decoding: self.buffer[0..<headEnd!], as: UTF8.self)
    self.buffer.removeSubrange(0..<(headEnd! + 4))
    var lines = headText.components(separatedBy: "\r\n")
    let statusLine = lines.removeFirst()
    var fields = [(name: String, value: String)]()
    for line in lines {
      if let colon = line.firstIndex(of: ":") {
        fields.append((name: String(line[line.startIndex..<colon]),
                       value: line[line.index(after: colon)...]
                                .trimmingCharacters(in: .whitespaces)))
      }
    }
    var response = RawResponse(statusLine: statusLine, headerFields: fields, body: [])
    let status = response.status
    if head || (100..<200).contains(status) || status == 204 || status == 304 {
      return response
    }
    if let length = response.header("content-length").flatMap({ Int($0) }) {
      while self.buffer.count < length && self.fill() {}
      let take = min(length, self.buffer.count)
      response.body = Array(self.buffer[0..<take])
      self.buffer.removeSubrange(0..<take)
    } else {
      while self.fill() {}
      response.body = self.buffer
      self.buffer.removeAll()
    }
    return response
  }

  /// Reads exactly `count` bytes (used for WebSocket frames). `nil` on EOF/timeout.
  func readBytes(_ count: Int) -> [UInt8]? {
    while self.buffer.count < count {
      if !self.fill() {
        return nil
      }
    }
    let result = Array(self.buffer[0..<count])
    self.buffer.removeSubrange(0..<count)
    return result
  }

  /// Reads until EOF or until nothing arrives for `timeout` seconds.
  func readToEnd(timeout: TimeInterval = 1) -> [UInt8] {
    self.setReceiveTimeout(timeout)
    while self.fill() {}
    let result = self.buffer
    self.buffer.removeAll()
    return result
  }

  /// Waits up to `timeout` seconds for the peer to close the connection.
  func waitForClose(timeout: TimeInterval = 1) -> Bool {
    self.setReceiveTimeout(timeout)
    while self.fill() {}
    return self.reachedEOF
  }
}

// MARK: - Convenience request helpers

extension RawClient {

  /// Builds the text of an HTTP request.
  static func requestText(_ method: String,
                          _ path: String,
                          version: String = "HTTP/1.1",
                          headers: [String] = [],
                          body: [UInt8]? = nil) -> [UInt8] {
    var text = "\(method) \(path) \(version)\r\nHost: localhost\r\n"
    for header in headers {
      text += header + "\r\n"
    }
    if let body, !headers.contains(where: { $0.lowercased().hasPrefix("content-length") ||
                                            $0.lowercased().hasPrefix("transfer-encoding") }) {
      text += "Content-Length: \(body.count)\r\n"
    }
    text += "\r\n"
    return Array(text.utf8) + (body ?? [])
  }

  /// Sends one request on a fresh connection and returns the response.
  /// By default the request carries `Connection: close`.
  @discardableResult
  static func request(_ method: String,
                      _ path: String,
                      port: Int,
                      version: String = "HTTP/1.1",
                      headers: [String] = ["Connection: close"],
                      body: [UInt8]? = nil,
                      timeout: TimeInterval = 3) throws -> RawResponse {
    let client = try RawClient(port: port, timeout: timeout)
    client.send(requestText(method, path, version: version, headers: headers, body: body))
    guard let response = client.readResponse(head: method == "HEAD") else {
      throw RawClientError.noResponse("\(method) \(path)")
    }
    return response
  }

  @discardableResult
  static func get(_ path: String,
                  port: Int,
                  headers: [String] = ["Connection: close"],
                  timeout: TimeInterval = 3) throws -> RawResponse {
    return try request("GET", path, port: port, headers: headers, timeout: timeout)
  }
}
