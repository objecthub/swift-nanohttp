//
//  NanoHTTPMultipart.swift
//  NanoHTTP
//
//  Copyright © 2026 Matthias Zenger. All rights reserved.
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

/// A header value in the form `value; name=token; name="quoted string"`, like `Content-Type`
/// and `Content-Disposition`: the value before the first `;`, and the parameters behind
/// it. A `;`, an `=` or a `:` inside a quoted string belongs to the string, and a quoted
/// string can hold `\"` and `\\`.
struct NanoHeaderParameters {
  /// The part before the first `;`, without surrounding spaces.
  let value: String
  /// The parameters in the order in which they appear, with names in lower case and
  /// values without quotes.
  let parameters: [(name: String, value: String)]

  init(_ text: String) {
    var segments = [String]()
    var current = String.UnicodeScalarView()
    var quoted = false
    var escaped = false
    for scalar in text.unicodeScalars {
      if quoted {
        current.append(scalar)
        if escaped {
          escaped = false
        } else if scalar == "\\" {
          escaped = true
        } else if scalar == "\"" {
          quoted = false
        }
      } else if scalar == ";" {
        segments.append(String(current))
        current = String.UnicodeScalarView()
      } else {
        if scalar == "\"" {
          quoted = true
        }
        current.append(scalar)
      }
    }
    segments.append(String(current))
    self.value = segments[0].trimmingCharacters(in: .whitespaces)
    var parameters = [(name: String, value: String)]()
    for segment in segments.dropFirst() {
      guard let equals = segment.firstIndex(of: "=") else {
        continue
      }
      let name = segment[segment.startIndex..<equals]
                   .trimmingCharacters(in: .whitespaces)
                   .lowercased()
      if !name.isEmpty {
        let raw = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        parameters.append((name, NanoHeaderParameters.unquoted(raw)))
      }
    }
    self.parameters = parameters
  }

  /// The value of the first parameter with this name (in lower case).
  subscript(name: String) -> String? {
    return self.parameters.first { $0.name == name }?.value
  }

  /// The text between the quotes, if `raw` begins with one. `\"` and `\\` stand for the
  /// character behind the backslash; any other backslash stays (browsers do not escape
  /// the backslashes of a Windows path).
  private static func unquoted(_ raw: String) -> String {
    guard raw.first == "\"" else {
      return raw
    }
    let scalars = Array(raw.unicodeScalars)
    var result = String.UnicodeScalarView()
    var index = 1
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar == "\"" {
        break
      }
      if scalar == "\\" && index + 1 < scalars.count && (scalars[index + 1] == "\"" ||
                                                         scalars[index + 1] == "\\") {
        index += 1
        result.append(scalars[index])
      } else {
        result.append(scalar)
      }
      index += 1
    }
    return String(result)
  }

  /// Decodes an extended value (RFC 8187): `UTF-8''%E2%82%AC.txt`, the character set, an
  /// optional language and the percent-encoded text. `nil` for another character set than
  /// UTF-8 and ISO-8859-1, and for bytes that are no text.
  static func decodeExtended(_ value: String) -> String? {
    let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
    guard pieces.count == 3 else {
      return nil
    }
    let raw = Array(pieces[2].utf8)
    var bytes = [UInt8]()
    var index = 0
    while index < raw.count {
      if raw[index] == UInt8(ascii: "%") {
        guard index + 2 < raw.count,
              let high = NanoHeaderParameters.hexValue(raw[index + 1]),
              let low = NanoHeaderParameters.hexValue(raw[index + 2]) else {
          return nil
        }
        bytes.append(high << 4 | low)
        index += 3
      } else {
        bytes.append(raw[index])
        index += 1
      }
    }
    switch pieces[0].lowercased() {
      case "utf-8":
        return String(bytes: bytes, encoding: .utf8)
      case "iso-8859-1":
        return String(bytes: bytes, encoding: .isoLatin1)
      default:
        return nil
    }
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"):
        return byte - UInt8(ascii: "0")
      case UInt8(ascii: "a")...UInt8(ascii: "f"):
        return byte - UInt8(ascii: "a") + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F"):
        return byte - UInt8(ascii: "A") + 10
      default:
        return nil
    }
  }
}

