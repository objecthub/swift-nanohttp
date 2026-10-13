//
//  NanoSocket.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `Socket` of framework `Swifter` by Damian Kołakowski.
//
//  Copyright © 2014-2016 Damian Kołakowski. All rights reserved.
//  Copyright © 2024 Matthias Zenger. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  * Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
//
//  * Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
//  * Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software without
//    specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
//  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
//  ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import Foundation


/// A socket: a listening socket (see ``tcpSocketForListen(_:_:backlog:)``) or one
/// end of a connection. It reads and writes bytes and lines, sends files, and is
/// where the server's connections end up.
///
/// It can be used from several threads. In particular `close()` can be called while
/// other threads read or write: they fail or return, and the file descriptor is not
/// reused while any of them is running. Operations on a closed socket throw an error.
/// Several threads that write at the same time are not
/// synchronized with each other: the bytes of their writes may be mixed, so serialize
/// writes if a connection is written by more than one thread (``NanoWebSocketSession``
/// does).
///
/// Sockets are equal only if they are the same object.
open class NanoSocket: Hashable, Equatable, NanoHTTPResponseBodyWriter {
  
  // Constants
  static let kBufferLength = 1024
  
  /// Upper bound for the size of one read when a number of bytes is requested.
  static let kChunkLength = 64 * 1024
  private static let CR: UInt8 = 13
  private static let NL: UInt8 = 10
  
  /// The socket file descriptor
  let socketFileDescriptor: Int32
  
  /// Guards `closed` and `activeOperations`; signaled when the last running
  /// operation has ended.
  private let condition = NSCondition()
  
  /// Is set to `true` as soon as the socket is being closed
  private var closed = false
  
  /// What has been read from the connection but not consumed yet: bytes
  /// `inputStart..<inputEnd` of `input`. Reading in blocks costs a system call for a
  /// few hundred bytes instead of one for every byte. Only the thread that reads the
  /// socket uses these (a socket is read by one thread at a time).
  private var input = [UInt8]()
  private var inputStart = 0
  private var inputEnd = 0
  private static let inputCapacity = 16 * 1024
  
  /// The number of operations (reads, writes, ...) that are using the descriptor right now
  private var activeOperations = 0
  
  private static let closedDescription = String(cString: strerror(EBADF))
  
  /// Initializer
  public init(socketFileDescriptor: Int32) {
    self.socketFileDescriptor = socketFileDescriptor
  }
  
  deinit {
    self.close()
  }
  
  /// Sockets are compared by identity, not by file descriptor number: the number of a closed
  /// socket is handed out again, and a stale socket must never be taken for the new one that
  /// happens to have the same number.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  /// Sockets are equal if they are the same object (not if they have the same descriptor number).
  public static func == (socket1: NanoSocket, socket2: NanoSocket) -> Bool {
    return socket1 === socket2
  }
  
  /// Is `true` once the socket has been closed (or is being closed).
  var isClosed: Bool {
    self.condition.lock()
    defer {
      self.condition.unlock()
    }
    return self.closed
  }
  
  /// Runs `body` with the descriptor of this socket and keeps the socket from being released
  /// while `body` runs. Throws `closedError` if the socket is already closed.
  ///
  /// This is what makes closing safe while other threads read or write: the number of a closed
  /// descriptor is handed out again by the system, so an operation that still used it would read
  /// from or write to an unrelated socket.
  private func withDescriptor<T>(closedError: @autoclosure () -> NanoSocketError,
                                 _ body: (Int32) throws -> T) throws -> T {
    self.condition.lock()
    if self.closed {
      self.condition.unlock()
      throw closedError()
    }
    self.activeOperations += 1
    self.condition.unlock()
    defer {
      self.condition.lock()
      self.activeOperations -= 1
      if self.activeOperations == 0 {
        self.condition.broadcast()
      }
      self.condition.unlock()
    }
    return try body(self.socketFileDescriptor)
  }
  
