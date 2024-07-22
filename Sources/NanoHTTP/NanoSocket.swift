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

public enum NanoSocketError: Error {
  case socketCreationFailed(String)
  case socketSettingReUseAddrFailed(String)
  case bindFailed(String)
  case listenFailed(String)
  case writeFailed(String)
  case getPeerNameFailed(String)
  case convertingPeerNameFailed
  case getNameInfoFailed(String)
  case acceptFailed(String)
  case recvFailed(String)
  case getSockNameFailed(String)
}

open class NanoSocket: Hashable, Equatable, NanoHTTPResponseBodyWriter {
  
  // Constants
  static let kBufferLength = 1024
  private static let CR: UInt8 = 13
  private static let NL: UInt8 = 10
  
  /// The socket file descriptor
  let socketFileDescriptor: Int32
  
  /// Is set to `true` once the socket was closed
  private var shutdown = false
  
  /// Initializer
  public init(socketFileDescriptor: Int32) {
    self.socketFileDescriptor = socketFileDescriptor
  }
  
  deinit {
    self.close()
  }
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.socketFileDescriptor)
  }
  
  public func close() {
    if shutdown {
      return
    }
    self.shutdown = true
    NanoSocket.close(self.socketFileDescriptor)
  }
  
  public func port() throws -> in_port_t {
    var addr = sockaddr_in()
    return try withUnsafePointer(to: &addr) { pointer in
      var len = socklen_t(MemoryLayout<sockaddr_in>.size)
      if getsockname(socketFileDescriptor, UnsafeMutablePointer(OpaquePointer(pointer)), &len) != 0 {
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
  
  public func isIPv4() throws -> Bool {
    var addr = sockaddr_in()
    return try withUnsafePointer(to: &addr) { pointer in
      var len = socklen_t(MemoryLayout<sockaddr_in>.size)
      if getsockname(socketFileDescriptor, UnsafeMutablePointer(OpaquePointer(pointer)), &len) != 0 {
        throw NanoSocketError.getSockNameFailed(Self.errnoDescription)
      }
      return Int32(pointer.pointee.sin_family) == AF_INET
    }
  }
  
  public func writeUTF8(_ string: String) throws {
    try self.writeUInt8(ArraySlice(string.utf8))
  }
  
  public func writeUInt8(_ data: [UInt8]) throws {
    try self.writeUInt8(ArraySlice(data))
  }
  
  public func writeUInt8(_ data: ArraySlice<UInt8>) throws {
    try data.withUnsafeBufferPointer {
      try self.writeBuffer($0.baseAddress!, length: data.count)
    }
  }
  
  public func writeData(_ data: NSData) throws {
    try self.writeBuffer(data.bytes, length: data.length)
  }
  
  public func writeData(_ data: Data) throws {
    try data.withUnsafeBytes { (body: UnsafeRawBufferPointer) -> Void in
      if let baseAddress = body.baseAddress, body.count > 0 {
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        try self.writeBuffer(pointer, length: data.count)
      }
    }
  }
  
  private func writeBuffer(_ pointer: UnsafeRawPointer, length: Int) throws {
    var sent = 0
    while sent < length {
      #if os(Linux)
      let result = send(self.socketFileDescriptor, pointer + sent, Int(length - sent), Int32(MSG_NOSIGNAL))
      #else
      let result = Darwin.write(self.socketFileDescriptor, pointer + sent, Int(length - sent))
      #endif
      if result <= 0 {
        throw NanoSocketError.writeFailed(Self.errnoDescription)
      }
      sent += result
    }
  }
  
  /// Read a single byte off the socket. This method is optimized for reading
  /// a single byte. For reading multiple bytes, use read(length:), which will
  /// pre-allocate heap space and read directly into it.
  ///
  /// - Returns: A single byte
  /// - Throws: SocketError.recvFailed if unable to read from the socket
  open func read() throws -> UInt8 {
    var byte: UInt8 = 0
    #if os(Linux)
    let count = Glibc.read(self.socketFileDescriptor as Int32, &byte, 1)
    #else
    let count = Darwin.read(self.socketFileDescriptor as Int32, &byte, 1)
    #endif
    guard count > 0 else {
      throw NanoSocketError.recvFailed(Self.errnoDescription)
    }
    return byte
  }
  
  /// Read up to `length` bytes from this socket
  ///
  /// - Parameter length: The maximum bytes to read
  /// - Returns: A buffer containing the bytes read
  /// - Throws: SocketError.recvFailed if unable to read bytes from the socket
  open func read(length: Int) throws -> [UInt8] {
    return try [UInt8](unsafeUninitializedCapacity: length) { buffer, bytesRead in
      bytesRead = try read(into: &buffer, length: length)
    }
  }
  
  /// Read up to `length` bytes from this socket into an existing buffer
  ///
  /// - Parameter into: The buffer to read into (must be at least length bytes in size)
  /// - Parameter length: The maximum bytes to read
  /// - Returns: The number of bytes read
  /// - Throws: SocketError.recvFailed if unable to read bytes from the socket
  func read(into buffer: inout UnsafeMutableBufferPointer<UInt8>, length: Int) throws -> Int {
    var offset = 0
    guard let baseAddress = buffer.baseAddress else { return 0 }
    while offset < length {
      // Compute next read length in bytes. The bytes read is never more than kBufferLength at once.
      let readLength = offset + NanoSocket.kBufferLength < length ? NanoSocket.kBufferLength : length - offset
      #if os(Linux)
      let bytesRead = Glibc.read(self.socketFileDescriptor as Int32, baseAddress + offset, readLength)
      #else
      let bytesRead = Darwin.read(self.socketFileDescriptor as Int32, baseAddress + offset, readLength)
      #endif
      guard bytesRead > 0 else {
        throw NanoSocketError.recvFailed(Self.errnoDescription)
      }
      offset += bytesRead
    }
    return offset
  }
  
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
  
  public func peername() throws -> String {
    var addr = sockaddr(), len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
    if getpeername(self.socketFileDescriptor, &addr, &len) != 0 {
      throw NanoSocketError.getPeerNameFailed(Self.errnoDescription)
    }
    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    if getnameinfo(&addr, len, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) != 0 {
      throw NanoSocketError.getNameInfoFailed(Self.errnoDescription)
    }
    return String(cString: hostBuffer)
  }
  
  public class func setNoSigPipe(_ socket: Int32) {
    #if os(Linux)
    // There is no SO_NOSIGPIPE in Linux (nor some other systems). You can instead use the MSG_NOSIGNAL flag when calling send(),
    // or use signal(SIGPIPE, SIG_IGN) to make your entire application ignore SIGPIPE.
    #else
    // Prevents crashes when blocking calls are pending and the app is paused ( via Home button ).
    var no_sig_pipe: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &no_sig_pipe, socklen_t(MemoryLayout<Int32>.size))
    #endif
  }
  
  public class func close(_ socket: Int32) {
    #if os(Linux)
    _ = Glibc.close(socket)
    #else
    _ = Darwin.close(socket)
    #endif
  }
  
  public func writeFile(_ file: String.File) throws {
    var offset: off_t = 0
    var sf: sf_hdtr = sf_hdtr()
    #if os(iOS) || os(tvOS) || os (Linux)
    let result = sendfileImpl(file.pointer, self.socketFileDescriptor, 0, &offset, &sf, 0)
    #else
    let result = sendfile(fileno(file.pointer), self.socketFileDescriptor, 0, &offset, &sf, 0)
    #endif
    if result == -1 {
      throw NanoSocketError.writeFailed("sendfile: " + Self.errnoDescription)
    }
  }
  
  /// - Parameters:
  ///   - listenAddress: String representation of the address the socket should accept
  ///       connections from. It should be in IPv4 format if forceIPv4 == true,
  ///       otherwise - in IPv6.
  public class func tcpSocketForListen(_ port: in_port_t,
                                       _ forceIPv4: Bool = false,
                                       _ maxPendingConnection: Int32 = SOMAXCONN,
                                       _ listenAddress: String? = nil) throws -> NanoSocket {
    #if os(Linux)
    let socketFileDescriptor = socket(forceIPv4 ? AF_INET : AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let socketFileDescriptor = socket(forceIPv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
    #endif
    if socketFileDescriptor == -1 {
      throw NanoSocketError.socketCreationFailed(Self.errnoDescription)
    }
    var value: Int32 = 1
    if setsockopt(socketFileDescriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size)) == -1 {
      let details = Self.errnoDescription
      NanoSocket.close(socketFileDescriptor)
      throw NanoSocketError.socketSettingReUseAddrFailed(details)
    }
    NanoSocket.setNoSigPipe(socketFileDescriptor)
    var bindResult: Int32 = -1
    if forceIPv4 {
      #if os(Linux)
      var addr = sockaddr_in(
        sin_family: sa_family_t(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: in_addr_t(0)),
        sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
      #else
      var addr = sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.stride),
        sin_family: UInt8(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: in_addr_t(0)),
        sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
      #endif
      if let address = listenAddress {
        if address.withCString({ cstring in inet_pton(AF_INET, cstring, &addr.sin_addr) }) == 1 {
          // print("\(address) is converted to \(addr.sin_addr).")
        } else {
          // print("\(address) is not converted.")
        }
      }
      bindResult = withUnsafePointer(to: &addr) {
        bind(socketFileDescriptor, UnsafePointer<sockaddr>(OpaquePointer($0)), socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    } else {
      #if os(Linux)
      var addr = sockaddr_in6(
        sin6_family: sa_family_t(AF_INET6),
        sin6_port: port.bigEndian,
        sin6_flowinfo: 0,
        sin6_addr: in6addr_any,
        sin6_scope_id: 0)
      #else
      var addr = sockaddr_in6(
        sin6_len: UInt8(MemoryLayout<sockaddr_in6>.stride),
        sin6_family: UInt8(AF_INET6),
        sin6_port: port.bigEndian,
        sin6_flowinfo: 0,
        sin6_addr: in6addr_any,
        sin6_scope_id: 0)
      #endif
      if let address = listenAddress {
        if address.withCString({ cstring in inet_pton(AF_INET6, cstring, &addr.sin6_addr) }) == 1 {
            //print("\(address) is converted to \(addr.sin6_addr).")
        } else {
            //print("\(address) is not converted.")
        }
      }
      bindResult = withUnsafePointer(to: &addr) {
        bind(socketFileDescriptor, UnsafePointer<sockaddr>(OpaquePointer($0)), socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
    
    if bindResult == -1 {
      let details = Self.errnoDescription
      NanoSocket.close(socketFileDescriptor)
      throw NanoSocketError.bindFailed(details)
    } else if listen(socketFileDescriptor, maxPendingConnection) == -1 {
      let details = Self.errnoDescription
      NanoSocket.close(socketFileDescriptor)
      throw NanoSocketError.listenFailed(details)
    } else {
      return NanoSocket(socketFileDescriptor: socketFileDescriptor)
    }
  }
  
  public func acceptClientSocket() throws -> NanoSocket {
    var addr = sockaddr()
    var len: socklen_t = 0
    let clientSocket = accept(self.socketFileDescriptor, &addr, &len)
    if clientSocket == -1 {
      throw NanoSocketError.acceptFailed(Self.errnoDescription)
    }
    NanoSocket.setNoSigPipe(clientSocket)
    return NanoSocket(socketFileDescriptor: clientSocket)
  }
  
  public func write(_ file: String.File) throws {
    try self.writeFile(file)
  }
  
  public func write(_ data: ArraySlice<UInt8>) throws {
    try self.writeUInt8(data)
  }
  
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
          return write(target, start, len)
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
  
  public static func == (socket1: NanoSocket, socket2: NanoSocket) -> Bool {
    return socket1.socketFileDescriptor == socket2.socketFileDescriptor
  }
}