extension NanoHTTPRequest {

  /// The parts of a `multipart/form-data` body (a form with file uploads), in order.
  /// Returns an empty array if the request has another content type or the body is
  /// malformed. The whole body is in memory, see ``NanoHTTPParser/Limits/maxBodyBytes``.
  ///
  /// The body is read as RFC 2046 and RFC 7578 describe it, and is binary safe: a part
  /// ends at the line break that precedes the next boundary line, and every byte before
  /// that belongs to the part, line breaks and `--` included. Text before the first
  /// boundary and after the closing boundary is ignored. A boundary can be quoted
  /// (`boundary="a b"`), and the names and file names of the parts can contain quotes
  /// (`\"`), `;`, `=` and `:`.
  ///
  /// A body is refused as a whole (the result is empty) if it has no closing boundary, if
  /// the headers of a part are not followed by an empty line, or if it exceeds
  /// ``NanoHTTPParser/Limits/maxMultipartParts`` or
  /// ``NanoHTTPParser/Limits/maxMultipartHeaderBytes``.
  public func parseMultiPartFormData() -> [MultiPart] {
    guard let contentType = self.header("content-type") else {
      return []
    }
    let parameters = NanoHeaderParameters(contentType)
    guard parameters.value.lowercased() == "multipart/form-data",
          let boundary = parameters["boundary"],
          !boundary.isEmpty else {
      return []
    }
    return NanoMultipartParser.parse(self.body,
                                     boundary: boundary,
                                     maxParts: self.multipartLimits.parts,
                                     maxHeaderBytes: self.multipartLimits.headerBytes) ?? []
  }
}

/// Splits a `multipart/form-data` body into its parts, working on the bytes.
enum NanoMultipartParser {
  private static let cr = UInt8(ascii: "\r")
  private static let lf = UInt8(ascii: "\n")
  private static let space = UInt8(ascii: " ")
  private static let tab = UInt8(ascii: "\t")
  private static let dash = UInt8(ascii: "-")

  /// What follows a boundary: the beginning of a part, or the end of the body.
  private enum Delimiter {
    case part(start: Int)
    case end
  }

  /// The body, with what is needed to look for the boundary lines.
  private struct Input {
    let bytes: UnsafeBufferPointer<UInt8>
    /// `--boundary`
    let delimiter: [UInt8]
    /// A line feed and the delimiter: what the boundary line of every part but the first
    /// one begins with.
    let needle: [UInt8]

    /// Is there a boundary line at `index`? A delimiter that is followed by more text
    /// (`--boundaryX`) is no boundary line, and is content of the part. What follows the
    /// boundary on its line is optional blanks, and then `--` (the closing boundary), or
    /// the line break after which the next part begins. A body that ends after the
    /// delimiter is closed.
    func delimiter(at index: Int) -> Delimiter? {
      guard index + self.delimiter.count <= self.bytes.count else {
        return nil
      }
      for offset in 0..<self.delimiter.count where self.bytes[index + offset] != self.delimiter[offset] {
        return nil
      }
      var position = index + self.delimiter.count
      while position < self.bytes.count && (self.bytes[position] == NanoMultipartParser.space ||
                                            self.bytes[position] == NanoMultipartParser.tab) {
        position += 1
      }
      if position == self.bytes.count {
        return .end
      }
      switch self.bytes[position] {
        case NanoMultipartParser.dash:
          return position + 1 < self.bytes.count &&
                 self.bytes[position + 1] == NanoMultipartParser.dash ? .end : nil
        case NanoMultipartParser.cr:
          return position + 1 < self.bytes.count && self.bytes[position + 1] == NanoMultipartParser.lf
                   ? .part(start: position + 2) : nil
        case NanoMultipartParser.lf:
          return .part(start: position + 1)
        default:
          return nil
      }
    }