  /// Closes the socket. Closing is idempotent and may be called from any thread, also while other
  /// threads are reading from or writing to the socket.
  ///
  /// The connection is shut down first, which makes operations that are blocked right now fail
  /// instead of waiting for the peer; then `close` waits (for at most two seconds) until all
  /// running operations have returned, and only then releases the descriptor. Operations started
  /// afterwards fail without touching the descriptor.
  public func close() {
    self.condition.lock()
    if self.closed {
      self.condition.unlock()
      return
    }
    self.closed = true
    self.condition.unlock()
    _ = Darwin.shutdown(self.socketFileDescriptor, SHUT_RDWR)
    let deadline = Date(timeIntervalSinceNow: 2)
    self.condition.lock()
    while self.activeOperations > 0 && self.condition.wait(until: deadline) {}
    self.condition.unlock()
    NanoSocket.close(self.socketFileDescriptor)
  }
  
  /// Closes the connection after the peer had a chance to read everything sent so far.
  ///
  /// Closing a socket that still has unread incoming data makes TCP answer with a reset,
  /// and a reset makes the peer discard data it has not read yet, such as an error response.
  /// Use this after answering a request that was refused before it was read completely:
  /// the sending direction is shut down (the peer sees the end of the response), whatever
  /// the peer still sends is read and dropped for at most `timeout` seconds and `limit`
  /// bytes, and then the socket is closed.
  ///
  /// - Parameters:
  ///   - timeout: The longest time to wait for the peer to finish, in seconds.
  ///   - limit: The most data to read and drop, in bytes.
  func closeAfterDraining(timeout: TimeInterval = 1, limit: Int = 4 * 1024 * 1024) {
    self.inputStart = 0 // what is in the buffer is dropped like the rest
    self.inputEnd = 0
    try? self.withDescriptor(closedError: .recvFailed(Self.closedDescription)) { descriptor in
      _ = Darwin.shutdown(descriptor, SHUT_WR)
      let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)
      var drained = 0
      while drained < limit {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline {
          break
        }
        let remaining = max(0.001,
                            Double(deadline - now) / 1_000_000_000) // 0 would mean "no timeout"
        var wait = timeval(tv_sec: Int(remaining),
                           tv_usec: Int32((remaining - remaining.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
          drained += count
        } else if count < 0 && errno == EINTR {
          continue
        } else {
          break
        }
      }
    }
    self.close()
  }
  
  /// The `timeval` for a timeout in seconds; a missing or non-positive timeout is zero,
  /// which means "no timeout" to the system. A positive timeout is never rounded down to zero.
  private static func makeTimeval(_ seconds: TimeInterval?) -> timeval {
    guard let seconds, seconds > 0 else {
      return timeval(tv_sec: 0, tv_usec: 0)
    }
    let whole = seconds.rounded(.down)
    let micro = Int32((seconds - whole) * 1_000_000)
    return timeval(tv_sec: Int(whole), tv_usec: whole == 0 && micro == 0 ? 1 : micro)
  }
  
  /// Limits how long a read waits for data. A read that waits longer throws
  /// ``NanoSocketError/timedOut``. `nil` (or zero or less) waits forever, which is how
  /// a socket starts. Does nothing on a closed socket.
  public func setReceiveTimeout(_ seconds: TimeInterval?) {
    var value = Self.makeTimeval(seconds)
    guard self.timeoutChanged(receive: true, value) else {
      return
    }
    _ = try? self.withDescriptor(closedError: .recvFailed(Self.closedDescription)) { descriptor in
      setsockopt(descriptor,
                 SOL_SOCKET, SO_RCVTIMEO,
                 &value,
                 socklen_t(MemoryLayout<timeval>.size))
    }
  }
  
  /// Limits how long a write waits for the peer to take data: a write that makes
  /// no progress for that long throws ``NanoSocketError/timedOut``. `nil` (or zero
  /// or less) waits forever, which is how a socket starts. Does nothing on a closed socket.
  public func setSendTimeout(_ seconds: TimeInterval?) {
    var value = Self.makeTimeval(seconds)
    guard self.timeoutChanged(receive: false, value) else {
      return
    }
    _ = try? self.withDescriptor(closedError: .writeFailed(Self.closedDescription)) { descriptor in
      setsockopt(descriptor,
                 SOL_SOCKET,
                 SO_SNDTIMEO,
                 &value,
                 socklen_t(MemoryLayout<timeval>.size))
    }
  }
  
  /// The timeouts that were set last (guarded by `condition`), so that a timeout that
  /// does not change, as the same one is set for every request of a connection, costs
  /// no system call.
  private var receiveTimeoutValue = timeval(tv_sec: 0, tv_usec: 0)
  private var sendTimeoutValue = timeval(tv_sec: 0, tv_usec: 0)
  
  /// Stores the receive or send timeout `new` and tells whether it is a change.
  private func timeoutChanged(receive: Bool, _ new: timeval) -> Bool {
    self.condition.lock()
    defer {
      self.condition.unlock()
    }
    let current = receive ? self.receiveTimeoutValue : self.sendTimeoutValue
    if current.tv_sec == new.tv_sec && current.tv_usec == new.tv_usec {
      return false
    }
    if receive {
      self.receiveTimeoutValue = new
    } else {
      self.sendTimeoutValue = new
    }
    return true
  }
  
  /// Waits until a read would not block: until data has arrived, or the peer has closed the
  /// connection (the read then reports it), or the socket is closed.
  ///
  /// - Parameter timeout: The longest time to wait, in seconds; `nil` (or zero or less)
  ///                      waits forever.
  /// - Returns: `true` if a read will not block; `false` if the timeout passed first.
  /// - Throws: `NanoSocketError.recvFailed` if the socket is closed or cannot be polled.
  public func waitUntilReadable(timeout: TimeInterval?) throws -> Bool {
    if self.hasBufferedData {
      return true
    }
    return try self.withDescriptor(closedError: .recvFailed(Self.closedDescription)) { descriptor in
      var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      var deadline: UInt64? = nil
      if let timeout, timeout > 0 {
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
      }
      while true {
        var milliseconds: Int32 = -1
        if let deadline {
          let now = DispatchTime.now().uptimeNanoseconds
          if now >= deadline {
            return false
          }
          milliseconds = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
        }
        let result = poll(&poller, 1, milliseconds)
        if result > 0 {
          return true
        } else if result < 0 && errno != EINTR {
          throw NanoSocketError.recvFailed(Self.errnoDescription)
        }
      }
    }
  }
  
  /// Waits until there is something to read, without reading it: data (also data that has
  /// been read from the connection already and is waiting in the buffer), or the end of the
  /// connection, which the next read reports. Waits for as long as the receive timeout
  /// (see ``setReceiveTimeout(_:)``), and forever without one.
  ///
  /// This is how a thread that serves one connection waits for the next message of a session:
  /// in contrast to ``waitUntilReadable(timeout:)`` it takes no system call more than a
  /// read would, and does not need the timeout to be changed.
  ///
  /// - Returns: `true` if a read will not wait; `false` if the receive timeout has passed.
  /// - Throws: `NanoSocketError.recvFailed` if the socket is closed or fails.
  func awaitData() throws -> Bool {
    if self.hasBufferedData {
      return true
    }
    return try self.withDescriptor(closedError: .recvFailed(Self.closedDescription)) { descriptor in
      var byte: UInt8 = 0
      while true {
        if recv(descriptor, &byte, 1, MSG_PEEK) >= 0 {
          return true
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
          return false
        } else if errno != EINTR {
          throw NanoSocketError.recvFailed(Self.errnoDescription)
        }
      }
    }
  }
  
  /// Makes reads, writes and `accept` of the socket not wait (`true`: they fail with
  /// `EAGAIN` instead) or wait (`false`, which is how a socket starts). Systems differ
  /// in whether a connection that is accepted from a non-blocking listening socket
  /// inherits the setting, so the server sets every accepted connection to blocking.
  func setNonBlocking(_ nonBlocking: Bool) {
    _ = try? self.withDescriptor(closedError: .recvFailed(Self.closedDescription)) { descriptor in
      NanoSocket.setNonBlocking(descriptor, nonBlocking)
    }
  }
  
  private static func setNonBlocking(_ descriptor: Int32, _ nonBlocking: Bool) {
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 {
      _ = fcntl(descriptor, F_SETFL, nonBlocking ? flags | O_NONBLOCK : flags & ~O_NONBLOCK)
    }
  }
  
  /// The local port of the socket; for a listening socket started with port 0, the port
  /// that the system chose.
  public func port() throws -> in_port_t {
    return try self.withDescriptor(closedError: .getSockNameFailed(Self.closedDescription)) { descriptor in
      var addr = sockaddr_in()
      return try withUnsafePointer(to: &addr) { pointer in
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        if getsockname(descriptor, UnsafeMutablePointer(OpaquePointer(pointer)), &len) != 0 {
          throw NanoSocketError.getSockNameFailed(Self.errnoDescription)
        }
        let sin_port = pointer.pointee.sin_port
        #if os(Linux)
        return ntohs(sin_port)
        #else
        return Int(OSHostByteOrder()) != OSLittleEndian ? sin_port.littleEndian : sin_port.bigEndian
        #endif
      }
    }
  }
  
  /// Whether the local address of the socket is an IPv4 address.
  public func isIPv4() throws -> Bool {
    return try self.withDescriptor(closedError: .getSockNameFailed(Self.closedDescription)) { descriptor in
      var addr = sockaddr_in()
      return try withUnsafePointer(to: &addr) { pointer in
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        if getsockname(descriptor, UnsafeMutablePointer(OpaquePointer(pointer)), &len) != 0 {
          throw NanoSocketError.getSockNameFailed(Self.errnoDescription)
        }
        return Int32(pointer.pointee.sin_family) == AF_INET
      }
    }
  }
  
  /// Writes the UTF-8 bytes of the string. Blocks until all bytes are written;
  /// throws if the peer went away.
  public func writeUTF8(_ string: String) throws {
    try self.writeUInt8(ArraySlice(string.utf8))
  }
  
  /// Writes bytes. Blocks until all bytes are written; throws if the peer went away.
  public func writeUInt8(_ data: [UInt8]) throws {
    try self.writeUInt8(ArraySlice(data))
  }
  
  /// Writes bytes. Blocks until all bytes are written; throws if the peer went away.
  public func writeUInt8(_ data: ArraySlice<UInt8>) throws {
    try data.withUnsafeBufferPointer {
      try self.writeBuffer($0.baseAddress!, length: data.count)
    }
  }
  
  /// Writes bytes. Blocks until all bytes are written; throws if the peer went away.
  public func writeData(_ data: NSData) throws {
    try self.writeBuffer(data.bytes, length: data.length)
  }
  
  /// Writes bytes. Blocks until all bytes are written; throws if the peer went away.
  public func writeData(_ data: Data) throws {
    try data.withUnsafeBytes { (body: UnsafeRawBufferPointer) -> Void in
      if let baseAddress = body.baseAddress, body.count > 0 {
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        try self.writeBuffer(pointer, length: data.count)
      }
    }
  }
  
  private func writeBuffer(_ pointer: UnsafeRawPointer, length: Int) throws {
    try self.withDescriptor(closedError: .writeFailed(Self.closedDescription)) { descriptor in
      var sent = 0
      while sent < length {
        #if os(Linux)
        let result = send(descriptor, pointer + sent, Int(length - sent), Int32(MSG_NOSIGNAL))
        #else
        let result = Darwin.write(descriptor, pointer + sent, Int(length - sent))
        #endif
        if result < 0 && errno == EINTR {
          continue
        }
        if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
          throw NanoSocketError.timedOut // the send timeout has passed
        }
        if result <= 0 {
          throw NanoSocketError.writeFailed(Self.errnoDescription)
        }
        sent += result
      }
    }
  }
  
