//
//  NanoHTTPParser.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `HttpParser` of framework `Swifter` by Damian Kołakowski.
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

/// The reasons why `NanoHTTPParser` refuses a request. A server answers requests that fail with
/// one of these errors with the matching HTTP status code and closes the connection; failures of
/// the connection itself (peer closed, reset) surface as `NanoSocketError`.
public enum NanoHTTPParserError: Error, Equatable {
  /// The first line is not of the form `METHOD TARGET VERSION` (HTTP status 400).
  case invalidStatusLine(String)
  /// The request line is longer than `Limits.maxLineLength` (HTTP status 414).
  case requestLineTooLong
  /// A header line is longer than `Limits.maxLineLength` (HTTP status 431).
  case headerLineTooLong
  /// Request line and headers together exceed `Limits.maxHeaderBytes` (HTTP status 431).
  case headersTooLarge
  /// The `Content-Length` header is not a number (HTTP status 400).
  case invalidContentLength
  /// The `Content-Length` header is negative (HTTP status 400).
  case negativeContentLength
  /// The `Content-Length` header exceeds `Limits.maxBodyBytes` (HTTP status 413).
  case bodyTooLarge
  /// The protocol version is not one that this server speaks, HTTP/1.0 and HTTP/1.1 (HTTP status 505).
  case unsupportedVersion(String)
  /// The request has a `Content-Length` and a `Transfer-Encoding`: which of them says where the body ends
  /// is a question that different servers answer differently, which is how requests are smuggled past a
  /// proxy (HTTP status 400).
  case conflictingFraming
  /// The `Transfer-Encoding` is not just `chunked`, the only one that the server decodes (HTTP status 501).
  case unsupportedTransferEncoding(String)
  /// The body that is sent in chunks is malformed (HTTP status 400).
  case invalidChunk
  /// The `Expect` header asks for something other than `100-continue` (HTTP status 417).
  case expectationFailed(String)
}

/// Reads HTTP requests from a socket.
///
/// The parser never reads or allocates more than its `limits` allow, no matter what the peer
/// announces, so a single request cannot exhaust the memory of the process.
public struct NanoHTTPParser {
  
  /// Upper bounds for the size of a request.
  public struct Limits: Equatable {
    /// The longest accepted line (request line or header line) in bytes, excluding the line break.
    public var maxLineLength: Int
    
    /// The most bytes accepted for the request line and all headers together, including line breaks.
    public var maxHeaderBytes: Int
    
    /// The largest accepted request body in bytes (the value of `Content-Length`). The body is
    /// held in memory, so keep this as small as the application allows.
    public var maxBodyBytes: Int
    
    /// The most parts that ``NanoHTTPRequest/parseMultiPartFormData()`` accepts in a `multipart/form-data` body. A
    /// body with more parts is refused as a whole. The parts cost memory (every one has headers of its own), and a
    /// body of the permitted size can hold millions of empty ones.
    public var maxMultipartParts: Int
    
    /// The most bytes that ``NanoHTTPRequest/parseMultiPartFormData()`` accepts for the headers of one part of a
    /// `multipart/form-data` body, including line breaks.
    public var maxMultipartHeaderBytes: Int
    
    /// Creates limits; the defaults are the limits of a new server.
    public init(maxLineLength: Int = 8 * 1024,
                maxHeaderBytes: Int = 64 * 1024,
                maxBodyBytes: Int = 64 * 1024 * 1024) {
      self.init(maxLineLength: maxLineLength,
                maxHeaderBytes: maxHeaderBytes,
                maxBodyBytes: maxBodyBytes,
                maxMultipartParts: 1000)
    }
    
    /// Creates limits, including the ones for `multipart/form-data` bodies; the defaults are the limits of a new server.
    public init(maxLineLength: Int = 8 * 1024,
                maxHeaderBytes: Int = 64 * 1024,
                maxBodyBytes: Int = 64 * 1024 * 1024,
                maxMultipartParts: Int,
                maxMultipartHeaderBytes: Int = 16 * 1024) {
      self.maxLineLength = maxLineLength
      self.maxHeaderBytes = maxHeaderBytes
      self.maxBodyBytes = maxBodyBytes
      self.maxMultipartParts = maxMultipartParts
      self.maxMultipartHeaderBytes = maxMultipartHeaderBytes
    }
  }
  
  /// The socket the requests are read from.
  public let socket: NanoSocket
  
  /// The bounds this parser enforces.
  public var limits = Limits()
  
