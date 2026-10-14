//
//  ResponseSerializerTests.swift
//  NanoHTTPTests
//
//  2.0: the head of a response is written by a function of its arguments (`NanoHTTPResponseSerializer`), so that
//  what goes over the wire can be tested without a socket; a body that is in memory is written with its
//  head in one piece; every response has a `Date`.
//

import XCTest
@testable import NanoHTTP

private func text(_ bytes: [UInt8]) -> String {
  return String(decoding: bytes, as: UTF8.self)
}

private func lines(_ head: [UInt8]) -> [String] {
  return text(head).components(separatedBy: "\r\n")
}

final class ResponseSerializerTests: XCTestCase {

  private func head(_ response: NanoHTTPResponse,
                    _ framing: NanoHTTPResponseSerializer.Framing,
                    connection: NanoHTTPResponseSerializer.Connection = .unspecified,
                    date: String? = nil) -> [String] {
    return lines(NanoHTTPResponseSerializer.head(response, framing: framing, connection: connection, date: date))
  }

  func testTheStatusLineComesFirstAndTheHeadEndsWithAnEmptyLine() {
    let bytes = NanoHTTPResponseSerializer.head(.ok(.text("hi")), framing: .length(2))
    let all = lines(bytes)
    XCTAssertEqual(all.first, "HTTP/1.1 200 OK")
    XCTAssertEqual(Array(all.suffix(2)), ["", ""], "the last header line and the empty line end with CR LF")
    XCTAssertTrue(text(bytes).hasSuffix("\r\n\r\n"))
  }

  func testTheHeadHasTheContentLengthAndTheContentTypeOfTheBody() {
    let all = head(.ok(.text("héllo")), .length(6))
    XCTAssertTrue(all.contains("Content-Length: 6"))
    XCTAssertTrue(all.contains("Content-Type: text/plain; charset=utf-8"))
    XCTAssertEqual(all.filter { $0.hasPrefix("Content-Length") }.count, 1)
  }

  func testUnknownStatusCodesHaveNoReasonPhrase() {
    XCTAssertEqual(head(NanoHTTPResponse(statusCode: 799), .none).first, "HTTP/1.1 799 ")
    XCTAssertEqual(head(NanoHTTPResponse(statusCode: 404), .none).first, "HTTP/1.1 404 Not Found")
  }

  func testTheConnectionHeader() {
    XCTAssertFalse(head(.ok(.text("x")), .length(1)).contains { $0.hasPrefix("Connection") })
    XCTAssertTrue(head(.ok(.text("x")), .length(1), connection: .close).contains("Connection: close"))
    XCTAssertTrue(head(.ok(.text("x")), .length(1), connection: .keepAlive).contains("Connection: keep-alive"))
  }

  func testTheFramingReplacesWhatTheHandlerSaid() {
    var response = NanoHTTPResponse.ok(.text("abc"))
    response.headers["content-length"] = "999"
    response.headers["Transfer-Encoding"] = "chunked"
    response.headers["CONNECTION"] = "keep-alive"
    let all = head(response, .length(3), connection: .close)
    XCTAssertEqual(all.filter { $0.lowercased().hasPrefix("content-length") }, ["Content-Length: 3"])
    XCTAssertFalse(all.contains { $0.lowercased().hasPrefix("transfer-encoding") })
    XCTAssertEqual(all.filter { $0.lowercased().hasPrefix("connection") }, ["Connection: close"])
  }

  func testAChunkedBodyHasNoLength() {
    var response = NanoHTTPResponse.ok(.text("abc"))
    response.headers["Content-Length"] = "3"
    let all = head(response, .chunked)
    XCTAssertTrue(all.contains("Transfer-Encoding: chunked"))
    XCTAssertFalse(all.contains { $0.lowercased().hasPrefix("content-length") })
  }

  func testWhenTheBodyEndsWithTheConnectionTheHeadersOfTheHandlerStay() {
    var response = NanoHTTPResponse.custom(200) { _ in }
    response.headers["Content-Length"] = "10"
    XCTAssertTrue(head(response, .untilClose).contains("Content-Length: 10"))
  }

