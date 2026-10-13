//
//  NanoSocketSession.swift
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

/// A conversation over a connection that has been switched away from HTTP, such as a WebSocket, which the
/// server drives one step at a time. A response with such a session
/// (``NanoHTTPResponse/switchProtocols(_:session:)``) turns the connection over to it once the `101` response
/// has been sent.
///
/// The server calls ``start(socket:drainTimeout:)`` once, then ``receive()`` whenever the socket has
/// something to read, and ``end()`` once the session is over. This lets a server that has only one thread
/// (``NanoHTTPServerIO/Configuration/Threading/singleThread``) serve many sessions and all its other
/// connections: it waits for all of them together, and a session never holds the thread longer than
/// it takes to handle one message. A server with a thread per connection calls the same functions on the
/// thread of the connection, which waits for the socket between the calls.
///
/// Implement this protocol for a protocol of your own. For WebSockets, use
/// ``websocket(text:binary:pong:connected:disconnected:maxMessageSize:)``.
///
/// ```swift
/// // file scope
/// /// Answers every line it receives with the same line, in upper case.
/// final class ExampleUppercaseSession: NanoSocketSession {
///   private var socket: NanoSocket?
///
///   func start(socket: NanoSocket, drainTimeout: TimeInterval) {
///     self.socket = socket
///     try? socket.writeUTF8("HELLO\n")
///   }
///
///   func receive() -> Bool {
///     guard let socket, let line = try? socket.readLine() else {
///       return false                                   // the connection has ended
///     }
///     try? socket.writeUTF8(line.uppercased() + "\n")
///     return line != "bye"                             // false ends the session
///   }
///
///   func end() {
///     self.socket = nil
///   }
/// }
/// ```
///
/// The session is used from one thread at a time, but possibly from different threads one after the
/// other. A session that is shared with other code (a hub that sends to all sessions) has to protect what it shares.
public protocol NanoSocketSession: AnyObject {
  /// Called once, after the response has been sent, on the thread that serves the connection.
  ///
  /// The receive timeout of the socket is the ``NanoHTTPServerIO/Configuration/readTimeout`` of the server: a read
  /// that waits longer than that for the rest of a message throws ``NanoSocketError/timedOut``. (The server waits
  /// for the next message itself, without a limit.) `drainTimeout` is how long to read and drop what a client
  /// still sends when the connection is closed because of an error: a connection that is closed while the peer is
  /// still sending is reset, and the peer then loses the last message that the session sent (the close frame of a
  /// WebSocket).
  func start(socket: NanoSocket, drainTimeout: TimeInterval)
  
  /// Called when the socket has data to read, or has been closed by the peer or the server. Reads and
  /// handles what has arrived and returns without waiting for more: a message that is only partly there
  /// can be waited for, up to the read timeout. Returns `false` to end the session.
  func receive() -> Bool
  
  /// Called once when the session is over: after ``receive()`` returned `false`, and when the server stops.
  /// The server closes the socket afterwards.
  func end()
}