  /// Reads the next request: request line, headers and, if `Content-Length` announces one, the body.
  ///
  /// - Throws: `NanoHTTPParserError` if the request is malformed or exceeds `limits`;
  ///     `NanoSocketError` if the connection fails or ends before the request is complete.
  public func readHttpRequest() throws -> NanoHTTPRequest {
    var budget = self.limits.maxHeaderBytes
    let statusLine = try self.readLine(tooLong: .requestLineTooLong, budget: &budget)
    let statusLineTokens = statusLine.components(separatedBy: " ")
    if statusLineTokens.count < 3 {
      throw NanoHTTPParserError.invalidStatusLine(statusLine)
    }
    let version = try NanoHTTPParser.version(of: statusLineTokens[2].trimmingCharacters(in: .whitespaces),
                                             in: statusLine)
    let (rawPath, rawQuery) = NanoHTTPParser.split(target: statusLineTokens[1])
    let request = NanoHTTPRequest(
                    method: statusLineTokens[0],
                    rawPath: rawPath,
                    rawQuery: rawQuery,
                    headers: try readHeaders(budget: &budget),
                    httpVersion: version)
    request.multipartLimits = (self.limits.maxMultipartParts, self.limits.maxMultipartHeaderBytes)
    // Where the body ends: with the chunks that say so, or after as many bytes as `Content-Length` says.
    // A request that says both is refused (see `NanoHTTPParserError.conflictingFraming`).
    let contentLength = request.header("content-length")
    if let encoding = request.header("transfer-encoding") {
      guard contentLength == nil else {
        throw NanoHTTPParserError.conflictingFraming
      }
      guard encoding.trimmingCharacters(in: .whitespaces).lowercased() == "chunked", version == "HTTP/1.1" else {
        throw NanoHTTPParserError.unsupportedTransferEncoding(encoding)
      }
      try self.acceptExpectation(of: request, bodyFollows: true)
      let body = try self.readChunkedBody()
      request.body = body
      // The headers describe the request as the handler sees it.
      request.removeHeader("transfer-encoding")
      request.setHeader("content-length", to: String(body.count))
    } else if let contentLength {
      let size = try self.bodySize(contentLength)
      try self.acceptExpectation(of: request, bodyFollows: size > 0)
      request.body = try readBody(size: size)
    } else {
      try self.acceptExpectation(of: request, bodyFollows: false)
    }
    return request
  }
  
  /// The version of the protocol that a request line names, as the server speaks it: `HTTP/1.0`, or
  /// `HTTP/1.1` (also for the minor versions behind it, which HTTP/1.1 is compatible with).
  private static func version(of token: String, in line: String) throws -> String {
    guard token.hasPrefix("HTTP/") else {
      throw NanoHTTPParserError.invalidStatusLine(line)
    }
    let numbers = token.dropFirst(5).split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(numbers.count), let major = Int(numbers[0]), major >= 0,
          numbers.count == 1 || Int(numbers[1]) != nil else {
      throw NanoHTTPParserError.invalidStatusLine(line)
    }
    guard major == 1 else {
      throw NanoHTTPParserError.unsupportedVersion(token)
    }
    guard numbers.count == 2, let minor = Int(numbers[1]), minor >= 0 else {
      throw NanoHTTPParserError.invalidStatusLine(line) // "HTTP/1" is no version
    }
    return minor == 0 ? "HTTP/1.0" : "HTTP/1.1"
  }
  
  /// Looks at the `Expect` header: the only expectation that is understood is `100-continue`, which asks
  /// the server to say that it wants the body before the client sends it. That is answered here, after the
  /// size of the body has been checked (a client with a body that is too large is told so instead) and
  /// before the body is read. HTTP/1.0 has no interim responses.
  private func acceptExpectation(of request: NanoHTTPRequest, bodyFollows: Bool) throws {
    guard let expectation = request.header("expect") else {
      return
    }
    guard expectation.trimmingCharacters(in: .whitespaces).lowercased() == "100-continue" else {
      throw NanoHTTPParserError.expectationFailed(expectation)
    }
    if bodyFollows && request.httpVersion == "HTTP/1.1" {
      try self.socket.writeUTF8("HTTP/1.1 100 Continue\r\n\r\n")
    }
  }
  