    /// The first boundary line that is preceded by a line feed, at or after `index` (the
    /// position of the line feed).
    func find(from index: Int) -> (lineFeed: Int, delimiter: Delimiter)? {
      guard let base = self.bytes.baseAddress else {
        return nil
      }
      var start = index
      while start + self.needle.count <= self.bytes.count {
        guard let found = memmem(base + start, self.bytes.count - start, self.needle, self.needle.count) else {
          return nil
        }
        let position = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        if let delimiter = self.delimiter(at: position + 1) {
          return (position, delimiter)
        }
        start = position + 1 // something that looks like a boundary, but is not
      }
      return nil
    }

    /// The first boundary line of the body, which may be the first line (there is no
    /// preamble then).
    func first() -> Delimiter? {
      return self.delimiter(at: 0) ?? self.find(from: 0)?.delimiter
    }

    private func text(_ range: Range<Int>) -> String {
      return String(decoding: UnsafeBufferPointer(rebasing: self.bytes[range]), as: UTF8.self)
    }

    /// Reads the headers of the part that begins at `start`, up to the empty line: the
    /// names in lower case, the values without the blanks around them, repeated headers
    /// joined with `", "`, continuation lines (which begin with a blank) appended with a
    /// space. Returns them and the position where the content of the part begins; `nil`
    /// if there is no empty line within `maxBytes`.
    func headers(from start: Int, maxBytes: Int) -> (headers: [String: String], contentStart: Int)? {
      guard let base = self.bytes.baseAddress else {
        return nil
      }
      let limit = start + min(maxBytes, self.bytes.count - start)
      var headers = [String: String]()
      var last: String? = nil
      var position = start
      while position < limit {
        guard let found = memchr(base + position, Int32(NanoMultipartParser.lf), limit - position) else {
          return nil
        }
        let lineFeed = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        var end = lineFeed
        if end > position && self.bytes[end - 1] == NanoMultipartParser.cr {
          end -= 1
        }
        if end == position {
          return (headers, lineFeed + 1) // the empty line
        }
        if self.bytes[position] == NanoMultipartParser.space ||
                                   self.bytes[position] == NanoMultipartParser.tab {
          if let name = last {
            headers[name]! += " " + self.text(position..<end).trimmingCharacters(in: .whitespaces)
          }
        } else if let colon = self.bytes[position..<end].firstIndex(of: UInt8(ascii: ":")) {
          let name = self.text(position..<colon).trimmingCharacters(in: .whitespaces).lowercased()
          let value = self.text((colon + 1)..<end).trimmingCharacters(in: .whitespaces)
          if !name.isEmpty {
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
            last = name
          }
        }
        position = lineFeed + 1
      }
      return nil
    }
  }

  /// The parts of `data`, or `nil` if it is not a well-formed body for this boundary.
  static func parse(_ data: [UInt8],
                    boundary: String,
                    maxParts: Int,
                    maxHeaderBytes: Int) -> [NanoHTTPRequest.MultiPart]? {
    let delimiter = [dash, dash] + Array(boundary.utf8)
    return data.withUnsafeBufferPointer { bytes in
      let input = Input(bytes: bytes, delimiter: delimiter, needle: [lf] + delimiter)
      guard var current = input.first() else {
        return nil
      }
      var parts = [NanoHTTPRequest.MultiPart]()
      while case .part(let start) = current {
        guard parts.count < maxParts,
              let (headers, contentStart) = input.headers(from: start, maxBytes: maxHeaderBytes),
              // From the last line feed of the headers: a part that is empty may have
              // only one line break before the next boundary.
              let (lineFeed, next) = input.find(from: contentStart - 1) else {
          return nil
        }
        // the line break before a boundary belongs to the boundary, not to the part
        var end = lineFeed
        if lineFeed < contentStart {
          end = contentStart
        } else if lineFeed > contentStart && bytes[lineFeed - 1] == cr {
          end = lineFeed - 1
        }
        parts.append(NanoHTTPRequest.MultiPart(headers: headers,
                                               body: Array(bytes[contentStart..<end])))
        current = next
      }
      return parts
    }
  }
}
