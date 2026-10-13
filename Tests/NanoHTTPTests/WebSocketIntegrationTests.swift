//
//  WebSocketIntegrationTests.swift
//  NanoHTTPTests
//
//  End-to-end WebSocket tests: a real server, a raw-socket client that performs the RFC 6455
//  handshake and speaks masked frames. Covers findings W1 and W2 of the assessment plan; the
//  original WebSocketTests.swift only parses frame headers.
//

import XCTest
@testable import NanoHTTP

// MARK: - Client side of the protocol

private enum WS {
  static let key = "dGhlIHNhbXBsZSBub25jZQ=="                 // example from RFC 6455 §1.3
  static let accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="           // its required accept value

  enum Opcode: UInt8 {
    case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
  }

  enum LengthEncoding {
    case minimal, sevenBit, sixteenBit, sixtyFourBit
  }

  /// A client-to-server frame (always masked, as required).
  static func frame(_ opcode: Opcode,
                    _ payload: [UInt8],
                    fin: Bool = true,
                    masked: Bool = true,
                    encoding: LengthEncoding = .minimal) -> [UInt8] {
    let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    let count = payload.count
    var frame: [UInt8] = [(fin ? 0x80 : 0x00) | opcode.rawValue]
    let maskBit: UInt8 = masked ? 0x80 : 0
    var kind = encoding
    if kind == .minimal {
      kind = count < 126 ? .sevenBit : (count <= 0xFFFF ? .sixteenBit : .sixtyFourBit)
    }
    switch kind {
      case .sevenBit, .minimal:
        frame.append(maskBit | UInt8(count))
      case .sixteenBit:
        frame += [maskBit | 126, UInt8(count >> 8), UInt8(count & 0xFF)]
      case .sixtyFourBit:
        frame.append(maskBit | 127)
        for shift in stride(from: 56, through: 0, by: -8) {
          frame.append(UInt8((UInt64(count) >> UInt64(shift)) & 0xFF))
        }
    }
    if masked {
      frame += mask
      frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    } else {
      frame += payload
    }
    return frame
  }

  static func text(_ string: String, fin: Bool = true) -> [UInt8] {
    return frame(.text, Array(string.utf8), fin: fin)
  }

  /// Reads one server-to-client frame (never masked).
  static func readFrame(_ client: RawClient) -> (opcode: UInt8, fin: Bool, payload: [UInt8])? {
    guard let head = client.readBytes(2) else {
      return nil
    }
    var length = Int(head[1] & 0x7F)
    if length == 126 {
      guard let extra = client.readBytes(2) else { return nil }
      length = Int(extra[0]) << 8 | Int(extra[1])
    } else if length == 127 {
      guard let extra = client.readBytes(8) else { return nil }
      length = extra.reduce(0) { $0 << 8 | Int($1) }
    }
    guard let payload = client.readBytes(length) else {
      return nil
    }
    return (head[0] & 0x0F, head[0] & 0x80 != 0, payload)
  }

  static func handshakeRequest(path: String = "/ws", key: String? = WS.key) -> [UInt8] {
    var headers = ["Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Version: 13"]
    if let key {
      headers.append("Sec-WebSocket-Key: \(key)")
    }
    return RawClient.requestText("GET", path, headers: headers)
  }

  /// Opens a connection and performs the handshake; the returned client speaks frames.
  static func connect(port: Int, file: StaticString = #filePath, line: UInt = #line) throws -> RawClient {
    let client = try RawClient(port: port)
    client.send(handshakeRequest())
    let response = client.readResponse()
    XCTAssertEqual(response?.status, 101, "handshake failed", file: file, line: line)
    return client
  }
}

// MARK: - Tests

final class WebSocketIntegrationTests: XCTestCase {