  func testTheHeadersOfAnUpgradeStay() {
    let response = NanoHTTPResponse.switchProtocols(["Upgrade": "websocket", "Connection": "Upgrade"], { _ in })
    let all = head(response, .none)
    XCTAssertEqual(all.first, "HTTP/1.1 101 Switching Protocols")
    XCTAssertTrue(all.contains("Upgrade: websocket"))
    XCTAssertTrue(all.contains("Connection: Upgrade"))
    XCTAssertFalse(all.contains { $0.hasPrefix("Content-Length") })
  }

  func testTheDate() {
    let all = head(.ok(.text("x")), .length(1), date: "Tue, 13 Oct 2026 21:00:00 GMT")
    XCTAssertEqual(all.filter { $0.hasPrefix("Date") }, ["Date: Tue, 13 Oct 2026 21:00:00 GMT"])
    var response = NanoHTTPResponse.ok(.text("x"))
    response.headers["date"] = "yesterday"
    XCTAssertEqual(head(response, .length(1), date: "Tue, 13 Oct 2026 21:00:00 GMT").filter { $0.lowercased().hasPrefix("date") },
                   ["Date: Tue, 13 Oct 2026 21:00:00 GMT"])
    XCTAssertEqual(head(response, .length(1)).filter { $0.lowercased().hasPrefix("date") }, ["date: yesterday"],
                   "without a date of the server, the one of the handler stays")
  }

  func testHeaderValuesCannotInjectHeadersAndBadNamesAreDropped() {
    var response = NanoHTTPResponse.ok(.text("x"))
    response.headers["Location"] = "/a\r\nSet-Cookie: stolen=1\r\n\r\n<script>"
    response.headers["Bad Name"] = "x"
    response.headers["Also:Bad"] = "x"
    response.headers["X-Nul"] = "a\0b"
    var dropped = [String]()
    let bytes = NanoHTTPResponseSerializer.head(response, framing: .length(1), dropped: { dropped.append($0) })
    let all = lines(bytes)
    XCTAssertTrue(all.contains("Location: /a  Set-Cookie: stolen=1    <script>"), all.joined(separator: "|"))
    XCTAssertFalse(all.contains { $0.hasPrefix("Set-Cookie") })
    XCTAssertTrue(all.contains("X-Nul: a b"))
    XCTAssertEqual(dropped.sorted(), ["Also:Bad", "Bad Name"])
    XCTAssertEqual(text(bytes).components(separatedBy: "\r\n\r\n").count, 2, "the head has one empty line, at its end")
  }
}

final class NanoHTTPDateTests: XCTestCase {

  func testTheFormatOfHTTP() {
    XCTAssertEqual(NanoHTTPDate.string(for: Date(timeIntervalSince1970: 0)), "Thu, 01 Jan 1970 00:00:00 GMT")
    XCTAssertEqual(NanoHTTPDate.string(for: Date(timeIntervalSince1970: 1_000_000_000)), "Sun, 09 Sep 2001 01:46:40 GMT")
    XCTAssertEqual(NanoHTTPDate.string(for: Date(timeIntervalSince1970: 1_791_924_000)), "Tue, 13 Oct 2026 20:40:00 GMT")
    XCTAssertEqual(NanoHTTPDate.string(for: Date(timeIntervalSince1970: 951_782_399)), "Mon, 28 Feb 2000 23:59:59 GMT")
    XCTAssertEqual(NanoHTTPDate.string(for: Date(timeIntervalSince1970: 951_782_400)), "Tue, 29 Feb 2000 00:00:00 GMT")
  }

  func testTheTextOfASecondIsTheSameUntilTheNextSecondBegins() {
    let first = NanoHTTPDate.string(for: Date(timeIntervalSince1970: 1_000_000_000.1))
    XCTAssertEqual(NanoHTTPDate.string(for: Date(timeIntervalSince1970: 1_000_000_000.9)), first)
    XCTAssertNotEqual(NanoHTTPDate.string(for: Date(timeIntervalSince1970: 1_000_000_001.0)), first)
    XCTAssertEqual(NanoHTTPDate.string(for: Date(timeIntervalSince1970: 1_000_000_000.5)), first, "and going back works")
  }

