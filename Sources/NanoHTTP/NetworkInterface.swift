//
//  NetworkInterfaces.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 08/08/2024.
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

/// An IP address of a network interface of this machine.
public struct NetworkInterface: Hashable {
  /// The name of the interface, e.g. `en0`.
  public let name: String
  
  /// Is `ip` an IPv4 address? (Otherwise it is an IPv6 address.)
  public let ipv4: Bool
  
  /// The address in its usual text form. Link-local IPv6 addresses carry the zone of the
  /// interface: `fe80::1%en0`.
  public let ip: String
  
  /// The netmask in the same form as `ip` (`255.255.255.0`); empty if the system does not report one.
  public let netmask: String
  
  init(name: String, ipv4: Bool, ip: String, netmask: String) {
    self.name = name
    self.ipv4 = ipv4
    self.ip = ip
    self.netmask = netmask
  }
  
  /// The address under which other machines most likely reach this one: the IPv4 address of
  /// `localIP(ipv4: true)`, or, if there is none, the IPv6 address of `localIP(ipv4: false)`.
  public static var localIP: String? {
    return Self.localIP(ipv4: true) ?? Self.localIP(ipv4: false)
  }
  
  /// The address of the preferred interface (see `preferred(among:)`) for the given IP version.
  public static func localIP(ipv4: Bool = true) -> String? {
    return Self.preferred(among: Self.available().filter { $0.ipv4 == ipv4 })?.ip
  }
  
  /// The interface that is most likely the one that is connected to the local network. Wired and
  /// Wi-Fi interfaces (`en0`, `en1`, ...) come first, in numeric order; link-local addresses
  /// (`169.254.x.x`, `fe80::`) come after all others. Among equals the name and address decide, so
  /// the result does not depend on the order in which the system lists the interfaces.
  static func preferred(among interfaces: Set<NetworkInterface>) -> NetworkInterface? {
    func rank(_ interface: NetworkInterface) -> (Int, Int, String, String) {
      let linkLocal = interface.ip.hasPrefix("169.254.") || interface.ip.lowercased().hasPrefix("fe80:")
      var number = Int.max
      if interface.name.hasPrefix("en"), let n = Int(interface.name.dropFirst(2)) {
        number = n
      }
      return (linkLocal ? 1 : 0, number, interface.name, interface.ip)
    }
    return interfaces.min { rank($0) < rank($1) }
  }
  
  /// All addresses of the interfaces that are up and running, except loopback.
  public static func available() -> Set<NetworkInterface> {
    var interfaces: Set<NetworkInterface> = []
    // Get list of all interfaces on the local machine.
    var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
    if getifaddrs(&ifaddr) == 0 {
      defer {
        freeifaddrs(ifaddr)
      }
      var cursor = ifaddr
      while let entry = cursor {
        if let interface = NetworkInterface.interface(from: entry.pointee) {
          interfaces.insert(interface)
        }
        cursor = entry.pointee.ifa_next
      }
    }
    return interfaces
  }
  
  /// The address that an entry of the list of `getifaddrs` stands for. `nil` for entries that are
  /// not usable: interfaces that are down or loopback, entries without an address, and addresses
  /// that are neither IPv4 nor IPv6 (link layer addresses, for example).
  static func interface(from entry: ifaddrs) -> NetworkInterface? {
    // Check for running IPv4, IPv6 interfaces. Skip the loopback interface.
    let flags = Int32(entry.ifa_flags)
    guard flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK) == (IFF_UP | IFF_RUNNING),
          let address = entry.ifa_addr,   // some entries (tunnels, for example) have no address
          let nameBytes = entry.ifa_name else {
      return nil
    }
    let family = Int32(address.pointee.sa_family)
    guard family == AF_INET || family == AF_INET6 else {
      return nil
    }
    // Hand over the address where it is stored, with the size of its real type: copying it into a
    // `sockaddr` would cut an IPv6 address (`sockaddr_in6` is larger) and garble it.
    let size = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(address, socklen_t(size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
      return nil
    }
    return NetworkInterface(name: String(cString: nameBytes),
                            ipv4: family == AF_INET,
                            ip: String(cString: host),
                            netmask: entry.ifa_netmask.map { Self.text(ofNetmask: $0, ipv4: family == AF_INET) } ?? "")
  }
  
  /// The text form of a netmask. The system may store a netmask with its trailing zero bytes cut
  /// off (`sa_len` is smaller than the structure, and `sa_family` is not reliable), so the bytes
  /// are copied into a zeroed structure of the right type and printed from there.
  private static func text(ofNetmask mask: UnsafePointer<sockaddr>, ipv4: Bool) -> String {
    var storage = sockaddr_storage()
    let length = min(Int(mask.pointee.sa_len), MemoryLayout<sockaddr_storage>.size)
    memcpy(&storage, mask, length)
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    withUnsafePointer(to: &storage) { pointer in
      if ipv4 {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
          var address = inet.pointee.sin_addr
          inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
        }
      } else {
        pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet6 in
          var address = inet6.pointee.sin6_addr
          inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
        }
      }
    }
    return String(cString: buffer)
  }
}
