//
//  NanoHTTPCookie.swift
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

/// A cookie that a response asks the client to store (`Set-Cookie`, RFC 6265).
///
/// ```swift
/// let server = NanoHTTPServer()
/// server.get["/login"] = { request in
///   var response = NanoHTTPResponse.seeOther("/home")
///   response.setCookie(NanoHTTPCookie(name: "session", value: "a1b2c3", maxAge: 3600))
///   // Set-Cookie: session=a1b2c3; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax
///   return response
/// }
/// server.get["/home"] = { request in
///   .ok(.text("Hello, \(request.cookie("session") ?? "stranger")"))
/// }
/// ```
///
/// A new cookie is made for the common case: it is sent for every path (`Path=/`), is
/// hidden from scripts (`HttpOnly`), and is not sent along with requests that other sites
/// cause (`SameSite=Lax`). It is not `Secure`, because that would keep browsers from
/// sending it back to a server that does not speak TLS (the browsers that accept a
/// `Secure` cookie from `localhost` are the exception): set ``secure`` when the server
/// runs behind a proxy that terminates TLS. ``sameSite`` set to ``SameSite/unrestricted``
/// is only accepted by browsers together with ``secure``.
///
/// The value can be any text: the characters that RFC 6265 does not allow in a cookie
/// (spaces, `;`, `,`, quotes, backslashes, `%`, and everything that is not ASCII) are
/// percent-encoded when the cookie is sent, and ``NanoHTTPRequest/cookies`` decodes them
/// again. A cookie that cannot be sent safely is left out of the response, and a warning
/// is logged: a name that is not a token (it has a space, `=`, `;` or a control
/// character, for example), and a `path` or `domain` with a `;` or a control character,
/// which would add attributes of the sender's choosing.
public struct NanoHTTPCookie: Equatable {

  /// The `SameSite` attribute: when the client sends the cookie along with requests that
  /// are caused by other sites.
  public enum SameSite: String {
    
    /// Only with requests that the site of the cookie causes itself.
    case strict = "Strict"
    
    /// Also when a user follows a link to the site, but not for requests that a page of
    /// another site makes (forms, images, scripts).
    case lax = "Lax"
    
    /// With every request. Browsers only accept this together with ``NanoHTTPCookie/secure``.
    /// (Not called `none`: `sameSite: .none` would mean `Optional.none`, no attribute at
    /// all.)
    case unrestricted = "None"
  }

  /// The name of the cookie; it has to be a token (letters, digits and `!#$%&'*+-.^_`|~`).
  public var name: String
  
  /// The text of the cookie, see the type's documentation for how it is encoded.
  public var value: String
  
  /// The paths of the site that the cookie is sent for, and their sub-paths. `nil` leaves
  /// it to the client, which uses the directory of the request.
  public var path: String?
  
  /// The site (and its subdomains) that the cookie is sent to; without it only the host
  /// that set the cookie receives it.
  public var domain: String?
  
  /// How long the cookie lives, in seconds; `0` (or less) deletes it. Without it (and
  /// without ``expires``) the cookie lasts until the client ends its session.
  public var maxAge: Int?
  
  /// When the cookie ends. ``maxAge`` takes precedence in browsers that know it.
  public var expires: Date?
  
  /// Whether the cookie is only sent over a secure connection (`https`).
  public var secure: Bool
  
  /// Whether the cookie is hidden from scripts of the page (`document.cookie`).
  public var httpOnly: Bool
  
  /// Whether the cookie is sent with requests that other sites cause, `nil` for no attribute.
  public var sameSite: SameSite?

  /// Creates a cookie.
  public init(name: String,
              value: String,
              path: String? = "/",
              domain: String? = nil,
              maxAge: Int? = nil,
              expires: Date? = nil,
              secure: Bool = false,
              httpOnly: Bool = true,
              sameSite: SameSite? = .lax) {
    self.name = name
    self.value = value
    self.path = path
    self.domain = domain
    self.maxAge = maxAge
    self.expires = expires
    self.secure = secure
    self.httpOnly = httpOnly
    self.sameSite = sameSite
  }