  /// Reads a body that is sent in chunks (RFC 9112 7.1): every chunk is its size in hexadecimal (and perhaps
  /// extensions, which are ignored), a line break, that many bytes, and a line break; a chunk of size 0 ends the
  /// body, and is followed by trailers (ignored) and an empty line. The total is limited like a body with a length.
  private func readChunkedBody() throws -> [UInt8] {
    var body = [UInt8]()
    while true {
      var noBudget = Int.max
      let line = try self.readLine(tooLong: .invalidChunk, budget: &noBudget)
      let digits = (line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                      .trimmingCharacters(in: .whitespaces)
      guard !digits.isEmpty, digits.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else {
        throw NanoHTTPParserError.invalidChunk
      }
      // More digits than an `Int` holds are more bytes than any limit allows.
      guard digits.count <= 15, let size = Int(digits, radix: 16) else {
        throw NanoHTTPParserError.bodyTooLarge
      }
      if size == 0 {
        var trailerBudget = self.limits.maxHeaderBytes
        while try !self.readLine(tooLong: .headerLineTooLong, budget: &trailerBudget).isEmpty {}
        return body
      }
      guard size <= self.limits.maxBodyBytes - body.count else {
        throw NanoHTTPParserError.bodyTooLarge
      }
      body.append(contentsOf: try self.socket.read(length: size))
      guard try self.readLine(tooLong: .invalidChunk, budget: &noBudget).isEmpty else {
        throw NanoHTTPParserError.invalidChunk // there is more than the line break behind the chunk
      }
    }
  }
  
  /// Splits the target of a request line into the path and the query, both still percent-encoded. The
  /// fragment, which clients do not send, is dropped. A target in absolute form (`http://host/a?b`, as a
  /// proxy receives it) gives its path and query; `*` (of an `OPTIONS` request) is its own path. Bytes that
  /// are not ASCII are turned into percent sequences, see `String.withNonASCIIPercentEncoded`.
  static func split(target: String) -> (path: String, query: String?) {
    var text = Substring(target.withNonASCIIPercentEncoded)
    if let fragment = text.firstIndex(of: "#") {
      text = text[..<fragment]
    }
    let lowercased = text.prefix(8).lowercased()
    if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://"),
       let scheme = text.range(of: "://") {
      let rest = text[scheme.upperBound...]
      if let start = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) {
        text = rest[start...]
        if text.first == "?" {
          text = "/" + text
        }
      } else {
        text = "/"
      }
    }
    guard let question = text.firstIndex(of: "?") else {
      return (String(text), nil)
    }
    return (String(text[..<question]), String(text[text.index(after: question)...]))
  }
  
  /// The number of body bytes announced by a `Content-Length` header value, checked against the limits.
  private func bodySize(_ contentLength: String) throws -> Int {
    if let size = Int(contentLength) {
      guard size >= 0 else {
        throw NanoHTTPParserError.negativeContentLength
      }
      guard size <= self.limits.maxBodyBytes else {
        throw NanoHTTPParserError.bodyTooLarge
      }
      return size
    }
    // Only digits, but too many for an `Int`: larger than any limit.
    if !contentLength.isEmpty && contentLength.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
      throw NanoHTTPParserError.bodyTooLarge
    }
    throw NanoHTTPParserError.invalidContentLength
  }
  
  private func readBody(size: Int) throws -> [UInt8] {
    return try self.socket.read(length: size)
  }
  
  /// Reads one line, terminated by a line feed (carriage returns and other control characters are
  /// dropped), and charges every byte read to `budget`. Throws `tooLong` if the line has more than
  /// `limits.maxLineLength` characters, and `headersTooLarge` if more than the budget is read.
  private func readLine(tooLong: NanoHTTPParserError, budget: inout Int) throws -> String {
    var bytes = [UInt8]()
    bytes.reserveCapacity(96)
    var ascii = true
    while true {
      let byte = try self.socket.read()
      budget -= 1
      if budget < 0 {
        throw NanoHTTPParserError.headersTooLarge
      }
      if byte == NanoHTTPParser.NL {
        break
      }
      if byte > NanoHTTPParser.CR {
        if bytes.count >= self.limits.maxLineLength {
          throw tooLong
        }
        bytes.append(byte)
        ascii = ascii && byte < 128
      }
    }
    if ascii {
      return String(decoding: bytes, as: UTF8.self)
    }
    // Every byte is one character (Latin-1); `split(target:)` and the decoding of paths read them as UTF-8 again.
    return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
  }
  
  private static let CR: UInt8 = 13
  private static let NL: UInt8 = 10
  
  private func readHeaders(budget: inout Int) throws -> [String: String] {
    var headers = [String: String]()
    while case let headerLine = try self.readLine(tooLong: .headerLineTooLong, budget: &budget),
          !headerLine.isEmpty {
      // "Name: value": the value starts after the first colon and may be empty or contain colons.
      // A line without a colon is not a header and is ignored.
      guard let colon = headerLine.firstIndex(of: ":") else {
        continue
      }
      let name = headerLine[headerLine.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      guard !name.isEmpty else {
        continue
      }
      let value = headerLine[headerLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let earlier = headers[name] {
        // Several headers of the same name are the same as one header with a comma-separated list
        // (RFC 9110 5.3), so none of them gets lost. The cookies are the exception: they are separated by
        // semicolons (RFC 9113 8.2.3), and a comma could be part of a value.
        headers[name] = earlier + (name == "cookie" ? "; " : ", ") + value
      } else {
        headers[name] = value
      }
    }
    return headers
  }
}
