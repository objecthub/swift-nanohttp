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

public func websocket(text: ((WebSocketSession, String) -> Void)? = nil,
                      binary: ((WebSocketSession, [UInt8]) -> Void)? = nil,
                      pong: ((WebSocketSession, [UInt8]) -> Void)? = nil,
                      connected: ((WebSocketSession) -> Void)? = nil,
                      disconnected: ((WebSocketSession) -> Void)? = nil) -> NanoHTTPRequestHandler {
  return { request in
    guard request.hasTokenForHeader("upgrade", token: "websocket") else {
      return .badRequest(.init(body: .text("Invalid value of 'Upgrade' header: \(request.headers["upgrade"] ?? "unknown")")))
    }
    guard request.hasTokenForHeader("connection", token: "upgrade") else {
      return .badRequest(.init(body: .text("Invalid value of 'Connection' header: \(request.headers["connection"] ?? "unknown")")))
    }
    guard let secWebSocketKey = request.headers["sec-websocket-key"] else {
      return .badRequest(.init(body: .text("Invalid value of 'Sec-Websocket-Key' header: \(request.headers["sec-websocket-key"] ?? "unknown")")))
    }
    let protocolSessionClosure: ((NanoSocket) -> Void) = { socket in
      let session = WebSocketSession(socket)
      var fragmentedOpCode = WebSocketSession.OpCode.close
      var payload = [UInt8]() // Used for fragmented frames.
      
      func handleTextPayload(_ frame: WebSocketSession.Frame) throws {
        if let handleText = text {
          if frame.fin {
            if payload.count > 0 {
              throw WebSocketSession.WsError.protocolError("Continuing fragmented frame cannot have an operation code.")
            }
            var textFramePayload = frame.payload.map { Int8(bitPattern: $0) }
            textFramePayload.append(0)
            if let text = String(validatingUTF8: textFramePayload) {
              handleText(session, text)
            } else {
              throw WebSocketSession.WsError.invalidUTF8("")
            }
          } else {
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
      
      do {
        try read()
      } catch let error {
        switch error {
          case WebSocketSession.Control.close:
            // Normal close
            break
          case WebSocketSession.WsError.unknownOpCode:
            print("Unknown Op Code: \(error)")
          case WebSocketSession.WsError.unMaskedFrame:
            print("Unmasked frame: \(error)")
          case WebSocketSession.WsError.invalidUTF8:
            print("Invalid UTF8 character: \(error)")
          case WebSocketSession.WsError.protocolError:
            print("Protocol error: \(error)")
          default:
            print("Unkown error \(error)")
        }
        // If an error occurs, send the close handshake.
        session.writeCloseFrame()
      }
      
      disconnected?(session)
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

public class WebSocketSession: Hashable, Equatable {
  
  public enum WsError: Error {
    case unknownOpCode(String)
    case unMaskedFrame(String)
    case protocolError(String)
    case invalidUTF8(String)
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
  
  public func writeFrame(_ data: ArraySlice<UInt8>, _ op: OpCode, _ fin: Bool = true) {
    let finAndOpCode = UInt8(fin ? 0x80 : 0x00) | op.rawValue
    let maskAndLngth = encodeLengthAndMaskFlag(UInt64(data.count), false)
    do {
      try self.socket.writeUInt8([finAndOpCode])
      try self.socket.writeUInt8(maskAndLngth)
      try self.socket.writeUInt8(data)
    } catch {
      print(error)
    }
  }
  
  public func writeCloseFrame() {
    writeFrame(ArraySlice("".utf8), .close)
  }
  
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
      let b0 = UInt64(try socket.read()) << 8
      let b1 = UInt64(try socket.read())
      len = UInt64(littleEndian: b0 | b1)
    } else if len == 0x7F {
      let b0 = UInt64(try socket.read()) << 54
      let b1 = UInt64(try socket.read()) << 48
      let b2 = UInt64(try socket.read()) << 40
      let b3 = UInt64(try socket.read()) << 32
      let b4 = UInt64(try socket.read()) << 24
      let b5 = UInt64(try socket.read()) << 16
      let b6 = UInt64(try socket.read()) << 8
      let b7 = UInt64(try socket.read())
      len = UInt64(littleEndian: b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7)
    }
    
    let mask = [try socket.read(), try socket.read(), try socket.read(), try socket.read()]
    // Read payload all at once, then apply mask (calling `socket.read` byte-by-byte is super slow).
    frm.payload = try socket.read(length: Int(len))
    for index in 0..<len {
      frm.payload[Int(index)] ^= mask[Int(index % 4)]
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