  /// A cookie that deletes the cookie of the same name, path and domain at the client: it
  /// is empty and has ended.
  public static func expired(name: String, path: String? = "/", domain: String? = nil) -> NanoHTTPCookie {
    return NanoHTTPCookie(name: name,
                          value: "",
                          path: path,
                          domain: domain,
                          maxAge: 0,
                          expires: Date(timeIntervalSince1970: 0),
                          secure: false,
                          httpOnly: false,
                          sameSite: nil)
  }

  /// Why a cookie cannot be sent.
  struct Invalid: LocalizedError, CustomStringConvertible {
    let description: String
    
    var errorDescription: String? {
      return "The cookie cannot be sent".withDetail(self.description)
    }
  }

  /// The value of the `Set-Cookie` header for this cookie.
  ///
  /// - Throws: `Invalid` if the name, the path or the domain would let a response say
  ///   more than it is meant to.
  func headerValue() throws -> String {
    guard NanoHTTPResponseSerializer.isValidHeaderName(self.name) else {
      throw Invalid(description: "the name is not a token")
    }
    var text = "\(self.name)=\(NanoHTTPCookie.encode(self.value))"
    if let path = self.path {
      guard NanoHTTPCookie.isValidAttribute(path) else {
        throw Invalid(description: "the path has a ';' or a control character")
      }
      text += "; Path=\(path)"
    }
    if let domain = self.domain {
      guard NanoHTTPCookie.isValidAttribute(domain) else {
        throw Invalid(description: "the domain has a ';' or a control character")
      }
      text += "; Domain=\(domain)"
    }
    if let maxAge = self.maxAge {
      text += "; Max-Age=\(max(0, maxAge))"
    }
    if let expires = self.expires {
      text += "; Expires=\(NanoHTTPDate.text(for: expires))"
    }
    if self.secure {
      text += "; Secure"
    }
    if self.httpOnly {
      text += "; HttpOnly"
    }
    if let sameSite = self.sameSite {
      text += "; SameSite=\(sameSite.rawValue)"
    }
    return text
  }

  /// An attribute value ends at a `;` and must not hold control characters (RFC 6265 4.1.1).
  private static func isValidAttribute(_ text: String) -> Bool {
    return text.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7F && $0 != UInt8(ascii: ";") }
  }

  /// The characters that a cookie value may have (`cookie-octet` of RFC 6265 4.1.1),
  /// except `%`, which is the escape character here.
  private static func isCookieOctet(_ byte: UInt8) -> Bool {
    return byte == 0x21 ||
           ((0x23...0x2B).contains(byte) && byte != UInt8(ascii: "%")) ||
           (0x2D...0x3A).contains(byte) || (0x3C...0x5B).contains(byte) ||
           (0x5D...0x7E).contains(byte)
  }

  /// `value` with every byte that a cookie cannot hold (and `%`) written as `%XX`.
  static func encode(_ value: String) -> String {
    let bytes = Array(value.utf8)
    if bytes.allSatisfy({ isCookieOctet($0) }) {
      return value
    }
    let digits = Array("0123456789ABCDEF".utf8)
    var encoded = [UInt8]()
    encoded.reserveCapacity(bytes.count + 8)
    for byte in bytes {
      if isCookieOctet(byte) {
        encoded.append(byte)
      } else {
        encoded.append(UInt8(ascii: "%"))
        encoded.append(digits[Int(byte >> 4)])
        encoded.append(digits[Int(byte & 0x0F)])
      }
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  /// The cookies of the value of a `Cookie` request header (`a=1; b=2`): the first one
  /// wins if a name is repeated (the client sends the one with the most specific path
  /// first, RFC 6265 5.4), a pair of quotes around a value is removed, values are
  /// percent-decoded, and entries without a name or without `=` are ignored.
  static func parse(requestHeader header: String) -> [String: String] {
    var cookies = [String: String]()
    for pair in header.split(separator: ";") {
      guard let equals = pair.firstIndex(of: "=") else {
        continue
      }
      let name = pair[pair.startIndex..<equals].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, cookies[name] == nil else {
        continue
      }
      var value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
        value = String(value.dropFirst().dropLast())
      }
      cookies[name] = value.percentDecoded()
    }
    return cookies
  }
}