  /// Read a single byte off the socket. This method is optimized for reading
  /// a single byte. For reading multiple bytes, use read(length:), which will
  /// pre-allocate heap space and read directly into it.
  ///
  /// - Returns: A single byte
  /// - Throws: SocketError.recvFailed if unable to read from the socket
  open func read() throws -> UInt8 {
    if self.inputStart == self.inputEnd {
      try self.fillInput()
    }
    let byte = self.input[self.inputStart]
    self.inputStart += 1
    return byte
  }
  
  /// Whether bytes have been read from the connection that nobody has consumed yet.
  /// Whoever waits for the socket to become readable (`poll`) has to look at this first:
  /// the data is not in the kernel any more.
  var hasBufferedData: Bool {
    return self.inputStart < self.inputEnd
  }
  
  /// Reads a block from the connection into the buffer: at least one byte, or an error.
  /// Only called when the buffer is empty.
  private func fillInput() throws {
    if self.input.isEmpty {
      self.input = [UInt8](repeating: 0, count: Self.inputCapacity)
    }
    let count = try self.withDescriptor(closedError: .recvFailed(Self.closedDescription)) { descriptor -> Int in
      while true {
        let count = self.input.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
          return count
        }
        if count < 0 && errno == EINTR {
          continue
        }
        throw Self.readFailure(count)
      }
    }
    self.inputStart = 0
    self.inputEnd = count
  }
  
  /// Reads exactly `length` bytes from this socket.
  ///
  /// The result grows with the data that actually arrives, in chunks of at most
  /// `kChunkLength` bytes. A caller-supplied `length` that is far larger than what the peer
  /// sends therefore does not reserve that much memory up front.
  ///
  /// - Parameter length: The number of bytes to read; must not be negative.
  /// - Returns: A buffer containing exactly `length` bytes.
  /// - Throws: `NanoSocketError.recvFailed` if `length` is negative or the socket fails or
  ///     reaches end-of-file before `length` bytes were read.
  open func read(length: Int) throws -> [UInt8] {
    guard length >= 0 else {
      throw NanoSocketError.recvFailed("negative length")
    }
    var result = [UInt8]()
    // First what has been read already ...
    let buffered = min(self.inputEnd - self.inputStart, length)
    if buffered > 0 {
      result.append(contentsOf: self.input[self.inputStart..<(self.inputStart + buffered)])
      self.inputStart += buffered
    }
    var remaining = length - result.count
    if remaining == 0 {
      return result
    }
    if remaining < Self.inputCapacity {
      // ... a little more: read a block, which probably has more of what comes next as well ...
      while remaining > 0 {
        try self.fillInput()
        let count = min(self.inputEnd - self.inputStart, remaining)
        result.append(contentsOf: self.input[self.inputStart..<(self.inputStart + count)])
        self.inputStart += count
        remaining -= count
      }
      return result
    }
    // ... and a lot: straight from the connection, without a detour through the buffer.
    return try self.withDescriptor(closedError: .recvFailed(Self.closedDescription)) { descriptor in
      var chunk = [UInt8](repeating: 0, count: min(remaining, NanoSocket.kChunkLength))
      while remaining > 0 {
        let wanted = min(chunk.count, remaining)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
        if count < 0 && errno == EINTR {
          continue
        }
        guard count > 0 else {
          throw Self.readFailure(count)
        }
        result.append(contentsOf: chunk[0..<count])
        remaining -= count
      }
      return result
    }
  }
  
  /// Reads a line: bytes up to a line feed, without the line break; carriage returns
  /// and other control characters are dropped, and every other byte is taken as one
  /// character (Latin-1). The length of the line is not limited: use ``NanoHTTPParser``
  /// for requests, which has limits.
  public func readLine() throws -> String {
    var characters: String = ""
    var index: UInt8 = 0
    repeat {
      index = try self.read()
      if index > NanoSocket.CR {
        characters.append(Character(UnicodeScalar(index)))
      }
    } while index != NanoSocket.NL
    return characters
  }
  
  /// The IP address of the peer in its text form.
  public func peername() throws -> String {
    var addr = sockaddr(), len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
    try self.withDescriptor(closedError: .getPeerNameFailed(Self.closedDescription)) { descriptor in
      if getpeername(descriptor, &addr, &len) != 0 {
        throw NanoSocketError.getPeerNameFailed(Self.errnoDescription)
      }
    }
    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    if getnameinfo(&addr, len, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) != 0 {
      throw NanoSocketError.getNameInfoFailed(Self.errnoDescription)
    }
    return String(cString: hostBuffer)
  }
  
  /// Makes writes to a socket whose peer has gone fail with an error instead of raising `SIGPIPE`.
  public class func setNoSigPipe(_ socket: Int32) {
    #if os(Linux)
    // There is no SO_NOSIGPIPE in Linux (nor some other systems). You can instead use the
    // MSG_NOSIGNAL flag when calling send(), or use signal(SIGPIPE, SIG_IGN) to make your
    // entire application ignore SIGPIPE.
    #else
    // Prevents crashes when blocking calls are pending and the app is paused ( via Home button ).
    var no_sig_pipe: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &no_sig_pipe, socklen_t(MemoryLayout<Int32>.size))
    #endif
  }
  
  /// Closes a file descriptor. Prefer ``close()`` for the sockets of this class.
  public class func close(_ socket: Int32) {
    #if os(Linux)
    _ = Glibc.close(socket)
    #else
    _ = Darwin.close(socket)
    #endif
  }
  
  /// Sends the content of a file, from its beginning to its end. Uses `sendfile` where the system has it.
  public func writeFile(_ file: NanoFile) throws {
    try self.withDescriptor(closedError: .writeFailed(Self.closedDescription)) { descriptor in
      var offset: off_t = 0
      var sf: sf_hdtr = sf_hdtr()
      #if os(iOS) || os(tvOS) || os (Linux)
      let result = sendfileImpl(file.pointer, descriptor, 0, &offset, &sf, 0)
      #else
      let result = sendfile(fileno(file.pointer), descriptor, 0, &offset, &sf, 0)
      #endif
      if result == -1 {
        if errno == EAGAIN || errno == EWOULDBLOCK {
          throw NanoSocketError.timedOut // the send timeout has passed
        }
        throw NanoSocketError.writeFailed("sendfile: " + Self.errnoDescription)
      }
    }
  }
  
  /// Sends `length` bytes of a file, from `offset` on, and returns how many were sent:
  /// fewer than `length` if the file ends earlier. Uses `sendfile` where the system has
  /// it (the bytes do not pass through this process). Exactly the bytes that were asked
  /// for are sent, also if the file grows meanwhile, which a response that has a length
  /// has to rely on.
  ///
  /// - Throws: `NanoSocketError.timedOut` if the peer takes nothing for as long as the
  ///           send timeout, or another `NanoSocketError` if the connection fails.
  @discardableResult
  public func writeFile(_ file: NanoFile, offset: Int64, length: Int64) throws -> Int64 {
    guard offset >= 0, length >= 0 else {
      throw NanoSocketError.writeFailed("negative offset or length")
    }
    #if os(iOS) || os(tvOS) || os(Linux)
    return try self.writeFileByReading(file, offset: offset, length: length)
    #else
    return try self.withDescriptor(closedError: .writeFailed(Self.closedDescription)) { descriptor in
      var sent: Int64 = 0
      while sent < length {
        var count = off_t(length - sent)
        let result = sendfile(fileno(file.pointer), descriptor, off_t(offset + sent), &count, nil, 0)
        sent += Int64(count)
        if result == 0 {
          if count == 0 {
            break // the file ends before `length`
          }
          continue
        }
        if errno == EINTR {
          continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          if count == 0 {
            throw NanoSocketError.timedOut // the send timeout has passed without progress
          }
          continue
        }
        throw NanoSocketError.writeFailed("sendfile: " + Self.errnoDescription)
      }
      return sent
    }
    #endif
  }
  
  /// The portable way to send a part of a file: read it in blocks and write them.
  /// Systems that have no `sendfile` use this; it is separate so that it can be
  /// tested on the others.
  func writeFileByReading(_ file: NanoFile, offset: Int64, length: Int64) throws -> Int64 {
    guard fseeko(file.pointer, off_t(offset), SEEK_SET) == 0 else {
      throw NanoSocketError.writeFailed("seek: " + Self.errnoDescription)
    }
    var sent: Int64 = 0
    var block = [UInt8](repeating: 0, count: 64 * 1024)
    while sent < length {
      let wanted = Int(min(Int64(block.count), length - sent))
      let count = fread(&block, 1, wanted, file.pointer)
      if count == 0 {
        break // the file ends before `length`
      }
      try self.writeUInt8(block[0..<count])
      sent += Int64(count)
    }
    return sent
  }
  
  /// Sends a part of a file, see ``writeFile(_:offset:length:)``.
  public func write(_ file: NanoFile, offset: Int64, length: Int64) throws {
    try self.writeFile(file, offset: offset, length: length)
  }
  
  /// Creates a listening TCP socket.
  ///
  /// - Parameters:
  ///   - port: The port to listen at; `0` lets the system choose a free port (see ``port()``).
  ///   - address: Where to listen: ``NanoHTTPServerIO/NanoListenAddress/loopback`` (an IPv4
  ///       socket for `127.0.0.1`), ``NanoHTTPServerIO/NanoListenAddress/allInterfaces`` (an
  ///       IPv6 socket for `::` that also accepts IPv4 connections), or one address, which also decides whether the socket is an IPv4 or an IPv6
  ///       socket. An address that cannot be parsed, or cannot be bound on this machine, makes this
  ///       method throw `NanoSocketError.bindFailed`; it never falls back to another address.
  ///   - backlog: The length of the queue of connections that wait to be accepted.
  /// - Returns: The listening socket.
  /// - Throws: `NanoSocketError` if the socket cannot be created, bound or put into the listening state.
  public class func tcpSocketForListen(_ port: in_port_t,
                                       _ address: NanoHTTPServerIO.NanoListenAddress = .loopback,
                                       backlog: Int32 = SOMAXCONN) throws -> NanoSocket {
    // Which kind of socket, and where it is bound: decided before a descriptor is created, so that a
    // bad address leaves nothing to clean up.
    var ipv4 = in_addr(s_addr: in_addr_t(0))
    var ipv6 = in6addr_any
    let useIPv4: Bool
    switch address {
      case .loopback:
        ipv4.s_addr = in_addr_t(0x7f000001).bigEndian
        useIPv4 = true
      case .allInterfaces:
        useIPv4 = false
      case .address(let text):
        if text.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
          useIPv4 = true
        } else if text.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
          useIPv4 = false
        } else {
          // Binding to "any address" instead would expose the server on every network interface.
          throw NanoSocketError.bindFailed("invalid listen address \"\(text)\"")
        }
    }
    #if os(Linux)
    let socketFileDescriptor = socket(useIPv4 ? AF_INET : AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let socketFileDescriptor = socket(useIPv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
    #endif
    if socketFileDescriptor == -1 {
      throw NanoSocketError.socketCreationFailed(Self.errnoDescription)
    }
    var value: Int32 = 1
    if setsockopt(socketFileDescriptor,
                  SOL_SOCKET,
                  SO_REUSEADDR,
                  &value,
                  socklen_t(MemoryLayout<Int32>.size)) == -1 {
      let details = Self.errnoDescription
      NanoSocket.close(socketFileDescriptor)
      throw NanoSocketError.socketSettingReUseAddrFailed(details)
    }
    NanoSocket.setNoSigPipe(socketFileDescriptor)
    var bindResult: Int32 = -1
    if useIPv4 {
      #if os(Linux)
      var addr = sockaddr_in(
        sin_family: sa_family_t(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: ipv4,
        sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
      #else
      var addr = sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.stride),
        sin_family: UInt8(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: ipv4,
        sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
      #endif
      bindResult = withUnsafePointer(to: &addr) {
        bind(socketFileDescriptor,
             UnsafePointer<sockaddr>(OpaquePointer($0)),
             socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    } else {
      if address == .allInterfaces {
        // Accept IPv4 connections on the same socket, whatever the system default is.
        var off: Int32 = 0
        setsockopt(socketFileDescriptor,
                   IPPROTO_IPV6,
                   IPV6_V6ONLY,
                   &off,
                   socklen_t(MemoryLayout<Int32>.size))
      }
      #if os(Linux)
      var addr = sockaddr_in6(
        sin6_family: sa_family_t(AF_INET6),
        sin6_port: port.bigEndian,
        sin6_flowinfo: 0,
        sin6_addr: ipv6,
        sin6_scope_id: 0)
      #else
      var addr = sockaddr_in6(
        sin6_len: UInt8(MemoryLayout<sockaddr_in6>.stride),
        sin6_family: UInt8(AF_INET6),
        sin6_port: port.bigEndian,
        sin6_flowinfo: 0,
        sin6_addr: ipv6,
        sin6_scope_id: 0)
      #endif
      bindResult = withUnsafePointer(to: &addr) {
        bind(socketFileDescriptor,
             UnsafePointer<sockaddr>(OpaquePointer($0)),
             socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
    if bindResult == -1 {
      let details = Self.errnoDescription
      NanoSocket.close(socketFileDescriptor)
      throw NanoSocketError.bindFailed(details)
    } else if listen(socketFileDescriptor, backlog) == -1 {
      let details = Self.errnoDescription
      NanoSocket.close(socketFileDescriptor)
      throw NanoSocketError.listenFailed(details)
    } else {
      return NanoSocket(socketFileDescriptor: socketFileDescriptor)
    }
  }
  
  /// What happened when a connection was awaited with `acceptOutcome()`.
  enum AcceptOutcome {
    
    /// A client connected.
    case accepted(NanoSocket)
    
    /// There is no connection to accept right now (the listening socket is not blocking).
    case wouldBlock
    
    /// The attempt failed for a reason that concerns only that attempt (an interrupted call, a
    /// connection that was aborted before it could be accepted); the next attempt may succeed.
    case transient(String)
    
    /// The process or the system is out of file descriptors or memory. Accepting works again once
    /// resources are free. Connections that arrive meanwhile may be lost: macOS discards a
    /// pending connection whose `accept` failed for lack of resources.
    case exhausted(String)
    
    /// The listening socket is closed or unusable; accepting will never work again.
    case failed(String)
  }
  
  /// Waits for the next connection and reports failures in a way that tells those that merely
  /// delay accepting (`transient`, `exhausted`) from those that end it (`failed`).
  func acceptOutcome() -> AcceptOutcome {
    if self.isClosed {
      return .failed(Self.closedDescription)
    }
    var addr = sockaddr()
    var len: socklen_t = 0
    let clientSocket = accept(self.socketFileDescriptor, &addr, &len)
    if clientSocket >= 0 {
      NanoSocket.setNoSigPipe(clientSocket)
      NanoSocket.setNonBlocking(clientSocket, false)
      // Responses are written in as few pieces as possible; whatever is written is sent
      // at once, instead of waiting for the peer to acknowledge the piece before (Nagle's
      // algorithm, up to 40 ms of delay).
      var one: Int32 = 1
      setsockopt(clientSocket, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
      return .accepted(NanoSocket(socketFileDescriptor: clientSocket))
    }
    let code = errno
    let description = String(cString: strerror(code))
    switch code {
      case EAGAIN: // == EWOULDBLOCK
        return .wouldBlock
      case EINTR, ECONNABORTED, EPROTO, ETIMEDOUT:
        return .transient(description)
      case EMFILE, ENFILE, ENOBUFS, ENOMEM:
        return .exhausted(description)
      default:
        return .failed(description)
    }
  }
  
  /// Waits for a connection to this listening socket and returns the socket of the connection.
  /// Throws on every failure; the server uses a more careful variant that retries the failures that
  /// are only temporary.
  public func acceptClientSocket() throws -> NanoSocket {
    switch self.acceptOutcome() {
      case .accepted(let socket):
        return socket
      case .wouldBlock:
        throw NanoSocketError.acceptFailed(Self.errnoDescription)
      case .transient(let description), .exhausted(let description), .failed(let description):
        throw NanoSocketError.acceptFailed(description)
    }
  }
  
  /// Sends a file; see ``writeFile(_:)``.
  public func write(_ file: NanoFile) throws {
    try self.writeFile(file)
  }
  
  /// Sends bytes.
  public func write(_ data: ArraySlice<UInt8>) throws {
    try self.writeUInt8(data)
  }
  
  /// Sends bytes.
  public func write(_ data: Data) throws {
    try self.writeData(data)
  }
  
  #if os(iOS) || os(tvOS) || os (Linux)
  struct sf_hdtr { }
  
  private func sendfileImpl(_ source: UnsafeMutablePointer<FILE>,
                            _ target: Int32, _: off_t,
                            _: UnsafeMutablePointer<off_t>,
                            _: UnsafeMutablePointer<sf_hdtr>,
                            _: Int32) -> Int32 {
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
      let readResult = fread(&buffer, 1, buffer.count, source)
      guard readResult > 0 else {
        return Int32(readResult)
      }
      var writeCounter = 0
      while writeCounter < readResult {
        let writeResult = buffer.withUnsafeBytes { (ptr) -> Int in
          let start = ptr.baseAddress! + writeCounter
          let len = readResult - writeCounter
          #if os(Linux)
          return send(target, start, len, Int32(MSG_NOSIGNAL))
          #else
          return Darwin.write(target, start, len)
          #endif
        }
        guard writeResult > 0 else {
          return Int32(writeResult)
        }
        writeCounter += writeResult
      }
    }
  }
  #endif
  
  private static var errnoDescription: String {
    return String(cString: strerror(errno))
  }
  
  /// The error for a read that returned `count` (zero: the peer closed the connection; negative: it
  /// failed, which includes the receive timeout having passed).
  private static func readFailure(_ count: Int) -> NanoSocketError {
    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
      return .timedOut
    }
    return .recvFailed(count == 0 ? "connection closed by peer" : Self.errnoDescription)
  }
  
}
