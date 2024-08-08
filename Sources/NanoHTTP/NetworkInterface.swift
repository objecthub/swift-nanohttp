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

public struct NetworkInterface {
  public let name: String
  public let ip: String
  public let netmask: String
  
  private init(name: String, ip: String, netmask: String) {
    self.name = name
    self.ip = ip
    self.netmask = netmask
  }
  
  public static var localIP: String? {
    let interfaces = NetworkInterface.enumerate()
    var dict: [String : String] = [:]
    for intf in interfaces {
      dict[intf.name] = intf.ip
    }
    return dict["en0"] ?? dict["en1"] ?? dict["en2"] ?? interfaces.first?.ip
  }
  
  public static func enumerate() -> [NetworkInterface] {
    var interfaces: [NetworkInterface] = []
    // Get list of all interfaces on the local machine.
    var ifaddr : UnsafeMutablePointer<ifaddrs>? = nil
    if getifaddrs(&ifaddr) == 0 {
      // For each interface ...
      var ptr = ifaddr
      while (ptr != nil) {
        let flags = Int32(ptr!.pointee.ifa_flags)
        var addr = ptr!.pointee.ifa_addr.pointee
        // Check for running IPv4, IPv6 interfaces. Skip the loopback interface.
        if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
          if addr.sa_family == UInt8(AF_INET) || addr.sa_family == UInt8(AF_INET6) {
            var mask = ptr!.pointee.ifa_netmask.pointee
            // Convert interface address to a human readable string.
            let zero  = CChar(0)
            var hostname = [CChar](repeating: zero, count: Int(NI_MAXHOST))
            var netmask =  [CChar](repeating: zero, count: Int(NI_MAXHOST))
            if (getnameinfo(&addr,
                            socklen_t(addr.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil,
                            socklen_t(0),
                            NI_NUMERICHOST) == 0) {
              let address = String(cString: hostname)
              let name = ptr!.pointee.ifa_name!
              let ifname = String(cString: name)
              if (getnameinfo(&mask,
                              socklen_t(mask.sa_len),
                              &netmask,
                              socklen_t(netmask.count),
                              nil,
                              socklen_t(0),
                              NI_NUMERICHOST) == 0) {
                let netmaskIP = String(cString: netmask)
                let info = NetworkInterface(name: ifname, ip: address, netmask: netmaskIP)
                interfaces.append(info)
              }
            }
          }
        }
        ptr = ptr!.pointee.ifa_next
      }
      freeifaddrs(ifaddr)
    }
    return interfaces
  }
}