  private func serve(_ body: (Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server["/ws"] = websocket(
        text: { session, text in session.writeText(text) },
        binary: { session, bytes in session.writeBinary(bytes) })
    }) { _, port in
      try body(port)
    }
  }

  func testHandshakeReturnsTheRFCAcceptKey() throws {
    try serve { port in
      let client = try RawClient(port: port)
      client.send(WS.handshakeRequest())
      let response = client.readResponse()
      XCTAssertEqual(response?.status, 101)
      XCTAssertEqual(response?.header("sec-websocket-accept"), WS.accept)
      XCTAssertEqual(response?.header("upgrade")?.lowercased(), "websocket")
      XCTAssertEqual(response?.header("connection")?.lowercased(), "upgrade")
    }
  }

  func testHandshakeWithoutKeyIsRejected() throws {
    try serve { port in
      let client = try RawClient(port: port)
      client.send(WS.handshakeRequest(key: nil))
      XCTAssertEqual(client.readResponse()?.status, 400)
    }
  }

  func testPlainRequestToWebSocketRouteIsRejected() throws {
    try serve { port in
      XCTAssertEqual(try RawClient.get("/ws", port: port).status, 400)
    }
  }

  func testEchoesShortText() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.text("hello"))
      let frame = WS.readFrame(client)
      XCTAssertEqual(frame?.opcode, WS.Opcode.text.rawValue)
      XCTAssertEqual(String(decoding: frame?.payload ?? [], as: UTF8.self), "hello")
    }
  }

  func testEchoesMultibyteText() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.text("héllo €😀"))
      XCTAssertEqual(String(decoding: WS.readFrame(client)?.payload ?? [], as: UTF8.self), "héllo €😀")
    }
  }

  func testEchoesBinary() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      let payload: [UInt8] = [0, 1, 2, 255, 254, 13, 10]
      client.send(WS.frame(.binary, payload))
      let frame = WS.readFrame(client)
      XCTAssertEqual(frame?.opcode, WS.Opcode.binary.rawValue)
      XCTAssertEqual(frame?.payload, payload)
    }
  }

  func testSixteenBitLengthFrame() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      let text = String(repeating: "x", count: 300)
      client.send(WS.text(text))
      XCTAssertEqual(String(decoding: WS.readFrame(client)?.payload ?? [], as: UTF8.self), text)
    }
  }

  func testSixtyFourBitLengthEncodingFrame() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      let payload = [UInt8](repeating: 0x61, count: 70_000)
      client.send(WS.frame(.binary, payload)) // > 65535 bytes: 8-byte length is mandatory
      XCTAssertEqual(WS.readFrame(client)?.payload.count, 70_000)
    }
  }

  func testFragmentedTextIsReassembled() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.text, Array("Hel".utf8), fin: false))
      client.send(WS.frame(.continuation, Array("l".utf8), fin: false))
      client.send(WS.frame(.continuation, Array("o".utf8), fin: true))
      XCTAssertEqual(String(decoding: WS.readFrame(client)?.payload ?? [], as: UTF8.self), "Hello")
    }
  }

  func testPingIsAnsweredWithPongCarryingThePayload() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.ping, Array("beat".utf8)))
      let frame = WS.readFrame(client)
      XCTAssertEqual(frame?.opcode, WS.Opcode.pong.rawValue)
      XCTAssertEqual(String(decoding: frame?.payload ?? [], as: UTF8.self), "beat")
    }
  }

  func testCloseFrameIsAnsweredAndTheConnectionEnds() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.close, []))
      XCTAssertEqual(WS.readFrame(client)?.opcode, WS.Opcode.close.rawValue)
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testUnmaskedClientFrameClosesTheConnection() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.text, Array("hi".utf8), masked: false))
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testServerSurvivesAClientThatVanishesMidFrame() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(Array(WS.text("truncated frame").prefix(6)))
      client.close()
      XCTAssertEqual(try RawClient.get("/ws", port: port).status, 400) // still serving
    }
  }

  func testConnectedAndDisconnectedCallbacksFire() throws {
    let connected = expectation(description: "connected")
    let disconnected = expectation(description: "disconnected")
    try withTestServer(configure: { server in
      server["/ws"] = websocket(connected: { _ in connected.fulfill() },
                                disconnected: { _ in disconnected.fulfill() })
    }) { _, port in
      let client = try WS.connect(port: port)
      wait(for: [connected], timeout: 3)
      client.close()
      wait(for: [disconnected], timeout: 3)
    }
  }

  // MARK: W2

  func testTextContainingNulCharacterSurvives() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.text("a\u{0}b"))
      let echoed = String(decoding: WS.readFrame(client)?.payload ?? [], as: UTF8.self)
      expectKnownIssue("W2", "String(validatingUTF8:) stops at the NUL byte, so the text is cut to 'a'") {
        XCTAssertEqual(echoed, "a\u{0}b")
      }
    }
  }

  func testInvalidUTF8TextClosesTheConnection() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.text, [0xC3, 0x28])) // invalid UTF-8
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }
}

