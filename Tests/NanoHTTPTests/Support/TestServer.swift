//
//  TestServer.swift
//  NanoHTTPTests
//
//  Test support: start a server on an ephemeral loopback port, process-level helpers.
//
//  Tests must never bind a fixed port (8080 etc.): a busy port would make them fail (or worse,
//  silently pass) depending on what else runs on the machine, and fixed ports prevent parallel
//  test runs.
//

import XCTest
import Darwin
@testable import NanoHTTP

/// Starts a server on an ephemeral port, bound to loopback only, runs `body`, then stops the
/// server. `configure` runs *before* the server starts, so routes are in place.
@discardableResult
func withTestServer<T>(configure: (NanoHTTPServer) -> Void = { _ in },
                       _ body: (NanoHTTPServer, Int) throws -> T) throws -> T {
  let server = NanoHTTPServer()
  configure(server)
  try server.start(0)
  defer {
    server.stop()
  }
  let port = try server.port()
  return try body(server, port)
}

/// Number of file descriptors currently open in this process (includes the descriptor used
/// for the listing itself, which is a constant offset, so compare *differences*).
func openFileDescriptorCount() -> Int {
  return (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

/// Raises the soft `RLIMIT_NOFILE` so tests that open many sockets don't depend on the shell's
/// default limit.
func raiseFileDescriptorLimit(to wanted: rlim_t = 4096) {
  var limit = rlimit()
  guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
    return
  }
  let target = min(wanted, limit.rlim_max)
  if limit.rlim_cur < target {
    limit.rlim_cur = target
    setrlimit(RLIMIT_NOFILE, &limit)
  }
}

/// Lowers the soft descriptor limit and fills *every* free descriptor slot below it, except
/// `free` of them, so the next `free` socket()/accept()/open() calls succeed and the one after
/// that fails with EMFILE. Returns a closure that restores the limit and releases the fillers.
func exhaustFileDescriptors(leaving free: Int) -> () -> Void {
  var original = rlimit()
  getrlimit(RLIMIT_NOFILE, &original)
  let listing = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
  let highest = listing.compactMap { Int($0) }.max() ?? 0
  var limited = original
  limited.rlim_cur = rlim_t(highest + 1 + free + 8)
  setrlimit(RLIMIT_NOFILE, &limited)
  var fillers = [Int32]()
  while true {
    let descriptor = open("/dev/null", O_RDONLY)
    if descriptor < 0 {
      break
    }
    fillers.append(descriptor)
  }
  for _ in 0..<free where !fillers.isEmpty {
    close(fillers.removeLast())
  }
  return {
    var restored = original
    setrlimit(RLIMIT_NOFILE, &restored)
    fillers.forEach { close($0) }
  }
}

/// A `NanoSocket` that reads from an in-memory byte sequence (backed by an unlinked temp file).
/// Reads past the end fail with EOF. Use it to feed bytes to `NanoHTTPParser` or `WebSocketSession`
/// without a real connection. Any size works (unlike a pipe, which caps at the pipe buffer).
final class FileSocket: NanoSocket {
  init(_ bytes: [UInt8]) {
    let path = NSTemporaryDirectory() + "nanohttp-test-" + UUID().uuidString
    FileManager.default.createFile(atPath: path, contents: Data(bytes))
    let descriptor = open(path, O_RDONLY)
    unlink(path)
    super.init(socketFileDescriptor: descriptor)
  }

  convenience init(_ text: String) {
    self.init(Array(text.utf8))
  }
}

/// A writer for `NanoHTTPResponse.Body.custom` that captures what the handler writes.
final class CapturingWriter: NanoHTTPResponseBodyWriter {
  private(set) var bytes = [UInt8]()

  func write(_ file: String.File) throws {
    var chunk = [UInt8](repeating: 0, count: 4096)
    while case let count = try file.read(&chunk), count > 0 {
      self.bytes.append(contentsOf: chunk[0..<count])
    }
  }

  func write(_ data: ArraySlice<UInt8>) throws {
    self.bytes.append(contentsOf: data)
  }

  func write(_ data: Data) throws {
    self.bytes.append(contentsOf: data)
  }

  var text: String {
    return String(decoding: self.bytes, as: UTF8.self)
  }
}

extension NanoHTTPResponse {
  /// The body bytes of a response whose body is produced by `.custom`, `.text`, `.html`, `.data`
  /// or `.json`, obtained without any socket.
  func capturedBody() -> String {
    let writer = CapturingWriter()
    switch self.body {
      case .custom(let produce, _):
        try? produce(writer)
      default:
        let (_, produce) = (try? self.body.content()) ?? (nil, nil)
        try? produce?(writer)
    }
    return writer.text
  }
}

/// Files for file-serving tests:
///
///     <root>/secret.txt                 <- must never be reachable through the public directory
///     <root>/public/hello.txt           <- "hello"
///     <root>/public/sub/nested.txt
///     <root>/public/<xssName>           <- file whose *name* is an HTML payload
///     <root>/public/escape.txt          <- symlink to ../secret.txt (leaves the directory)
///     <root>/public/outerdir            <- symlink to .. (a directory link that leaves it)
///     <root>/public/alias.txt           <- symlink to hello.txt (stays inside)
///     <root>/public/my..file.txt        <- a legitimate name that merely contains ".."
///     <root>/public-link                <- symlink to public (a shared directory given as a link)
final class FileFixture {
  static let secret = "TOP-SECRET-DO-NOT-SERVE"
  static let xssName = "<img src=x onerror=alert(1)>.txt" // a file name cannot contain "/"

  let root: String
  let publicDir: String

  var helloFile: String {
    return self.publicDir + "/hello.txt"
  }

  init() throws {
    let manager = FileManager.default
    self.root = NSTemporaryDirectory() + "NanoHTTPTests-" + UUID().uuidString
    self.publicDir = self.root + "/public"
    try manager.createDirectory(atPath: self.publicDir + "/sub", withIntermediateDirectories: true)
    try FileFixture.secret.write(toFile: self.root + "/secret.txt", atomically: true, encoding: .utf8)
    try "hello".write(toFile: self.publicDir + "/hello.txt", atomically: true, encoding: .utf8)
    try "nested".write(toFile: self.publicDir + "/sub/nested.txt", atomically: true, encoding: .utf8)
    try "xss".write(toFile: self.publicDir + "/" + FileFixture.xssName, atomically: true, encoding: .utf8)
    try manager.createSymbolicLink(atPath: self.publicDir + "/escape.txt",
                                   withDestinationPath: "../secret.txt")
    try manager.createSymbolicLink(atPath: self.publicDir + "/outerdir", withDestinationPath: "..")
    try manager.createSymbolicLink(atPath: self.publicDir + "/alias.txt", withDestinationPath: "hello.txt")
    try "dotted".write(toFile: self.publicDir + "/my..file.txt", atomically: true, encoding: .utf8)
    try manager.createSymbolicLink(atPath: self.root + "/public-link", withDestinationPath: "public")
  }

  func remove() {
    try? FileManager.default.removeItem(atPath: self.root)
  }
}

/// Waits until `condition` holds, for at most `timeout` seconds.
@discardableResult
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
  let end = Date(timeIntervalSinceNow: timeout)
  while Date() < end {
    if condition() {
      return true
    }
    usleep(20_000)
  }
  return condition()
}

/// The id of the calling thread.
func currentThreadID() -> UInt64 {
  var id: UInt64 = 0
  pthread_threadid_np(nil, &id)
  return id
}

/// The number of threads of this process.
func processThreadCount() -> Int {
  var list: thread_act_array_t?
  var count = mach_msg_type_number_t(0)
  guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
    return -1
  }
  for index in 0..<Int(count) {
    mach_port_deallocate(mach_task_self_, list[index])
  }
  vm_deallocate(mach_task_self_,
                vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
  return Int(count)
}

/// The number of threads of this process once it has stopped changing: threads of earlier tests (pools
/// that were closed, dispatch workers) need a moment to end, and would make a baseline too high.
func settledThreadCount() -> Int {
  var last = processThreadCount()
  var unchanged = 0
  let end = Date(timeIntervalSinceNow: 3)
  while unchanged < 4 && Date() < end {
    usleep(50_000)
    let now = processThreadCount()
    unchanged = now == last ? unchanged + 1 : 0
    last = now
  }
  return last
}
