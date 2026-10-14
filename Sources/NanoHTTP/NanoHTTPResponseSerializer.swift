//
//  NanoHTTPResponseSerializer.swift
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

/// A body that is in memory: it is written together with the head of the response, in one piece.
enum NanoHTTPInlineBody {
  case bytes([UInt8])
  case string(String)
  case data(Data)
  
  /// The length in bytes.
  var count: Int {
    switch self {
      case .bytes(let bytes): return bytes.count
      case .string(let string): return string.utf8.count
      case .data(let data): return data.count
    }
  }
  
  func append(to buffer: inout [UInt8]) {
    switch self {
      case .bytes(let bytes): buffer.append(contentsOf: bytes)
      case .string(let string): buffer.append(contentsOf: string.utf8)
      case .data(let data): buffer.append(contentsOf: data)
    }
  }

  /// Writes the content to the socket, without copying it into another buffer first (a body of several
  /// megabytes would be allocated and copied for nothing).
  func write(to socket: NanoSocket) throws {
    switch self {
      case .bytes(let bytes): if !bytes.isEmpty { try socket.writeUInt8(bytes) }
      case .string(let string): try socket.writeUTF8(string)
      case .data(let data): try socket.writeData(data)
    }
  }
}

extension NanoHTTPResponse.Body {
  /// The content of a body that is held in memory, or `nil` for a body that a function writes (`.custom`)
  /// and for the bodies of switched connections. Throws if the body cannot be produced (`.json` with a
  /// value that is not JSON).
  func inline() throws -> NanoHTTPInlineBody? {
    switch self {
      case .empty:
        return .bytes([])
      case .text(let text), .html(let text):
        return .string(text)
      case .json(let object):
        guard JSONSerialization.isValidJSONObject(object) else {
          throw NanoHTTPResponse.ResponseError.invalidObject
        }
        return .data(try JSONSerialization.data(withJSONObject: object))
      case .data(let data, _):
        return .data(data)
      case .custom(_, _), .socket(_), .session(_):
        return nil
    }
  }
}

/// Writes the status line and the headers of a response. This is a function of its arguments and does not
/// touch a socket, so that what goes over the wire can be tested.
enum NanoHTTPResponseSerializer {
  
  /// How the end of the body is marked for the client.
  enum Framing: Equatable {
    /// There is no body and nothing is said about one (`1xx`, `204`, `304`; the switch to another protocol).
    case none
    /// `Content-Length: n`.
    case length(Int)
    /// `Transfer-Encoding: chunked`: the body is a sequence of chunks, which a connection can keep going after.
    case chunked
    /// The body ends when the connection does.
    case untilClose
  }
  
  /// What the head says about the connection.
  enum Connection: Equatable {
    /// No `Connection` header: the connection is kept open, which is what HTTP/1.1 means by itself.
    case unspecified
    /// `Connection: close`: the server closes the connection after the response.
    case close
    /// `Connection: keep-alive`.
    case keepAlive
  }
  
  /// The head of `response`: the status line, the headers and the empty line, as bytes.
  ///
  /// The framing, the connection and the date that are given replace the headers of the response with the same
  /// names. Headers whose names are no tokens are left out (and reported to `dropped`), and carriage returns,
  /// line feeds and NUL characters in values are replaced by spaces, so that a value taken from a request cannot
  /// inject headers or a body. The cookies of the response are written as `Set-Cookie` headers; a cookie that
  /// cannot be sent safely is left out and reported to `droppedCookie`.
  static func head(_ response: NanoHTTPResponse,
                   framing: Framing,
                   connection: Connection = .unspecified,
                   date: String? = nil,
                   dropped: (String) -> Void = { _ in },
                   droppedCookie: (String) -> Void = { _ in }) -> [UInt8] {
    var text = "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n"
    var replaced = Set<String>() // lower case names of headers that this function writes itself
    switch framing {
      case .none, .untilClose:
        break
      case .length(let length):
        text += "Content-Length: \(length)\r\n"
        replaced.insert("content-length")
        replaced.insert("transfer-encoding")
      case .chunked:
        text += "Transfer-Encoding: chunked\r\n"
        replaced.insert("content-length")
        replaced.insert("transfer-encoding")
    }
    switch connection {
      case .unspecified:
        break
      case .close:
        text += "Connection: close\r\n"
        replaced.insert("connection")
      case .keepAlive:
        text += "Connection: keep-alive\r\n"
        replaced.insert("connection")
    }
    if let date {
      text += "Date: \(date)\r\n"
      replaced.insert("date")
    }
    for (name, value) in response.allHeaders() {
      guard isValidHeaderName(name) else {
        dropped(name)
        continue
      }
      if replaced.contains(name.lowercased()) {
        continue
      }
      text += "\(name): \(sanitizedHeaderValue(value))\r\n"
    }
    // One `Set-Cookie` line for every cookie: the dictionary of headers cannot hold several of them.
    for cookie in response.cookies {
      do {
        text += "Set-Cookie: \(try cookie.headerValue())\r\n"
      } catch {
        droppedCookie("\(String(reflecting: cookie.name)): \(error)")
      }
    }
    text += "\r\n"
    return Array(text.utf8)
  }
  
