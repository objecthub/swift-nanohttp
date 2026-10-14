//
//  NanoWebSocketHub.swift
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

/// The WebSocket sessions of a server that belong together, such as the participants of a chat, with a way to send
/// a message to all of them.
///
/// A hub is thread-safe: it can be used from the closures of the sessions, from request handlers, and from any other
/// thread, and it needs no locks on your side, also on a server that runs on one thread. The sessions join
/// when ``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:origins:protocols:hub:)``
/// is given the hub, and leave when their connections have ended.
///
/// ```swift
/// let server = NanoHTTPServer()
/// let chat = NanoWebSocketHub()
/// server["/chat"] = NanoWebSocket.handler(
///   text: { session, text in chat.broadcast(text: text, except: session) },
///   hub: chat)
/// server.post["/announce"] = { request in
///   chat.broadcast(text: "Announcement: \(request.bodyString ?? "")")
///   return .ok(.text("sent to \(chat.count) people"))
/// }
/// ```
///
/// A message is written to the sessions one after the other. A client that does not read holds up the ones behind it
/// for at most the ``NanoHTTPServerIO/Configuration/sessionWriteTimeout`` (5 seconds by default); its connection
/// is closed then, and it leaves the hub.
public final class NanoWebSocketHub {
  private let lock = NSLock()
  private var members = [NanoWebSocketSession]()
  
  public init() {
  }
  
  /// The sessions that are in the hub now, in the order in which they joined.
  public var sessions: [NanoWebSocketSession] {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    return self.members
  }
  
  /// The number of sessions that are in the hub now.
  public var count: Int {
    self.lock.lock()
    defer {
      self.lock.unlock()
    }
    return self.members.count
  }
  
  /// Puts a session into the hub, if it is not in it already. Sessions that a handler was given the hub for join
  /// by themselves.
  public func add(_ session: NanoWebSocketSession) {
    self.lock.lock()
    if !self.members.contains(session) {
      self.members.append(session)
    }
    self.lock.unlock()
  }
  
  /// Takes a session out of the hub. Sessions leave by themselves when their connections have ended.
  public func remove(_ session: NanoWebSocketSession) {
    self.lock.lock()
    self.members.removeAll { $0 == session }
    self.lock.unlock()
  }
  
  /// Sends a text message to the sessions of the hub.
  ///
  /// - Parameters:
  ///   - text: The message.
  ///   - except: A session that does not get it, for example the one that the message comes from.
  public func broadcast(text: String, except: NanoWebSocketSession? = nil) {
    let data = Array(text.utf8)[...]
    for session in self.sessions where session != except {
      session.writeFrame(data, .text)
    }
  }
  
  /// Sends a binary message to the sessions of the hub.
  ///
  /// - Parameters:
  ///   - binary: The message.
  ///   - except: A session that does not get it.
  public func broadcast(binary: [UInt8], except: NanoWebSocketSession? = nil) {
    let data = binary[...]
    for session in self.sessions where session != except {
      session.writeFrame(data, .binary)
    }
  }
}