  func testTheCurrentDate() {
    let now = Date()
    let parsed = NanoHTTPDate.date(from: NanoHTTPDate.string())
    XCTAssertNotNil(parsed)
    XCTAssertLessThan(abs(parsed!.timeIntervalSince(now)), 2)
  }

  func testDatesAreReadInAllThreeFormsOfHTTP() {
    let expected = Date(timeIntervalSince1970: 784_111_777) // Sun, 06 Nov 1994 08:49:37 GMT
    XCTAssertEqual(NanoHTTPDate.date(from: "Sun, 06 Nov 1994 08:49:37 GMT"), expected)
    XCTAssertEqual(NanoHTTPDate.date(from: "Sunday, 06-Nov-94 08:49:37 GMT"), expected)
    XCTAssertEqual(NanoHTTPDate.date(from: "Sun Nov  6 08:49:37 1994"), expected)
    XCTAssertEqual(NanoHTTPDate.date(from: "  Sun, 06 Nov 1994 08:49:37 GMT  "), expected)
    XCTAssertNil(NanoHTTPDate.date(from: "yesterday"))
    XCTAssertNil(NanoHTTPDate.date(from: ""))
  }

  func testDatesCanBeFormattedAndReadByManyThreadsAtOnce() {
    DispatchQueue.concurrentPerform(iterations: 2000) { index in
      let date = Date(timeIntervalSince1970: Double(1_000_000_000 + index % 50))
      XCTAssertEqual(NanoHTTPDate.date(from: NanoHTTPDate.string(for: date)), date)
    }
  }
}

final class InlineBodyTests: XCTestCase {

  func testBodiesInMemoryKnowTheirLength() throws {
    XCTAssertEqual(try NanoHTTPResponse.Body.empty.inline()?.count, 0)
    XCTAssertEqual(try NanoHTTPResponse.Body.text("héllo").inline()?.count, 6)
    XCTAssertEqual(try NanoHTTPResponse.Body.html("<p>").inline()?.count, 3)
    XCTAssertEqual(try NanoHTTPResponse.Body.data(Data([1, 2, 3]), contentType: nil).inline()?.count, 3)
    XCTAssertEqual(try NanoHTTPResponse.Body.json(["a": 1]).inline()?.count, 7)
  }

  func testBodiesInMemoryAreAppended() throws {
    var buffer = Array("head".utf8)
    try NanoHTTPResponse.Body.text("é").inline()?.append(to: &buffer)
    try NanoHTTPResponse.Body.data(Data([0xFF]), contentType: nil).inline()?.append(to: &buffer)
    XCTAssertEqual(buffer, Array("head".utf8) + [0xC3, 0xA9, 0xFF])
  }

  func testFunctionsAndSwitchedConnectionsAreNotInMemory() throws {
    XCTAssertNil(try NanoHTTPResponse.Body.custom({ _ in }, contentType: nil).inline())
    XCTAssertNil(try NanoHTTPResponse.Body.socket({ _ in }).inline())
  }

  func testJSONThatIsNoJSONCannotBeProduced() {
    XCTAssertThrowsError(try NanoHTTPResponse.Body.json(NSObject()).inline())
  }
}

final class ServerResponseTests: XCTestCase {

  func testEveryResponseHasADate() throws {
    try withTestServer(configure: { server in
      server.get["/a"] = { _ in .ok(.text("a")) }
      server.get["/b"] = { _ in .notFound() }
      server.get["/c"] = { _ in .custom(200) { writer in try writer.write(Array("c".utf8)) } }
    }) { _, port in
      for path in ["/a", "/b", "/c", "/missing"] {
        let response = try RawClient.get(path, port: port)
        let date = response.header("date")
        XCTAssertNotNil(date, path)
        let parsed = date.flatMap { NanoHTTPDate.date(from: $0) }
        XCTAssertNotNil(parsed, "\(path): \(date ?? "")")
        if let parsed {
          XCTAssertLessThan(abs(parsed.timeIntervalSinceNow), 3, path)
        }
      }
    }
  }