  /// A header name is a token (RFC 9110 5.6.2): letters, digits and a few punctuation characters,
  /// but no whitespace, no colon and no line break.
  static func isValidHeaderName(_ name: String) -> Bool {
    return !name.isEmpty && name.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || tokenPunctuation.contains($0)
    }
  }
  
  private static let tokenPunctuation = Set("!#$%&'*+-.^_`|~".utf8)
  
  /// A header value without line breaks. A carriage return or line feed would end the header and let
  /// whatever follows become a header (or the body) of the response, which is how a redirect to a
  /// location taken from a request can be turned into an injection of arbitrary headers.
  static func sanitizedHeaderValue(_ value: String) -> String {
    guard value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) else {
      return value
    }
    // Not `Character`s: "\r\n" is a single Character that is neither "\r" nor "\n".
    return String(String.UnicodeScalarView(value.unicodeScalars.map { $0 == "\r" || $0 == "\n" || $0 == "\0" ? " " : $0 }))
  }
}

/// Dates in the form that HTTP uses (RFC 9110 5.6.7): `Tue, 13 Oct 2026 21:00:00 GMT`.
enum NanoHTTPDate {
  private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  
  /// The text of the date; the text of the current second is kept, because every response has one.
  static func string(for date: Date = Date()) -> String {
    let second = Int(date.timeIntervalSince1970.rounded(.down))
    lock.lock()
    defer {
      lock.unlock()
    }
    if second == cachedSecond {
      return cachedText
    }
    let text = format(second)
    cachedSecond = second
    cachedText = text
    return text
  }
  
  /// The text of any date. (Unlike ``string(for:)`` it does not use the cache of the current second, which a
  /// date in the future, like the end of a cookie, would evict again and again.)
  static func text(for date: Date) -> String {
    return format(Int(date.timeIntervalSince1970.rounded(.down)))
  }
  
  private static let lock = UnfairLock()
  private static var cachedSecond = Int.min
  private static var cachedText = ""
  
  private static func format(_ second: Int) -> String {
    var time = time_t(second)
    var parts = tm()
    gmtime_r(&time, &parts)
    let day = parts.tm_mday < 10 ? "0\(parts.tm_mday)" : "\(parts.tm_mday)"
    func two(_ value: Int32) -> String {
      return value < 10 ? "0\(value)" : "\(value)"
    }
    return "\(weekdays[Int(parts.tm_wday)]), \(day) \(months[Int(parts.tm_mon)]) \(1900 + Int(parts.tm_year)) " +
           "\(two(parts.tm_hour)):\(two(parts.tm_min)):\(two(parts.tm_sec)) GMT"
  }
  
  /// The date that a header contains (`If-Modified-Since`, `If-Range`), or `nil` if it is not in the form
  /// of HTTP. The obsolete forms (RFC 850, `asctime`) are understood as well.
  static func date(from text: String) -> Date? {
    let text = text.trimmingCharacters(in: .whitespaces)
    for formatter in formatters {
      if let date = formatter.date(from: text) {
        return date
      }
    }
    return nil
  }
  
  /// One formatter for each form (their settings are never changed, so that threads can share them).
  private static let formatters: [DateFormatter] = {
    return ["EEE, dd MMM yyyy HH:mm:ss 'GMT'",
            "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
            "EEE MMM d HH:mm:ss yyyy"].map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "GMT")
      formatter.dateFormat = format
      return formatter
    }
  }()
}
