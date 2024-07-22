//
//  WebSocketTests.swift
//  NanoHTTPTests
//
//  Created by Matthias Zenger on 22/07/2024.
//  Based on `SwifterTestsWebSocketSession` of framework `Swifter` by Damian Kołakowski.
//
//  Copyright © 2016 Damian Kołakowski. All rights reserved.
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


import XCTest
@testable import NanoHTTP

class SwifterTestsWebSocketSession: XCTestCase {
  
  class TestSocket: NanoSocket {
    var content = [UInt8]()
    var offset = 0
    
    init(_ content: [UInt8]) {
      super.init(socketFileDescriptor: -1)
      self.content.append(contentsOf: content)
    }
    
    override func read() throws -> UInt8 {
      if offset < content.count {
        let value = self.content[offset]
        offset += 1
        return value
      }
      throw NanoSocketError.recvFailed("")
    }
  }
  
  func testParser() {
    
    do {
      let session = WebSocketSession(TestSocket([0]))
      _ = try session.readFrame()
      XCTAssert(false, "Parser should throw an error if socket has not enough data for a frame.")
    } catch {
      XCTAssert(true, "Parser should throw an error if socket has not enough data for a frame.")
    }
    
    do {
      let session = WebSocketSession(TestSocket([0b0000_0001, 0b0000_0000, 0, 0, 0, 0]))
      _ = try session.readFrame()
      XCTAssert(false, "Parser should not accept unmasked frames.")
    } catch WebSocketSession.WsError.unMaskedFrame {
      XCTAssert(true, "Parse should throw UnMaskedFrame error for unmasked message.")
    } catch {
      XCTAssert(false, "Parse should throw UnMaskedFrame error for unmasked message.")
    }
    
    do {
      let session = WebSocketSession(TestSocket([0b1000_0001, 0b1000_0000, 0, 0, 0, 0]))
      let frame = try session.readFrame()
      XCTAssert(frame.fin, "Parser should detect fin flag set.")
    } catch {
      XCTAssert(false, "Parser should not throw an error for a frame with fin flag set (\(error)")
    }
    
    do {
      let session = WebSocketSession(TestSocket([0b0000_0000, 0b1000_0000, 0, 0, 0, 0]))
      let frame = try session.readFrame()
      XCTAssertEqual(frame.opcode, WebSocketSession.OpCode.continue, "Parser should accept Continue opcode.")
    } catch {
      XCTAssertTrue(true, "Parser should accept Continue opcode without any errors.")
    }
    
    do {
      let session = WebSocketSession(TestSocket([0b0000_0001, 0b1000_0000, 0, 0, 0, 0]))
      let frame = try session.readFrame()
      XCTAssertEqual(frame.opcode, WebSocketSession.OpCode.text, "Parser should accept Text opcode.")
    } catch {
      XCTAssert(false, "Parser should accept Text opcode without any errors.")
    }
    
    do {
      let session = WebSocketSession(TestSocket([0b0000_0010, 0b1000_0000, 0, 0, 0, 0]))
      let frame = try session.readFrame()
      XCTAssertEqual(frame.opcode, WebSocketSession.OpCode.binary, "Parser should accept Binary opcode.")
    } catch {
      XCTAssert(false, "Parser should accept Binary opcode without any errors.")
    }
    
    do {
      let session = WebSocketSession(TestSocket([0b1000_1000, 0b1000_0000, 0, 0, 0, 0]))
      let frame = try session.readFrame()
      XCTAssertEqual(frame.opcode, WebSocketSession.OpCode.close, "Parser should accept Close opcode.")
    } catch let error {
      XCTAssert(false, "Parser should accept Close opcode without any errors. \(error)")
    }
    
    do {
      let session = WebSocketSession(TestSocket([0b1000_1001, 0b1000_0000, 0, 0, 0, 0]))
      let frame = try session.readFrame()
      XCTAssertEqual(frame.opcode, WebSocketSession.OpCode.ping, "Parser should accept Ping opcode.")
    } catch let error {
      XCTAssert(false, "Parser should accept Ping opcode without any errors. \(error)")
    }
    
    do {
      let session = WebSocketSession(TestSocket([0b1000_1010, 0b1000_0000, 0, 0, 0, 0]))
      let frame = try session.readFrame()
      XCTAssertEqual(frame.opcode, WebSocketSession.OpCode.pong, "Parser should accept Pong opcode.")
    } catch let error {
      XCTAssert(false, "Parser should accept Pong opcode without any errors. \(error)")
    }
    
    for opcode in [3, 4, 5, 6, 7, 11, 12, 13, 14, 15] {
      do {
        let session = WebSocketSession(TestSocket([UInt8(opcode), 0b1000_0000, 0, 0, 0, 0]))
        _ = try session.readFrame()
        XCTAssert(false, "Parse should throw an error for unknown opcode: \(opcode)")
      } catch WebSocketSession.WsError.unknownOpCode(_) {
        XCTAssert(true, "Parse should throw UnknownOpCode error for unknown opcode.")
      } catch {
        XCTAssert(false, "Parse should throw UnknownOpCode error for unknown opcode (was \(error)).")
      }
    }
  }
}
