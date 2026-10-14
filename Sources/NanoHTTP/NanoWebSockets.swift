//
//  NanoWebSockets.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `WebSockets` of framework `Swifter` by Damian Kołakowski.
//
//  Copyright © 2014-2016 Damian Kołakowski. All rights reserved.
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

/// The WebSocket support of the server: ``handler(text:binary:pong:connected:disconnected:maxMessageSize:)``
/// creates the handler that upgrades a request to a WebSocket connection.
public enum NanoWebSocket {
  
  /// Returns a handler that upgrades a request to a WebSocket connection and then calls the given
  /// closures for what the client sends. Register it like any other handler:
  /// `server["/chat"] = NanoWebSocket.handler(text: { session, text in session.writeText(text) })`.
  ///
  /// The closures run on the thread that serves the connection, one message at a time. A closure
  /// that blocks delays the processing of later messages of the same connection only.
  ///
  /// Messages larger than `maxMessageSize` bytes, whether sent as one frame or assembled from
  /// fragments, end the connection.
  ///
  /// The handshake must be a `GET` request for version 13 of the protocol; other versions are
  /// answered with `426 Upgrade Required` (and the header `Sec-WebSocket-Version: 13`). A connection
  /// that ends because of an error is closed with the matching status code (1002 protocol error, 1007
  /// invalid text, 1009 message too big); a close frame of the client is answered with its own code.
  ///
  /// - Parameters:
  ///   - text: Called with every complete text message.
  ///   - binary: Called with every complete binary message.
  ///   - pong: Called with the payload of every pong frame.
  ///   - connected: Called once the connection is established.
  ///   - disconnected: Called once the connection has ended.
  ///   - maxMessageSize: The largest accepted message (and frame payload) in bytes.
  public static func handler(text: ((NanoWebSocketSession, String) -> Void)? = nil,
                             binary: ((NanoWebSocketSession, [UInt8]) -> Void)? = nil,
                             pong: ((NanoWebSocketSession, [UInt8]) -> Void)? = nil,
                             connected: ((NanoWebSocketSession) -> Void)? = nil,
                             disconnected: ((NanoWebSocketSession) -> Void)? = nil,
                             maxMessageSize: Int = 16 * 1024 * 1024) -> NanoHTTPRequestHandler {
    return { request in
      guard request.method == "GET" else {
        return .methodNotAllowed(headers: ["Allow": "GET"], .text("A WebSocket handshake is a GET request"))
      }
      guard request.hasTokenForHeader("upgrade", token: "websocket") else {
        return .badRequest(.text("Invalid value of 'Upgrade' header: \(request.header("upgrade") ?? "unknown")"))
      }
      guard request.hasTokenForHeader("connection", token: "upgrade") else {
        return .badRequest(.text("Invalid value of 'Connection' header: \(request.header("connection") ?? "unknown")"))
      }
      guard let secWebSocketKey = request.header("sec-websocket-key") else {
        return .badRequest(.text("Invalid value of 'Sec-Websocket-Key' header: \(request.header("sec-websocket-key") ?? "unknown")"))
      }
      guard request.header("sec-websocket-version") == "13" else {
        // https://tools.ietf.org/html/rfc6455#section-4.4: tell the client which version this server speaks.
        return NanoHTTPResponse(statusCode: 426,
                                headers: ["Sec-WebSocket-Version": "13"],
                                body: .text("Unsupported WebSocket version: \(request.header("sec-websocket-version") ?? "none")"))
      }
      let driver = NanoWebSocketSessionDriver(text: text,
                                              binary: binary,
                                              pong: pong,
                                              connected: connected,
                                              disconnected: disconnected,
                                              maxMessageSize: maxMessageSize)
      let secWebSocketAccept = String.toBase64((secWebSocketKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").sha1Bytes())
      let headers = [
        "Upgrade": "WebSocket",
        "Connection": "Upgrade",
        "Sec-WebSocket-Accept": secWebSocketAccept
      ]
      return NanoHTTPResponse.switchProtocols(headers, session: driver)
    }
  }
}

/// The part of a WebSocket connection that reads the frames of the client and calls the closures of
/// ``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:)``: one message at a time, as the
/// server tells it that the socket has something to read.
final class NanoWebSocketSessionDriver: NanoSocketSession {
  private let text: ((NanoWebSocketSession, String) -> Void)?
  private let binary: ((NanoWebSocketSession, [UInt8]) -> Void)?
  private let pong: ((NanoWebSocketSession, [UInt8]) -> Void)?
  private let connected: ((NanoWebSocketSession) -> Void)?
  private let disconnected: ((NanoWebSocketSession) -> Void)?
  private let maxMessageSize: Int
  
  private var session: NanoWebSocketSession?
  private var drainTimeout: TimeInterval = 1
  private var logger: NanoHTTPLogger = NanoSilentLogger()
  private var fragmentedOpCode = NanoWebSocketSession.OpCode.close
  private var payload = [UInt8]() // Used for fragmented frames.
  private var closeCode: UInt16? = nil // The status code of the close frame of the client, if it has one.
  private var failed = false
  private var ended = false
  
  init(text: ((NanoWebSocketSession, String) -> Void)?,
       binary: ((NanoWebSocketSession, [UInt8]) -> Void)?,
       pong: ((NanoWebSocketSession, [UInt8]) -> Void)?,
       connected: ((NanoWebSocketSession) -> Void)?,
       disconnected: ((NanoWebSocketSession) -> Void)?,
       maxMessageSize: Int) {
    self.text = text
    self.binary = binary
    self.pong = pong
    self.connected = connected
    self.disconnected = disconnected
    self.maxMessageSize = maxMessageSize
  }
  
  func start(socket: NanoSocket, drainTimeout: TimeInterval, logger: NanoHTTPLogger) {
    let session = NanoWebSocketSession(socket)
    session.logger = logger
    self.logger = logger
    session.maxPayloadSize = self.maxMessageSize
    self.session = session
    self.drainTimeout = drainTimeout
    self.connected?(session)
  }
  
  /// Reads one frame (waiting for the rest of it for at most the read timeout) and handles it.
  func receive() -> Bool {
    guard let session, !self.ended else {
      return false
    }
    do {
      try self.handleOperationCode(try session.readFrame())
      return true
    } catch {
      self.finish(with: error)
      return false
    }
  }
  
  func end() {
    guard let session, !self.ended else {
      return
    }
    self.ended = true
    self.disconnected?(session)
    if self.failed {
      // The client may still be sending (e.g. the rest of a refused frame): let it read our close
      // frame instead of resetting the connection.
      session.socket.closeAfterDraining(timeout: self.drainTimeout)
    }
  }
  
  private func ensureMessageFits(adding frame: NanoWebSocketSession.Frame) throws {
    if self.payload.count + frame.payload.count > self.maxMessageSize {
      throw NanoWebSocketSession.WsError.messageTooBig("Message exceeds \(self.maxMessageSize) bytes.")
    }
  }
  
  private func handleTextPayload(_ frame: NanoWebSocketSession.Frame, _ session: NanoWebSocketSession) throws {
    if let handleText = self.text {
      if frame.fin {
        if self.payload.count > 0 {
          throw NanoWebSocketSession.WsError.protocolError("Continuing fragmented frame cannot have an operation code.")
        }
        // Not `String(validatingUTF8:)`: that reads a C string and stops at the first NUL.
        if let text = String(bytes: frame.payload, encoding: .utf8) {
          handleText(session, text)
        } else {
          throw NanoWebSocketSession.WsError.invalidUTF8("")
        }
      } else {
        try self.ensureMessageFits(adding: frame)
        self.payload.append(contentsOf: frame.payload)
        self.fragmentedOpCode = .text
      }
    }
  }
  
  private func handleBinaryPayload(_ frame: NanoWebSocketSession.Frame, _ session: NanoWebSocketSession) throws {
    if let handleBinary = self.binary {
      if frame.fin {
        if self.payload.count > 0 {
          throw NanoWebSocketSession.WsError.protocolError("Continuing fragmented frame cannot have an operation code.")
        }
        handleBinary(session, frame.payload)
      } else {
        try self.ensureMessageFits(adding: frame)
        self.payload.append(contentsOf: frame.payload)
        self.fragmentedOpCode = .binary
      }
    }
  }
  
  private func handleOperationCode(_ frame: NanoWebSocketSession.Frame) throws {
    guard let session else {
      return
    }
    switch frame.opcode {
      case .continue:
        // There is no message to continue, failed immediatelly.
        if self.fragmentedOpCode == .close {
          session.socket.close()
        }
        frame.opcode = self.fragmentedOpCode
        if frame.fin {
          try self.ensureMessageFits(adding: frame)
          self.payload.append(contentsOf: frame.payload)
          frame.payload = self.payload
          // Clean the buffer.
          self.payload = []
          // Reset the OpCode.
          self.fragmentedOpCode = NanoWebSocketSession.OpCode.close
        }
        try self.handleOperationCode(frame)
      case .text:
        try self.handleTextPayload(frame, session)
      case .binary:
        try self.handleBinaryPayload(frame, session)
      case .close:
        // https://tools.ietf.org/html/rfc6455#section-5.5.1: no payload, or a status code (two
        // bytes) with an optional reason.
        if frame.payload.count == 1 {
          throw NanoWebSocketSession.WsError.protocolError("A close frame cannot have a payload of one byte.")
        }
        if frame.payload.count >= 2 {
          let code = UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
          guard NanoWebSocketSession.isValidCloseCode(code) else {
            throw NanoWebSocketSession.WsError.protocolError("Invalid close code \(code).")
          }
          self.closeCode = code
        }
        throw NanoWebSocketSession.Control.close
      case .ping:
        if frame.payload.count > 125 {
          throw NanoWebSocketSession.WsError.protocolError("Payload gretter than 125 octets.")
        } else {
          session.writeFrame(ArraySlice(frame.payload), .pong)
        }
      case .pong:
        if let handlePong = self.pong {
          handlePong(session, frame.payload)
        }
    }
  }
  
  /// Tells the client why the connection ends (RFC 6455 7.4): the error decides the status code of the close
  /// frame.
  private func finish(with error: Error) {
    guard let session else {
      return
    }
    var code: UInt16? = nil
    switch error {
      case NanoWebSocketSession.Control.close:
        // Normal close: answer with the status code of the client.
        code = self.closeCode
      case NanoWebSocketSession.WsError.unknownOpCode:
        self.logger.info("WebSocket: unknown operation code (\(error))")
        code = NanoWebSocketSession.CloseCode.protocolError
      case NanoWebSocketSession.WsError.unMaskedFrame:
        self.logger.info("WebSocket: unmasked frame (\(error))")
        code = NanoWebSocketSession.CloseCode.protocolError
      case NanoWebSocketSession.WsError.invalidUTF8:
        self.logger.info("WebSocket: invalid UTF-8 text (\(error))")
        code = NanoWebSocketSession.CloseCode.invalidPayload
      case NanoWebSocketSession.WsError.messageTooBig:
        self.logger.info("WebSocket: message too big (\(error))")
        code = NanoWebSocketSession.CloseCode.messageTooBig
      case NanoWebSocketSession.WsError.protocolError:
        self.logger.info("WebSocket: protocol error (\(error))")
        code = NanoWebSocketSession.CloseCode.protocolError
      default:
        self.logger.warning("WebSocket: the session ended because of an unexpected error (\(error))")
    }
    // If an error occurs, send the close handshake.
    if let code {
      session.writeCloseFrame(code: code)
    } else {
      session.writeCloseFrame()
    }
    if case NanoWebSocketSession.Control.close = error {} else {
      self.failed = true
    }
  }
}

/// One WebSocket connection. Sessions are what the closures of `NanoWebSocket.handler(...)` receive; keep them
/// (for example in a set, to broadcast) and drop them in `disconnected`.
///
/// All `write...` methods may be called from any thread at any time: concurrent calls are
/// serialized, so frames never interleave. After the connection has ended, writing is a harmless
/// no-op that is logged at the level ``NanoLogLevel/info`` (if the session has a ``logger``).
public class NanoWebSocketSession: Hashable, Equatable {
  
  /// Violations of the WebSocket protocol that end a connection.
  public enum WsError: Error {
    /// A frame has an operation code that does not exist.
    case unknownOpCode(String)
    /// A frame of the client was not masked, as the protocol demands.
    case unMaskedFrame(String)
    /// Another violation of the protocol.
    case protocolError(String)
    /// A text message is not valid UTF-8.
    case invalidUTF8(String)
    /// A frame or a message is larger than the limit (close code 1009).
    case messageTooBig(String)
  }
  
  /// The operation codes of frames.
  public enum OpCode: UInt8 {
    /// A continuation of a message that is sent in several frames.
    case `continue` = 0x00
    /// The connection is closed.
    case close = 0x08
    /// A ping: the peer answers with a pong that has the same payload.
    case ping = 0x09
    /// The answer to a ping.
    case pong = 0x0A
    /// A text message (UTF-8).
    case text = 0x01
    /// A binary message.
    case binary = 0x02
  }
  
  /// Not an error: how the processing of a connection is told that the client closed it.
  public enum Control: Error {
    /// The client closed the connection.
    case close
  }
  
  /// A frame as it was read from the connection.
  public class Frame {
    /// The kind of the frame.
    public var opcode = OpCode.close
    /// Whether this frame is the last one of its message.
    public var fin = false
    /// A reserved bit; frames with a reserved bit are refused.
    public var rsv1: UInt8 = 0
    /// A reserved bit; frames with a reserved bit are refused.
    public var rsv2: UInt8 = 0
    /// A reserved bit; frames with a reserved bit are refused.
    public var rsv3: UInt8 = 0
    /// The content of the frame, unmasked.
    public var payload = [UInt8]()
  }
  
  /// The socket of the connection.
  public let socket: NanoSocket
  
  /// Serializes writing frames: a frame consists of several parts, and the writes of two threads
  /// must not be mixed.
  private let writeLock = NSLock()
  
  /// The largest frame payload `readFrame()` accepts, in bytes. A frame that announces more is
  /// rejected with `WsError.protocolError` before any of its payload is read.
  public var maxPayloadSize = 16 * 1024 * 1024
  
  /// Receives what goes wrong when the session writes (a frame that cannot be written because the
  /// client has gone). The server sets the logger of its sessions to its own; a session that is created
  /// by hand logs nothing.
  public var logger: NanoHTTPLogger?
  
  /// Creates a session for an established connection. Sessions are normally created by ``NanoWebSocket/handler(text:binary:pong:connected:disconnected:maxMessageSize:)``.
  public init(_ socket: NanoSocket) {
    self.socket = socket
  }
  
  deinit {
    // A courtesy for a session that is dropped while its connection is still open. When the connection
    // has ended already (the server closes it after the close handshake), there is nobody to tell.
    if !self.socket.isClosed {
      self.writeCloseFrame()
    }
    self.socket.close()
  }
  
  /// Sends a text message in one frame.
  public func writeText(_ text: String) {
    self.writeFrame(ArraySlice(text.utf8), OpCode.text)
  }
  
  /// Sends a binary message in one frame.
  public func writeBinary(_ binary: [UInt8]) {
    self.writeBinary(ArraySlice(binary))
  }
  
  /// Sends a binary message in one frame.
  public func writeBinary(_ binary: ArraySlice<UInt8>) {
    self.writeFrame(binary, OpCode.binary)
  }
  
  /// Sends one frame. May be called from any thread: frames of different threads are written one
  /// after the other and never interleave.
  public func writeFrame(_ data: ArraySlice<UInt8>, _ op: OpCode, _ fin: Bool = true) {
    var header: [UInt8] = [UInt8(fin ? 0x80 : 0x00) | op.rawValue]
    header.append(contentsOf: self.encodeLengthAndMaskFlag(UInt64(data.count), false))
    self.writeLock.lock()
    defer {
      self.writeLock.unlock()
    }
    do {
      if data.count <= NanoWebSocketSession.coalescingLimit {
        // Small frames go out in a single write (and so in a single TCP segment, where possible).
        try self.socket.writeUInt8(header + data)
      } else {
        try self.socket.writeUInt8(header)
        try self.socket.writeUInt8(data)
      }
    } catch {
      self.logger?.info("WebSocket: unable to write a frame (\(error))")
    }
  }
  
  /// Sends a close frame without a status code.
  public func writeCloseFrame() {
    writeFrame(ArraySlice("".utf8), .close)
  }
  
  /// Sends a close frame with a status code (see `CloseCode`) and an optional reason, which is
  /// shown to the peer and must be short (at most 123 bytes; longer reasons are cut).
  public func writeCloseFrame(code: UInt16, reason: String = "") {
    var payload: [UInt8] = [UInt8(code >> 8), UInt8(code & 0xFF)]
    payload.append(contentsOf: reason.utf8.prefix(123))
    writeFrame(ArraySlice(payload), .close)
  }
  
  /// Status codes of close frames (https://tools.ietf.org/html/rfc6455#section-7.4.1).
  public enum CloseCode {
    /// The purpose of the connection has been fulfilled.
    public static let normal: UInt16 = 1000
    /// The endpoint goes away (the server shuts down).
    public static let goingAway: UInt16 = 1001
    /// The peer violated the protocol.
    public static let protocolError: UInt16 = 1002
    /// The endpoint cannot handle the kind of data it received.
    public static let unsupportedData: UInt16 = 1003
    /// A message is inconsistent with its type (text that is not UTF-8).
    public static let invalidPayload: UInt16 = 1007
    /// A message violates a policy of the endpoint.
    public static let policyViolation: UInt16 = 1008
    /// A message is too large to process.
    public static let messageTooBig: UInt16 = 1009
    /// The server met an unexpected condition.
    public static let internalError: UInt16 = 1011
  }
  
  /// Is `code` allowed in a close frame that is sent over the wire?
  static func isValidCloseCode(_ code: UInt16) -> Bool {
    return (1000...1003).contains(code) || (1007...1014).contains(code) || (3000...4999).contains(code)
  }
  
  /// Frames up to this size are written together with their header in one call.
  private static let coalescingLimit = 64 * 1024
  
  private func encodeLengthAndMaskFlag(_ len: UInt64, _ masked: Bool) -> [UInt8] {
    let encodedLngth = UInt8(masked ? 0x80 : 0x00)
    var encodedBytes = [UInt8]()
    switch len {
      case 0...125:
        encodedBytes.append(encodedLngth | UInt8(len))
      case 126...UInt64(UINT16_MAX):
        encodedBytes.append(encodedLngth | 0x7E)
        encodedBytes.append(UInt8(len >> 8 & 0xFF))
        encodedBytes.append(UInt8(len >> 0 & 0xFF))
      default:
        encodedBytes.append(encodedLngth | 0x7F)
        encodedBytes.append(UInt8(len >> 56 & 0xFF))
        encodedBytes.append(UInt8(len >> 48 & 0xFF))
        encodedBytes.append(UInt8(len >> 40 & 0xFF))
        encodedBytes.append(UInt8(len >> 32 & 0xFF))
        encodedBytes.append(UInt8(len >> 24 & 0xFF))
        encodedBytes.append(UInt8(len >> 16 & 0xFF))
        encodedBytes.append(UInt8(len >> 08 & 0xFF))
        encodedBytes.append(UInt8(len >> 00 & 0xFF))
    }
    return encodedBytes
  }
  
  /// Reads the next frame: a masked frame of the client with a payload of at most ``maxPayloadSize`` bytes
  /// (control frames: 125). Blocks until the frame is complete.
  ///
  /// - Throws: ``WsError`` for violations of the protocol, `NanoSocketError` if the connection ends.
  public func readFrame() throws -> Frame {
    let frm = Frame()
    let fst = try socket.read()
    frm.fin = fst & 0x80 != 0
    frm.rsv1 = fst & 0x40
    frm.rsv2 = fst & 0x20
    frm.rsv3 = fst & 0x10
    guard frm.rsv1 == 0 && frm.rsv2 == 0 && frm.rsv3 == 0 else {
      throw WsError.protocolError("Reserved frame bit has not been negociated.")
    }
    let opc = fst & 0x0F
    guard let opcode = OpCode(rawValue: opc) else {
      // "If an unknown opcode is received, the receiving endpoint MUST _Fail the WebSocket Connection_."
      // http://tools.ietf.org/html/rfc6455#section-5.2 ( Page 29 )
      throw WsError.unknownOpCode("\(opc)")
    }
    if frm.fin == false {
      switch opcode {
        case .ping, .pong, .close:
          // Control frames must not be fragmented
          // https://tools.ietf.org/html/rfc6455#section-5.5 ( Page 35 )
          throw WsError.protocolError("Control frames must not be fragmented.")
        default:
          break
      }
    }
    frm.opcode = opcode
    let sec = try socket.read()
    let msk = sec & 0x80 != 0
    guard msk else {
      // "...a client MUST mask all frames that it sends to the server."
      // http://tools.ietf.org/html/rfc6455#section-5.1
      throw WsError.unMaskedFrame("A client must mask all frames that it sends to the server.")
    }
    var len = UInt64(sec & 0x7F)
    if len == 0x7E {
      // 16-bit length, network byte order.
      let b0 = UInt64(try socket.read()) << 8
      let b1 = UInt64(try socket.read())
      len = b0 | b1
    } else if len == 0x7F {
      // 64-bit length, network byte order.
      let b0 = UInt64(try socket.read()) << 56
      let b1 = UInt64(try socket.read()) << 48
      let b2 = UInt64(try socket.read()) << 40
      let b3 = UInt64(try socket.read()) << 32
      let b4 = UInt64(try socket.read()) << 24
      let b5 = UInt64(try socket.read()) << 16
      let b6 = UInt64(try socket.read()) << 8
      let b7 = UInt64(try socket.read())
      len = b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7
    }
    if opcode == .close || opcode == .ping || opcode == .pong, len > 125 {
      // https://tools.ietf.org/html/rfc6455#section-5.5
      throw WsError.protocolError("Control frames must not carry more than 125 bytes.")
    }
    guard len <= UInt64(max(0, self.maxPayloadSize)) else {
      throw WsError.messageTooBig("Frame of \(len) bytes exceeds the limit of \(self.maxPayloadSize) bytes.")
    }
    
    let mask = [try socket.read(), try socket.read(), try socket.read(), try socket.read()]
    // Read payload all at once, then apply mask (calling `socket.read` byte-by-byte is super slow).
    frm.payload = try socket.read(length: Int(len))
    for index in 0..<frm.payload.count {
      frm.payload[index] ^= mask[index % 4]
    }
    return frm
  }
  
  /// Sessions are hashed by their socket, so that they can be kept in a `Set`.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(socket)
  }
  
  /// Sessions are equal if they have the same socket.
  public static func == (wss1: NanoWebSocketSession, wss2: NanoWebSocketSession) -> Bool {
      return wss1.socket == wss2.socket
  }
}
