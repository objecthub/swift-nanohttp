//
//  String+Extensions.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
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
import CryptoKit
import UniformTypeIdentifiers

extension String {
  
  func split(_ separator: Character) -> [String] {
    return self.split { $0 == separator }.map(String.init)
  }
  
  /// The MIME type for the file extension of this file name (`"a.png"` gives `image/png`); `application/octet-stream` if it is not known.
  public func mimeType() -> String {
    if let mimeType = UTType(filenameExtension: (self as NSString).pathExtension)?.preferredMIMEType {
      return mimeType
    } else {
      return "application/octet-stream"
    }
  }
  
  /// This string without one pair of surrounding double quotes, if it has them.
  public func unquote() -> String {
    if self.first == "\"" && self.count >= 2 && self.last == "\"" {
      return String(self[self.index(after: self.startIndex)..<self.index(before: self.endIndex)])
    }
    return self
  }
  
  /// The SHA-1 hash of the UTF-8 bytes of this string. (The type of the result selects between this and the hexadecimal text.)
  public func sha1() -> [UInt8] {
    guard let data = self.data(using: .utf8) else {
      return []
    }
    let digest = Data(Insecure.SHA1.hash(data: data))
    var res = [UInt8](repeating: 0, count: digest.count)
    digest.copyBytes(to: &res, count: digest.count)
    return res
  }

  /// The SHA-1 hash of the UTF-8 bytes of this string as hexadecimal text.
  public func sha1() -> String {
    return self.sha1().reduce("") { $0 + String(format: "%02x", $1) }
  }
  
  /// The Base64 encoding of the bytes.
  public static func toBase64(_ data: [UInt8]) -> String {
    return Data(data).base64EncodedString()
  }
}

extension String {
  /// Decodes percent-encoded text: `%XX` is the byte `XX`, and the bytes are read as UTF-8. This never
  /// fails: a `%` that is not followed by two hexadecimal digits is kept as it is, and bytes that are not
  /// valid UTF-8 become the replacement character U+FFFD.
  ///
  /// - Parameter plusAsSpace: Whether `+` is a space, as in a query string or in the body of an HTML form
  ///     (decided before the percent sequences are decoded, so that `%2B` stays a plus). In a path, `+` is a plus.
  func percentDecoded(plusAsSpace: Bool = false) -> String {
    let input = Array(self.utf8)
    guard input.contains(37) || (plusAsSpace && input.contains(43)) else {
      return self // nothing to decode
    }
    var bytes = [UInt8]()
    bytes.reserveCapacity(input.count)
    func hexValue(_ digit: UInt8) -> UInt8? {
      switch digit {
        case 48...57: return digit - 48
        case 65...70: return digit - 55
        case 97...102: return digit - 87
        default: return nil
      }
    }
    var index = 0
    while index < input.count {
      let byte = input[index]
      if byte == 43 && plusAsSpace {
        bytes.append(32)
        index += 1
      } else if byte == 37, index + 2 < input.count,
                let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
        bytes.append(high << 4 | low)
        index += 3
      } else {
        bytes.append(byte)
        index += 1
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }
  
  /// The text as the path of a request target: everything but the characters that a path may contain is
  /// percent-encoded as UTF-8 (`/a b/é` is `/a%20b/%C3%A9`; `/` and `+` stay as they are).
  var percentEncodedAsPath: String {
    return self.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
  }
  
  /// The text as a name or a value of a query string: everything but letters, digits and `-._~` is
  /// percent-encoded as UTF-8.
  var percentEncodedAsQueryComponent: String {
    return self.addingPercentEncoding(withAllowedCharacters: .urlQueryComponentAllowed) ?? self
  }
  
  /// The text of a request target with the bytes that are not ASCII written as percent sequences. The
  /// parser reads the bytes of a request line as Latin-1 characters; clients that send UTF-8 in a target
  /// without encoding it have their bytes preserved this way, and the decoding reads them as UTF-8.
  var withNonASCIIPercentEncoded: String {
    guard self.unicodeScalars.contains(where: { $0.value > 127 }) else {
      return self
    }
    var result = ""
    for scalar in self.unicodeScalars {
      if scalar.value < 128 {
        result.unicodeScalars.append(scalar)
      } else if scalar.value <= 0xFF {
        result += String(format: "%%%02X", scalar.value)
      } else {
        for byte in String(scalar).utf8 {
          result += String(format: "%%%02X", byte)
        }
      }
    }
    return result
  }
}

extension CharacterSet {
  /// Letters, digits and `-._~`: the characters that need no encoding in a name or value of a query.
  static let urlQueryComponentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

