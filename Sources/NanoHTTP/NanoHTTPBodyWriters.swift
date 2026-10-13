//
//  NanoHTTPBodyWriters.swift
//  NanoHTTP
//
//  Copyright © 2026 Matthias Zenger. All rights reserved.
//  
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
//

import Foundation

/// Writes the body of a response in chunks (RFC 9112 7.1), so that a body of unknown length ends in a way that
/// the client can see, and the connection can be used for the next request: every write is one chunk, and
/// ``finish()`` writes the chunk that ends the body. Empty writes are left out, because the empty chunk ends
/// the body.
final class ChunkedBodyWriter: NanoHTTPResponseBodyWriter {
  private let socket: NanoSocket
  
  /// Chunks up to this size are written in one piece, with their size line and line break.
  private static let coalescingLimit = 64 * 1024
  
  init(socket: NanoSocket) {
    self.socket = socket
  }
  
  func write(_ data: ArraySlice<UInt8>) throws {
    guard !data.isEmpty else {
      return
    }
    var head = Array(String(data.count, radix: 16).utf8)
    head.append(13)
    head.append(10)
    if data.count <= ChunkedBodyWriter.coalescingLimit {
      head.append(contentsOf: data)
      head.append(13)
      head.append(10)
      try self.socket.writeUInt8(head)
    } else {
      try self.socket.writeUInt8(head)
      try self.socket.writeUInt8(data)
      try self.socket.writeUInt8([13, 10])
    }
  }
  
  func write(_ data: Data) throws {
    try self.write(ArraySlice([UInt8](data)))
  }
  
  func write(_ file: NanoFile) throws {
    try self.write(file, offset: 0, length: Int64(file.status()?.st_size ?? 0))
  }
  
  /// A part of a file is one chunk, which the system sends without the bytes passing through this process. If the
  /// file turns out shorter than it was a moment ago, the chunk cannot be completed: the error ends the connection.
  func write(_ file: NanoFile, offset: Int64, length: Int64) throws {
    guard length > 0 else {
      return
    }
    var head = Array(String(length, radix: 16).utf8)
    head.append(13)
    head.append(10)
    try self.socket.writeUInt8(head)
    guard try self.socket.writeFile(file, offset: offset, length: length) == length else {
      throw NanoSocketError.writeFailed("the file is shorter than it was")
    }
    try self.socket.writeUInt8([13, 10])
  }
  
  /// Writes the last chunk (and no trailers).
  func finish() throws {
    try self.socket.writeUInt8([48, 13, 10, 13, 10]) // "0\r\n\r\n"
  }
}

/// Writes the body of a response that has a length, which the head announced: not a byte more is written
/// than that. A handler that writes more has its bytes dropped, one that writes less leaves the client waiting;
/// either way the connection cannot be used for another request, and the connection finds that out here.
final class LengthLimitedBodyWriter: NanoHTTPResponseBodyWriter {
  private let socket: NanoSocket
  private let length: Int
  
  /// The number of bytes that have been written.
  private(set) var written = 0
  
  /// Has the handler tried to write more than the announced length?
  private(set) var overflowed = false
  
  init(socket: NanoSocket, length: Int) {
    self.socket = socket
    self.length = length
  }
  
  /// Does the body have exactly the announced length?
  var isComplete: Bool {
    return self.written == self.length && !self.overflowed
  }
  
  func write(_ data: ArraySlice<UInt8>) throws {
    let room = self.length - self.written
    guard data.count <= room else {
      self.overflowed = true
      if room > 0 {
        try self.socket.writeUInt8(data.prefix(room))
        self.written += room
      }
      return
    }
    try self.socket.writeUInt8(data)
    self.written += data.count
  }
  
  func write(_ data: Data) throws {
    try self.write(ArraySlice([UInt8](data)))
  }
  
  func write(_ file: NanoFile) throws {
    try self.write(file, offset: 0, length: Int64(file.status()?.st_size ?? 0))
  }
  
  func write(_ file: NanoFile, offset: Int64, length: Int64) throws {
    let room = Int64(self.length - self.written)
    if length > room {
      self.overflowed = true
    }
    guard min(length, room) > 0 else {
      return
    }
    self.written += Int(try self.socket.writeFile(file, offset: offset, length: min(length, room)))
  }
}