  func testResponsesWithoutABodyHaveNoLengthAndSendNoBody() throws {
    try withTestServer(configure: { server in
      server.get["/204"] = { _ in NanoHTTPResponse(statusCode: 204, body: .text("must not be sent")) }
      server.get["/304"] = { _ in NanoHTTPResponse(statusCode: 304, body: .text("must not be sent")) }
    }) { _, port in
      for path in ["/204", "/304"] {
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", path, headers: ["Connection: keep-alive"]))
        let response = client.readResponse()
        XCTAssertNil(response?.header("content-length"), path)
        XCTAssertEqual(response?.body.count, 0, path)
        // The connection is still in step: the next response is not the body that must not be sent.
        client.send(RawClient.requestText("GET", path, headers: ["Connection: keep-alive"]))
        XCTAssertEqual(client.readResponse()?.status, path == "/204" ? 204 : 304, path)
      }
    }
  }

  func testASmallResponseArrivesInOneRead() throws {
    try withTestServer(configure: { server in
      server.get["/small"] = { _ in .ok(.text("small body")) }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/small", headers: ["Connection: close"]))
      usleep(200_000) // everything that the server sent has arrived
      let bytes = client.readToEnd(timeout: 1)
      XCTAssertTrue(text(bytes).hasSuffix("\r\n\r\nsmall body"))
    }
  }

  /// Bodies above the limit for coalescing are written after the head, from where they are (a body of
  /// megabytes was once copied into a new array first, which cost more CPU than 1.0.2 needed).
  func testLargeBodiesInMemoryArriveUnchangedAndTheConnectionStaysUsable() throws {
    let pattern = (0..<(300 * 1024)).map { UInt8(truncatingIfNeeded: $0 / 5 &+ $0) }
    let words = String(repeating: "größe ✓ ", count: 40_000)
    for threading in [NanoHTTPServerIO.Configuration.Threading.perConnection, .singleThread] {
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.get["/data"] = { _ in .ok(.data(Data(pattern), contentType: "application/octet-stream")) }
        server.get["/text"] = { _ in .ok(.text(words)) }
        server.get["/small"] = { _ in .ok(.text("after")) }
      }) { _, port in
        let client = try RawClient(port: port, timeout: 10)
        let keepAlive = ["Connection: keep-alive"]
        client.send(RawClient.requestText("GET", "/data", headers: keepAlive))
        let data = client.readResponse()
        XCTAssertEqual(data?.header("Content-Length"), String(pattern.count), "\(threading)")
        XCTAssertEqual(data?.body, pattern, "\(threading)")
        client.send(RawClient.requestText("GET", "/text", headers: keepAlive))
        let text = client.readResponse()
        XCTAssertEqual(text?.header("Content-Length"), String(words.utf8.count), "\(threading)")
        XCTAssertEqual(text?.body, Array(words.utf8), "\(threading)")
        client.send(RawClient.requestText("GET", "/small", headers: keepAlive))
        XCTAssertEqual(client.readResponse().map { String(decoding: $0.body, as: UTF8.self) }, "after", "\(threading)")
      }
    }
  }
}

final class RequestVersionTests: XCTestCase {

  private func parse(_ requestLine: String) throws -> NanoHTTPRequest {
    return try NanoHTTPParser(socket: FileSocket(requestLine + "\r\n\r\n")).readHttpRequest()
  }

  func testTheVersionOfTheRequestIsKept() throws {
    XCTAssertEqual(try parse("GET / HTTP/1.1").httpVersion, "HTTP/1.1")
    XCTAssertEqual(try parse("GET / HTTP/1.0").httpVersion, "HTTP/1.0")
    XCTAssertEqual(NanoHTTPRequest(method: "GET", path: "/").httpVersion, "HTTP/1.1")
  }

  func testBytesThatAreNotASCIIInHeadersStillArriveAsOneCharacterEach() throws {
    let request = try NanoHTTPParser(socket: FileSocket(Array("GET / HTTP/1.1\r\nX-Name: ".utf8) + [0xE9, 0xFF] + Array("\r\n\r\n".utf8))).readHttpRequest()
    XCTAssertEqual(request.header("x-name"), "\u{E9}\u{FF}")
  }
}
