//
//  NanoRequestPolicy.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 14/10/2026.
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

/// The checks of the `Host` and `Origin` headers of requests: the policies in the
/// configuration of a server (``NanoHTTPServerIO/Configuration/hostPolicy``,
/// ``NanoHTTPServerIO/Configuration/originPolicy``) and the middleware of ``NanoMiddleware``
/// use the same functions.
enum NanoRequestPolicy {
  
  /// What a request is refused for: the text for the client, and the details for the log.
  struct Refusal {
    let message: String
    let detail: String
  }
  
  /// The host and the port of a `Host` header or of the address in an `Origin`: the host
  /// in lower case (an IPv6 address keeps its brackets), and the port if there is one.
  struct Authority: Equatable {
    let host: String
    let port: Int?
  }
  
  /// The origin of a page: scheme, host and port.
  struct Origin {
    let scheme: String
    let authority: Authority
    
    /// The port that the origin is at: the one that is written, or the one of its scheme.
    var effectivePort: Int? {
      return self.authority.port ?? NanoRequestPolicy.defaultPort(of: self.scheme)
    }
  }
  
  static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "[::1]"]
  
  static func defaultPort(of scheme: String) -> Int? {
    switch scheme {
      case "http", "ws": return 80
      case "https", "wss": return 443
      default: return nil
    }
  }
  
  // MARK: - Parsing
  
  /// Reads `host`, `host:port`, `[v6]` or `[v6]:port`. `nil` if the text is not that:
  /// other characters than the ones of a host name (a path, a user name, a second colon),
  /// or a port that is not a number.
  ///
  /// This runs for every request of a server that has switched a policy on, so it looks
  /// at the bytes and builds one string.
  static func authority(_ text: String) -> Authority? {
    return self.authority(Array(text.utf8)[...])
  }
  
  private static func authority(_ input: ArraySlice<UInt8>) -> Authority? {
    var bytes = input
    while let first = bytes.first, first == 32 || first == 9 { // spaces around the value
      bytes = bytes.dropFirst()
    }
    while let last = bytes.last, last == 32 || last == 9 {
      bytes = bytes.dropLast()
    }
    guard !bytes.isEmpty else {
      return nil
    }
    var lower = [UInt8]()
    lower.reserveCapacity(bytes.count)
    for byte in bytes {
      switch byte {
        case 33...126 where byte != 47 && byte != 64 && byte != 63 &&
                            byte != 35 && byte != 92 && byte != 37:
          // printable ASCII, but no `/ @ ? # \ %`
          lower.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
        default:
          return nil
      }
    }
    var hostEnd = lower.count
    var portStart: Int? = nil
    if lower[0] == 91 { // `[`: an IPv6 address
      guard let close = lower.firstIndex(of: 93), close >= 2, !lower[1..<close].contains(91) else {
        return nil
      }
      hostEnd = close + 1
      if hostEnd < lower.count {
        guard lower[hostEnd] == 58 else { // `:`
          return nil
        }
        portStart = hostEnd + 1
      }
    } else {
      if let colon = lower.firstIndex(of: 58) {
        guard colon > 0, !lower[(colon + 1)...].contains(58) else {
          return nil
        }
        hostEnd = colon
        portStart = colon + 1
      }
      guard !lower[..<hostEnd].contains(91), !lower[..<hostEnd].contains(93) else {
        return nil
      }
    }
    let host = String(decoding: lower[..<hostEnd], as: UTF8.self)
    guard let portStart else {
      return Authority(host: host, port: nil)
    }
    let digits = lower[portStart...]
    guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
      return nil
    }
    let port = digits.reduce(0) { $0 * 10 + Int($1 - 48) }
    guard port <= 65535 else {
      return nil
    }
    return Authority(host: host, port: port)
  }
  
  /// Reads `scheme://host[:port]`. `nil` for `null` (a page without an origin) and
  /// everything else.
  static func origin(_ text: String) -> Origin? {
    let bytes = Array(text.utf8)
    var separator: Int? = nil
    var index = 0
    while index + 2 < bytes.count { // `://`
      if bytes[index] == 58 && bytes[index + 1] == 47 && bytes[index + 2] == 47 {
        separator = index
        break
      }
      index += 1
    }
    guard let separator, separator > 0 else {
      return nil
    }
    var scheme = [UInt8]()
    var start = 0
    while start < separator, bytes[start] == 32 || bytes[start] == 9 {
      start += 1
    }
    guard start < separator else {
      return nil
    }
    for position in start..<separator {
      var byte = bytes[position]
      if byte >= 65 && byte <= 90 {
        byte += 32
      }
      let letter = byte >= 97 && byte <= 122
      let other = (byte >= 48 && byte <= 57) || byte == 43 || byte == 45 || byte == 46
      // starts with a letter; then letters, digits and `+-.`
      guard letter || (other && position > start) else {
        return nil
      }
      scheme.append(byte)
    }
    guard let authority = self.authority(bytes[(separator + 3)...]) else {
      return nil
    }
    return Origin(scheme: String(decoding: scheme, as: UTF8.self), authority: authority)
  }
  
  // MARK: - Hosts
  
  /// Whether a `Host` header is allowed by the policy of a server that listens at
  /// `address`. A request without a `Host` header (HTTP/1.0) is allowed: a page that is
  /// made to talk to this server always sends one.
  static func hostAllowed(_ header: String?,
                          policy: NanoHTTPServerIO.Configuration.HostPolicy,
                          listenAddress address: NanoHTTPServerIO.NanoListenAddress) -> Bool {
    switch policy {
      case .any:
        return true
      case .automatic:
        guard self.isLoopback(address), let header else {
          return true
        }
        guard let authority = self.authority(header) else {
          return false
        }
        return self.loopbackNames.contains(authority.host)
      case .hosts(let allowed):
        guard let header else {
          return true
        }
        guard let authority = self.authority(header) else {
          return false
        }
        return allowed.contains { entry in
          guard let allowed = self.authority(entry), allowed.host == authority.host else {
            return false
          }
          return allowed.port == nil || allowed.port == authority.port
        }
    }
  }
  
  private static func isLoopback(_ address: NanoHTTPServerIO.NanoListenAddress) -> Bool {
    switch address {
      case .loopback:
        return true
      case .allInterfaces:
        return false
      case .address(let text):
        return text.hasPrefix("127.") || text == "::1" || text == "[::1]"
    }
  }
  
  // MARK: - Origins
  
  /// Whether a page with this origin is one of the server itself (the address of the
  /// request is its origin's) or one of the `listed` origins.
  static func originAllowed(_ header: String, host: String?, listed: [String]) -> Bool {
    guard let origin = self.origin(header) else {
      return false
    }
    if let host, let authority = self.authority(host) {
      // a host without a port: the one of the page
      let port = authority.port ?? self.defaultPort(of: origin.scheme)
      if authority.host == origin.authority.host && port == origin.effectivePort {
        return true
      }
    }
    return listed.contains { entry in
      guard let other = self.origin(entry) else {
        return false
      }
      return other.scheme == origin.scheme && other.authority.host == origin.authority.host
               && other.effectivePort == origin.effectivePort
    }
  }
  
  /// The requests that the origin policy looks at: those that change something, and
  /// WebSocket handshakes.
  static func isChecked(_ request: NanoHTTPRequest) -> Bool {
    switch request.method {
      case "GET", "HEAD", "OPTIONS", "TRACE":
        return request.hasTokenForHeader("upgrade", token: "websocket")
      default:
        return true
    }
  }
  
  // MARK: - Requests
  
  static func refusal(for request: NanoHTTPRequest,
                      _ configuration: NanoHTTPServerIO.Configuration) -> Refusal? {
    if case .any = configuration.hostPolicy, case .any = configuration.originPolicy {
      return nil // nothing to check: the default
    }
    if let refusal = self.hostRefusal(request,
                                      policy: configuration.hostPolicy,
                                      listenAddress: configuration.listenAddress) {
      return refusal
    }
    switch configuration.originPolicy {
      case .any:
        return nil
      case .sameOrigin:
        return self.originRefusal(request, listed: [])
      case .origins(let listed):
        return self.originRefusal(request, listed: listed)
    }
  }
  
  static func hostRefusal(_ request: NanoHTTPRequest,
                          policy: NanoHTTPServerIO.Configuration.HostPolicy,
                          listenAddress: NanoHTTPServerIO.NanoListenAddress) -> Refusal? {
    let header = request.header("host")
    guard !self.hostAllowed(header, policy: policy, listenAddress: listenAddress) else {
      return nil
    }
    return Refusal(message: "Forbidden: this server does not answer the host that the request is for",
                   detail: "the Host \(String(reflecting: header ?? "")) is not allowed")
  }
  
  static func originRefusal(_ request: NanoHTTPRequest, listed: [String]) -> Refusal? {
    guard let origin = request.header("origin"), self.isChecked(request) else {
      return nil
    }
    guard !self.originAllowed(origin, host: request.header("host"), listed: listed) else {
      return nil
    }
    return Refusal(
      message: "Forbidden: this server does not answer pages of the site that the request comes from",
      detail: "the Origin \(String(reflecting: origin)) is not allowed (Host: " +
              "\(String(reflecting: request.header("host") ?? "")))")
  }
}
