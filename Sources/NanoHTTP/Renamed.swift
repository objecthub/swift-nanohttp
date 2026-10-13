//
//  Renamed.swift
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

// Names of NanoHTTP 1.x that have a new name in 2.0. They cannot be used any more: the compiler
// reports the new name, and Xcode offers to replace the old one. They are removed in the next
// major version.

@available(*, unavailable, renamed: "NanoFiles.share(file:)")
public func share(file path: String) -> NanoHTTPRequestHandler {
  fatalError("renamed to NanoFiles.share(file:)")
}

@available(*, unavailable, renamed: "NanoFiles.share(directory:defaults:followSymlinks:)")
public func share(directory path: String,
                  defaults: [String] = ["index.html", "default.html"],
                  followSymlinks: Bool = false) -> NanoHTTPRequestHandler {
  fatalError("renamed to NanoFiles.share(directory:defaults:followSymlinks:)")
}

@available(*, unavailable, renamed: "NanoFiles.browse(directory:followSymlinks:)")
public func browse(directory dir: String, followSymlinks: Bool = false) -> NanoHTTPRequestHandler {
  fatalError("renamed to NanoFiles.browse(directory:followSymlinks:)")
}

@available(*, unavailable,
           renamed: "NanoWebSocket.handler(text:binary:pong:connected:disconnected:maxMessageSize:)")
public func websocket(text: ((NanoWebSocketSession, String) -> Void)? = nil,
                      binary: ((NanoWebSocketSession, [UInt8]) -> Void)? = nil,
                      pong: ((NanoWebSocketSession, [UInt8]) -> Void)? = nil,
                      connected: ((NanoWebSocketSession) -> Void)? = nil,
                      disconnected: ((NanoWebSocketSession) -> Void)? = nil,
                      maxMessageSize: Int = 16 * 1024 * 1024) -> NanoHTTPRequestHandler {
  fatalError("renamed to NanoWebSocket.handler(text:binary:pong:connected:disconnected:maxMessageSize:)")
}

@available(*, unavailable, renamed: "NanoWebSocketSession")
public typealias WebSocketSession = NanoWebSocketSession

@available(*, unavailable, renamed: "NanoNetworkInterface")
public typealias NetworkInterface = NanoNetworkInterface

extension String {
  @available(*, unavailable, renamed: "NanoFile")
  public typealias File = NanoFile
  
  @available(*, unavailable, renamed: "NanoFileError")
  public typealias FileError = NanoFileError
  
  @available(*, unavailable, message: "Use NanoFiles.mimeType(forPath:) instead")
  public func mimeType() -> String {
    fatalError("replaced by NanoFiles.mimeType(forPath:)")
  }
}
