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

/// Returns a handler that upgrades a request to a WebSocket connection and then calls the given
/// closures for what the client sends. Register it like any other handler:
/// `server["/chat"] = websocket(text: { session, text in session.writeText(text) })`.
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
public func websocket(text: ((WebSocketSession, String) -> Void)? = nil,
                      binary: ((WebSocketSession, [UInt8]) -> Void)? = nil,
                      pong: ((WebSocketSession, [UInt8]) -> Void)? = nil,
                      connected: ((WebSocketSession) -> Void)? = nil,
                      disconnected: ((WebSocketSession) -> Void)? = nil,
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
    let protocolSessionClosure: ((NanoSocket) -> Void) = { socket in
      let session = WebSocketSession(socket)
      session.maxPayloadSize = maxMessageSize
      var fragmentedOpCode = WebSocketSession.OpCode.close
      var payload = [UInt8]() // Used for fragmented frames.
      var closeCode: UInt16? = nil // The status code of the close frame of the client, if it has one.
      
      func ensureMessageFits(adding frame: WebSocketSession.Frame) throws {
        if payload.count + frame.payload.count > maxMessageSize {
          throw WebSocketSession.WsError.messageTooBig("Message exceeds \(maxMessageSize) bytes.")
        }
      }
      
      func handleTextPayload(_ frame: WebSocketSession.Frame) throws {
        if let handleText = text {
          if frame.fin {
            if payload.count > 0 {
              throw WebSocketSession.WsError.protocolError("Continuing fragmented frame cannot have an operation code.")
            }
            // Not `String(validatingUTF8:)`: that reads a C string and stops at the first NUL.
            if let text = String(bytes: frame.payload, encoding: .utf8) {
              handleText(session, text)
            } else {
              throw WebSocketSession.WsError.invalidUTF8("")
            }
          } else {
            try ensureMessageFits(adding: frame)
            payload.append(contentsOf: frame.payload)
            fragmentedOpCode = .text
          }
        }
      }
      
      func handleBinaryPayload(_ frame: WebSocketSession.Frame) throws {
        if let handleBinary = binary {
          if frame.fin {
            if payload.count > 0 {
              throw WebSocketSession.WsError.protocolError("Continuing fragmented frame cannot have an operation code.")
            }
            handleBinary(session, frame.payload)
          } else {
            try ensureMessageFits(adding: frame)
            payload.append(contentsOf: frame.payload)
            fragmentedOpCode = .binary
          }
        }
      }
      
      func handleOperationCode(_ frame: WebSocketSession.Frame) throws {
        switch frame.opcode {
          case .continue:
            // There is no message to continue, failed immediatelly.
            if fragmentedOpCode == .close {
              socket.close()
            }
            frame.opcode = fragmentedOpCode
            if frame.fin {
              try ensureMessageFits(adding: frame)
              payload.append(contentsOf: frame.payload)
              frame.payload = payload
              // Clean the buffer.
              payload = []
              // Reset the OpCode.
              fragmentedOpCode = WebSocketSession.OpCode.close
            }
            try handleOperationCode(frame)
          case .text:
            try handleTextPayload(frame)
          case .binary:
            try handleBinaryPayload(frame)
          case .close:
            // https://tools.ietf.org/html/rfc6455#section-5.5.1: no payload, or a status code (two
            // bytes) with an optional reason.
            if frame.payload.count == 1 {
              throw WebSocketSession.WsError.protocolError("A close frame cannot have a payload of one byte.")
            }
            if frame.payload.count >= 2 {
              let code = UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
              guard WebSocketSession.isValidCloseCode(code) else {
                throw WebSocketSession.WsError.protocolError("Invalid close code \(code).")
              }
              closeCode = code
            }
            throw WebSocketSession.Control.close
          case .ping:
            if frame.payload.count > 125 {
              throw WebSocketSession.WsError.protocolError("Payload gretter than 125 octets.")
            } else {
              session.writeFrame(ArraySlice(frame.payload), .pong)
            }
          case .pong:
            if let handlePong = pong {
              handlePong(session, frame.payload)
            }
        }
      }
      
      func read() throws {
        while true {
          let frame = try session.readFrame()
          try handleOperationCode(frame)
        }
      }
      
      connected?(session)
      
      var failed = false
      do {
        try read()
      } catch let error {
        // The close frame tells the client why the connection ends (RFC 6455 7.4).
        var code: UInt16? = nil
        switch error {
          case WebSocketSession.Control.close:
            // Normal close: answer with the status code of the client.
            code = closeCode
          case WebSocketSession.WsError.unknownOpCode:
            print("Unknown Op Code: \(error)")
            code = WebSocketSession.CloseCode.protocolError
          case WebSocketSession.WsError.unMaskedFrame:
            print("Unmasked frame: \(error)")
            code = WebSocketSession.CloseCode.protocolError
          case WebSocketSession.WsError.invalidUTF8:
            print("Invalid UTF8 character: \(error)")
            code = WebSocketSession.CloseCode.invalidPayload
          case WebSocketSession.WsError.messageTooBig:
            print("Message too big: \(error)")
            code = WebSocketSession.CloseCode.messageTooBig
          case WebSocketSession.WsError.protocolError:
            print("Protocol error: \(error)")
            code = WebSocketSession.CloseCode.protocolError
          default:
            print("Unkown error \(error)")
        }
        // If an error occurs, send the close handshake.
        if let code {
          session.writeCloseFrame(code: code)
        } else {
          session.writeCloseFrame()
        }
        if case WebSocketSession.Control.close = error {} else {
          failed = true
        }
      }
      
      disconnected?(session)
      if failed {
        // The client may still be sending (e.g. the rest of a refused frame): let it read our close
        // frame instead of resetting the connection.
        socket.closeAfterDraining()
      }
    }
    let secWebSocketAccept = String.toBase64((secWebSocketKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").sha1())
    let headers = [
      "Upgrade": "WebSocket",
      "Connection": "Upgrade",
      "Sec-WebSocket-Accept": secWebSocketAccept
    ]
    return NanoHTTPResponse.switchProtocols(headers, protocolSessionClosure)
  }
}

/// One WebSocket connection. Sessions are what the closures of `websocket(...)` receive; keep them
/// (for example in a set, to broadcast) and drop them in `disconnected`.
///
/// All `write...` methods may be called from any thread at any time: concurrent calls are
/// serialized, so frames never interleave. After the connection has ended, writing is a harmless
/// no-op that logs an error.
public class WebSocketSession: Hashable, Equatable {
  
  public enum WsError: Error {
    case unknownOpCode(String)
    case unMaskedFrame(String)
    case protocolError(String)
    case invalidUTF8(String)
    /// A frame or a message is larger than the limit (close code 1009).
    case messageTooBig(String)
  }
  
  public enum OpCode: UInt8 {
    case `continue` = 0x00
    case close = 0x08
    case ping = 0x09
    case pong = 0x0A
    case text = 0x01
    case binary = 0x02
  }
  
  public enum Control: Error {
    case close
  }
  
  public class Frame {
    public var opcode = OpCode.close
    public var fin = false
    public var rsv1: UInt8 = 0
    public var rsv2: UInt8 = 0
    public var rsv3: UInt8 = 0
    public var payload = [UInt8]()
  }
  
  public let socket: NanoSocket
  
  /// Serializes writing frames: a frame consists of several parts, and the writes of two threads
  /// must not be mixed.
  private let writeLock = NSLock()
  
  /// The largest frame payload `readFrame()` accepts, in bytes. A frame that announces more is
  /// rejected with `WsError.protocolError` before any of its payload is read.
  public var maxPayloadSize = 16 * 1024 * 1024
  
  public init(_ socket: NanoSocket) {
    self.socket = socket
  }
  
  deinit {
    writeCloseFrame()
    socket.close()
  }
  
  public func writeText(_ text: String) {
    self.writeFrame(ArraySlice(text.utf8), OpCode.text)
  }
  
  public func writeBinary(_ binary: [UInt8]) {
    self.writeBinary(ArraySlice(binary))
  }
  
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
      if data.count <= WebSocketSession.coalescingLimit {
        // Small frames go out in a single write (and so in a single TCP segment, where possible).
        try self.socket.writeUInt8(header + data)
      } else {
        try self.socket.writeUInt8(header)
        try self.socket.writeUInt8(data)
      }
    } catch {
      print(error)
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
    public static let normal: UInt16 = 1000
    public static let goingAway: UInt16 = 1001
    public static let protocolError: UInt16 = 1002
    public static let unsupportedData: UInt16 = 1003
    public static let invalidPayload: UInt16 = 1007
    public static let policyViolation: UInt16 = 1008
    public static let messageTooBig: UInt16 = 1009
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
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(socket)
  }
  
  public static func == (wss1: WebSocketSession, wss2: WebSocketSession) -> Bool {
      return wss1.socket == wss2.socket
  }
}
