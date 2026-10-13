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
