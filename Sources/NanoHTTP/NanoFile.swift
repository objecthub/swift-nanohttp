//
//  NanoFile.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `String+File` of framework `Swifter` by Damian Kołakowski.
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

/// The error of a file operation. The value is the `errno` of the system call that failed.
public enum NanoFileError: Error {
  case error(Int32)
}

/// An open file, for the content of a response (``NanoHTTPResponseBodyWriter`` sends it).
///
/// The file is closed by ``close()`` or, at the latest, when the last reference to the
/// `NanoFile` goes away, so a file that is handed to a response that is never written
/// does not leak its file descriptor.
///
/// ```swift
/// let server = NanoHTTPServer()
/// server["/report"] = { _ in
///   let file = try NanoFile(path: "/var/log/report.txt")
///   return .custom(200, contentType: "text/plain") { writer in
///     try writer.write(file)
///   }
/// }
/// ```
public final class NanoFile {
  
  /// How a file is opened.
  public enum Mode {
    /// An existing file, for reading.
    case read
    /// A new file for writing: an existing file is emptied, a missing one is created.
    case create
    /// An existing file for reading and writing, without emptying it.
    case update
  }
  
  let pointer: UnsafeMutablePointer<FILE>
  private var closed = false
  
  /// Opens the file at `path`.
  ///
  /// - Throws: ``NanoFileError`` if the file cannot be opened in the given mode: it does
  ///           not exist, or it cannot be read or written.
  public init(path: String, mode: Mode = .read) throws {
    let fopenMode: String
    switch mode {
      case .read:
        fopenMode = "rb"
      case .create:
        fopenMode = "wb"
      case .update:
        fopenMode = "r+b"
    }
    guard let file = path.withCString({ pathPointer in
            fopenMode.withCString { fopen(pathPointer, $0) }
          }) else {
      throw NanoFileError.error(errno)
    }
    self.pointer = file
  }
  
  /// Wraps a `FILE` pointer, which the instance owns from now on and closes.
  public init(_ pointer: UnsafeMutablePointer<FILE>) {
    self.pointer = pointer
  }
  
  deinit {
    self.close()
  }
  
  /// Closes the file. Closing a file that is already closed has no effect. Do not use the
  /// file afterwards.
  public func close() {
    if !self.closed {
      self.closed = true
      fclose(pointer)
    }
  }
  
  /// Moves to a position, counted in bytes from the start. Returns whether it worked.
  public func seek(_ offset: Int) -> Bool {
    return (fseek(pointer, offset, SEEK_SET) == 0)
  }
  
  /// Reads up to `data.count` bytes into `data` and returns how many were read; fewer
  /// means the end of the file.
  public func read(_ data: inout [UInt8]) throws -> Int {
    if data.count <= 0 {
      return data.count
    }
    let count = fread(&data, 1, data.count, self.pointer)
    if count == data.count {
      return count
    } else if feof(self.pointer) != 0 {
      return count
    } else if ferror(self.pointer) != 0 {
      throw NanoFileError.error(errno)
    } else {
      throw NanoFileError.error(0)
    }
  }
  
  /// Writes bytes.
  public func write(_ data: [UInt8]) throws {
    if data.count <= 0 {
      return
    }
    try data.withUnsafeBufferPointer {
      if fwrite($0.baseAddress, 1, data.count, self.pointer) != data.count {
        throw NanoFileError.error(errno)
      }
    }
  }
  
  /// What `fstat` says about the file that is open: the size, the modification time and
  /// the like of the file itself, also if it was opened through a symbolic link (which
  /// `FileManager.attributesOfItem(atPath:)` does not do: it describes the link). `nil`
  /// if the file cannot be examined.
  func status() -> stat? {
    var info = stat()
    return fstat(fileno(self.pointer), &info) == 0 ? info : nil
  }
}