// MARK: - S3: message size limit (fixed)

final class WebSocketMessageLimitTests: XCTestCase {

  private func serve(maxMessageSize: Int? = nil, _ body: (Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      let echoText: (WebSocketSession, String) -> Void = { session, text in session.writeText(text) }
      let echoBinary: (WebSocketSession, [UInt8]) -> Void = { session, bytes in session.writeBinary(bytes) }
      server["/ws"] = maxMessageSize.map { websocket(text: echoText, binary: echoBinary, maxMessageSize: $0) }
                                    ?? websocket(text: echoText, binary: echoBinary)
    }) { _, port in
      try body(port)
    }
  }

  private func text(_ count: Int) -> String {
    return String(repeating: "x", count: count)
  }

  func testMessageAtTheLimitIsEchoed() throws {
    try serve(maxMessageSize: 1000) { port in
      let client = try WS.connect(port: port)
      client.send(WS.text(text(1000)))
      XCTAssertEqual(WS.readFrame(client)?.payload.count, 1000)
    }
  }

  func testSingleFrameAboveTheLimitEndsTheConnection() throws {
    try serve(maxMessageSize: 1000) { port in
      let client = try WS.connect(port: port)
      client.send(WS.text(text(1001)))
      XCTAssertEqual(WS.readFrame(client)?.opcode, WS.Opcode.close.rawValue)
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testFragmentsWithinTheLimitAreAssembled() throws {
    try serve(maxMessageSize: 1000) { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.text, Array(text(500).utf8), fin: false))
      client.send(WS.frame(.continuation, Array(text(500).utf8), fin: true))
      XCTAssertEqual(WS.readFrame(client)?.payload.count, 1000)
    }
  }

  func testFragmentsAddingUpAboveTheLimitEndTheConnection() throws {
    try serve(maxMessageSize: 1000) { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.text, Array(text(600).utf8), fin: false))
      client.send(WS.frame(.continuation, Array(text(300).utf8), fin: false))
      client.send(WS.frame(.continuation, Array(text(200).utf8), fin: false)) // 1100 bytes in total
      XCTAssertEqual(WS.readFrame(client)?.opcode, WS.Opcode.close.rawValue)
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testTheFinalFragmentIsCountedToo() throws {
    try serve(maxMessageSize: 1000) { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.binary, [UInt8](repeating: 1, count: 900), fin: false))
      client.send(WS.frame(.continuation, [UInt8](repeating: 1, count: 101), fin: true))
      XCTAssertEqual(WS.readFrame(client)?.opcode, WS.Opcode.close.rawValue)
    }
  }

  func testEndlessFragmentsCannotGrowWithoutBound() throws {
    try serve(maxMessageSize: 10_000) { port in
      let client = try WS.connect(port: port)
      for _ in 0..<50 { // 50 x 1000 bytes without a final fragment
        client.send(WS.frame(.continuation, [UInt8](repeating: 1, count: 1000), fin: false))
      }
      // A continuation without a message start is a protocol violation anyway; start properly:
      let second = try WS.connect(port: port)
      second.send(WS.frame(.text, Array(text(1000).utf8), fin: false))
      for _ in 0..<50 {
        second.send(WS.frame(.continuation, [UInt8](repeating: 0x78, count: 1000), fin: false))
      }
      XCTAssertTrue(second.waitForClose(timeout: 3))
    }
  }

  func testOversizedControlFrameEndsTheConnection() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      client.send(WS.frame(.ping, [UInt8](repeating: 1, count: 126)))
      XCTAssertEqual(WS.readFrame(client)?.opcode, WS.Opcode.close.rawValue)
    }
  }

  func testServerKeepsServingAfterARefusedMessage() throws {
    try serve(maxMessageSize: 100) { port in
      let refused = try WS.connect(port: port)
      refused.send(WS.text(text(101)))
      XCTAssertTrue(refused.waitForClose(timeout: 2))
      let client = try WS.connect(port: port)
      client.send(WS.text("still alive"))
      XCTAssertEqual(String(decoding: WS.readFrame(client)?.payload ?? [], as: UTF8.self), "still alive")
    }
  }

  func testDefaultLimitAllowsMegabyteMessages() throws {
    try serve { port in
      let client = try WS.connect(port: port)
      let payload = [UInt8](repeating: 0x42, count: 1_000_000)
      client.send(WS.frame(.binary, payload))
      XCTAssertEqual(WS.readFrame(client)?.payload.count, 1_000_000)
    }
  }
}

