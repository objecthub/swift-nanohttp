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
    
    /// Creates limits; the defaults are the limits of a new server.
    public init(maxLineLength: Int = 8 * 1024,
                maxHeaderBytes: Int = 64 * 1024,
                maxBodyBytes: Int = 64 * 1024 * 1024) {
      self.maxLineLength = maxLineLength
      self.maxHeaderBytes = maxHeaderBytes
      self.maxBodyBytes = maxBodyBytes
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
    let urlComponents = URLComponents(string: statusLineTokens[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                                      ?? statusLineTokens[1])
    let request = NanoHTTPRequest(
                    method: statusLineTokens[0],
                    path: urlComponents?.path ?? "",
                    queryParams: urlComponents?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                    headers: try readHeaders(budget: &budget))
    if let contentLength = request.header("content-length") {
      request.body = try readBody(size: try self.bodySize(contentLength))
    }
    return request
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
    var characters = ""
    var length = 0
    while true {
      let byte = try self.socket.read()
      budget -= 1
      if budget < 0 {
        throw NanoHTTPParserError.headersTooLarge
      }
      if byte == NanoHTTPParser.NL {
        return characters
      }
      if byte > NanoHTTPParser.CR {
        length += 1
        if length > self.limits.maxLineLength {
          throw tooLong
        }
        characters.append(Character(UnicodeScalar(byte)))
      }
    }
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
        // (RFC 9110 5.3), so none of them gets lost.
        headers[name] = earlier + ", " + value
      } else {
        headers[name] = value
      }
    }
    return headers
  }
}