// MARK: - W1: concurrent writers

final class WebSocketWriteTests: XCTestCase {

  /// Several threads send frames through ONE session (a broadcast loop plus a ping reply is the
  /// realistic case). `writeFrame` issues three separate `write`s per frame without a lock, so
  /// frames of different threads can interleave and corrupt the stream. The failure is
  /// timing-dependent, hence `strict: false`.
  func testConcurrentWritersDoNotInterleaveFrames() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    NanoSocket.setNoSigPipe(fds[0])
    NanoSocket.setNoSigPipe(fds[1])
    var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let writers = 4
    let framesPerWriter = 300
    let payloadSize = 3000
    let letters = Array("ABCD".utf8)
    let session = WebSocketSession(NanoSocket(socketFileDescriptor: fds[0]))

    let lock = NSLock()
    var corrupted = false
    var writersDone = false

    let reader = DispatchGroup()
    reader.enter()
    DispatchQueue.global().async {
      defer { reader.leave() }
      func readExactly(_ count: Int) -> [UInt8]? {
        var result = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
          let n = result.withUnsafeMutableBytes { read(fds[1], $0.baseAddress! + offset, count - offset) }
          if n < 0 && errno == EAGAIN {
            lock.lock(); let done = writersDone; lock.unlock()
            if done { return nil }
            continue
          }
          if n <= 0 { return nil }
          offset += n
        }
        return result
      }
      var intact = true
      for _ in 0..<(writers * framesPerWriter) {
        guard let head = readExactly(2), head[0] == 0x81, head[1] == 126,
              let length = readExactly(2), Int(length[0]) << 8 | Int(length[1]) == payloadSize,
              let payload = readExactly(payloadSize),
              letters.contains(payload[0]), payload.allSatisfy({ $0 == payload[0] }) else {
          intact = false
          break
        }
      }
      if !intact {
        lock.lock(); corrupted = true; lock.unlock()
        // Keep draining so that blocked writers can finish.
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
          let n = scratch.withUnsafeMutableBytes { read(fds[1], $0.baseAddress, $0.count) }
          if n < 0 && errno == EAGAIN {
            lock.lock(); let done = writersDone; lock.unlock()
            if done { break }
          } else if n <= 0 {
            break
          }
        }
      }
    }
    DispatchQueue.concurrentPerform(iterations: writers) { writer in
      let text = String(repeating: String(UnicodeScalar(letters[writer])), count: payloadSize)
      for _ in 0..<framesPerWriter {
        session.writeText(text)
      }
    }
    lock.lock(); writersDone = true; lock.unlock()
    XCTAssertEqual(reader.wait(timeout: .now() + 30), .success, "reader did not finish")
    lock.lock(); let wasCorrupted = corrupted; lock.unlock()
    expectKnownIssue("W1", "frames from concurrent writers interleave (no write lock)", strict: false) {
      XCTAssertFalse(wasCorrupted, "the byte stream contained a corrupted frame")
    }
    close(fds[1])
  }
}
