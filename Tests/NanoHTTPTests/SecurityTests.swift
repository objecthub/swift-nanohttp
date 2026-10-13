//
//  SecurityTests.swift
//  NanoHTTPTests
//
//  Regression tests for the security findings S1–S7 of the assessment plan.
//  Tests wrapped in `expectKnownIssue` assert the CORRECT behavior and currently fail as
//  expected; see Support/KnownIssue.swift.
//

import XCTest
@testable import NanoHTTP

// MARK: - S1: path traversal in share(directory:) / browse(directory:)

final class FileServingSecurityTests: XCTestCase {
  var fixture: FileFixture!

  override func setUpWithError() throws {
    self.fixture = try FileFixture()
  }

  override func tearDown() {
    self.fixture?.remove()
    self.fixture = nil
  }

  private func serve(_ body: (Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server["/public/::path"] = share(directory: self.fixture.publicDir)
      server["/files/::path"] = browse(directory: self.fixture.publicDir)
    }) { _, port in
      try body(port)
    }
  }

  /// The secret lives *outside* the shared directory; no request may ever return it.
  private func assertSecretIsNotServed(_ path: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) throws {
    try self.serve { port in
      let response = try? RawClient.get(path, port: port)
      XCTAssertFalse(response?.bodyString.contains(FileFixture.secret) ?? false,
                     "\(path) leaked a file outside the shared directory", file: file, line: line)
      XCTAssertNotEqual(response?.status, 200, "\(path) must not succeed", file: file, line: line)
    }
  }

  // Controls: legitimate access keeps working.

  func testServesFileInsideRoot() throws {
    try self.serve { port in
      let response = try RawClient.get("/public/hello.txt", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.bodyString, "hello")
      XCTAssertEqual(response.header("content-type"), "text/plain")
    }
  }

  func testServesNestedFileInsideRoot() throws {
    try self.serve { port in
      let response = try RawClient.get("/public/sub/nested.txt", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.bodyString, "nested")
    }
  }

  func testMissingFileIs404() throws {
    try self.serve { port in
      XCTAssertEqual(try RawClient.get("/public/nope.txt", port: port).status, 404)
    }
  }

  func testBrowseListsRoot() throws {
    try self.serve { port in
      let response = try RawClient.get("/files/", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertTrue(response.bodyString.contains("hello.txt"))
    }
  }

  // The attacks.

  func testTraversalWithLiteralDotDotSegments() throws {
    try expectKnownIssue("S1", "'..' segments escape the shared directory") {
      try self.assertSecretIsNotServed("/public/../secret.txt")
    }
  }

  func testTraversalWithPercentEncodedDotDotSegments() throws {
    try expectKnownIssue("S1", "%2e%2e segments escape the shared directory") {
      try self.assertSecretIsNotServed("/public/%2e%2e/secret.txt")
    }
  }

  func testTraversalWithPercentEncodedSlash() throws {
    try expectKnownIssue("S1", "..%2f inside one segment escapes the shared directory") {
      try self.assertSecretIsNotServed("/public/..%2fsecret.txt")
    }
  }

  func testBrowseCanListDirectoryOutsideRoot() throws {
    try expectKnownIssue("S1", "browse lists the parent of the shared directory") {
      try self.serve { port in
        let response = try? RawClient.get("/files/%2e%2e/", port: port)
        XCTAssertFalse(response?.bodyString.contains("secret.txt") ?? false,
                       "listing of the parent directory was served")
      }
    }
  }

  func testBrowseCanReadFileOutsideRoot() throws {
    try expectKnownIssue("S1", "browse serves files outside the shared directory") {
      try self.assertSecretIsNotServed("/files/%2e%2e/secret.txt")
    }
  }

  func testSymlinkPointingOutsideRootIsNotFollowed() throws {
    // Policy decision: a static file server should not follow links that leave its root.
    try expectKnownIssue("S1", "symlink inside the root points at a file outside of it") {
      try self.assertSecretIsNotServed("/public/escape.txt")
    }
  }

  func testEncodedNulByteIsRejected() throws {
    try expectKnownIssue("S1", "%00 truncates the path (C-string) instead of being rejected") {
      try self.serve { port in
        let response = try? RawClient.get("/public/hello.txt%00.png", port: port)
        XCTAssertNotEqual(response?.status, 200)
      }
    }
  }

  // MARK: S5 (browse part): file names are inserted into HTML unescaped

  func testBrowseEscapesFileNames() throws {
    try expectKnownIssue("S5", "file name is interpolated into HTML without escaping") {
      try self.serve { port in
        let response = try RawClient.get("/files/", port: port)
        XCTAssertFalse(response.bodyString.contains(FileFixture.xssName),
                       "listing contains a raw HTML element built from a file name")
      }
    }
  }
}

// MARK: - S2: unbounded sizes while parsing a request

final class RequestSizeLimitTests: XCTestCase {

  func testHugeContentLengthIsRejectedWithoutAllocating() throws {
    try requireCrashTests("S2", "Content-Length of Int.max is passed to Array(unsafeUninitializedCapacity:)")
    let socket = FileSocket("POST / HTTP/1.1\r\nContent-Length: 9223372036854775807\r\n\r\n")
    XCTAssertThrowsError(try NanoHTTPParser(socket: socket).readHttpRequest())
  }

  func testOverlongRequestLineIsRejected() throws {
    let target = String(repeating: "a", count: 100_000)
    let socket = FileSocket("GET /\(target) HTTP/1.1\r\n\r\n")
    try expectKnownIssue("S2", "request line length is unbounded") {
      XCTAssertThrowsError(try NanoHTTPParser(socket: socket).readHttpRequest())
    }
  }

  func testOversizedHeaderBlockIsRejected() throws {
    var text = "GET / HTTP/1.1\r\n"
    let value = String(repeating: "v", count: 1000)
    for index in 0..<2000 {
      text += "X-Header-\(index): \(value)\r\n"
    }
    text += "\r\n"
    let socket = FileSocket(text)
    try expectKnownIssue("S2", "total header size / header count is unbounded (here: ~2 MB)") {
      XCTAssertThrowsError(try NanoHTTPParser(socket: socket).readHttpRequest())
    }
  }

  func testNegativeContentLengthIsRejected() throws {
    let socket = FileSocket("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n")
    XCTAssertThrowsError(try NanoHTTPParser(socket: socket).readHttpRequest()) { error in
      XCTAssertEqual(error as? NanoHTTPParserError, .negativeContentLength)
    }
  }
}

// MARK: - S3: WebSocket frame length

final class WebSocketFrameLimitTests: XCTestCase {

  private func frame(lengthBytes: [UInt8]) -> WebSocketSession {
    // FIN + text, masked + length marker 127 (8-byte length follows), the length, a 4-byte mask.
    return WebSocketSession(FileSocket([0x81, 0xFF] + lengthBytes + [0, 0, 0, 0]))
  }

  /// The claimed payload length is used as an allocation size without any limit, so a single
  /// 14-byte frame aborts the process ("failed to allocate N bytes"). Observed: with the first
  /// length byte 0x80 the decoded length is 2^61, not 2^63, because that byte is shifted by 54
  /// instead of 56 (second defect, same line).
  func testHugeFrameLengthDoesNotCrash() throws {
    try requireCrashTests("S3", "claimed frame length is allocated up front; also `<< 54` typo")
    XCTAssertThrowsError(try self.frame(lengthBytes: [0x80, 0, 0, 0, 0, 0, 0, 0]).readFrame())
  }

  /// Plain macOS grants a 1 TiB allocation lazily, so the read then fails with EOF and this
  /// passes; under AddressSanitizer (and on iOS) the allocation itself aborts the process.
  /// Same defect as above, so it shares the gate.
  func testOneTerabyteFrameLengthFailsCleanly() throws {
    try requireCrashTests("S3", "1 TiB payload buffer: aborts under ASan / on iOS, lazily granted on macOS")
    XCTAssertThrowsError(try self.frame(lengthBytes: [0, 0, 1, 0, 0, 0, 0, 0]).readFrame())
  }
}

// MARK: - S4: listen address handling

final class ListenAddressTests: XCTestCase {

  func testInvalidIPv4ListenAddressThrows() throws {
    let server = NanoHTTPServer()
    server.listenAddressIPv4 = "127.0.0.1x" // typo
    defer { server.stop() }
    try expectKnownIssue("S4", "invalid address is ignored and the server binds to ALL interfaces") {
      XCTAssertThrowsError(try server.start(0, forceIPv4: true))
    }
  }

  func testInvalidIPv6ListenAddressThrows() throws {
    let server = NanoHTTPServer()
    server.listenAddressIPv6 = "::1x" // typo
    defer { server.stop() }
    try expectKnownIssue("S4", "invalid address is ignored and the server binds to ALL interfaces") {
      XCTAssertThrowsError(try server.start(0, forceIPv4: false))
    }
  }

  func testLoopbackListenAddressIsAccepted() throws {
    try withTestServer { server, port in
      XCTAssertTrue(server.operating)
      XCTAssertGreaterThan(port, 0)
    }
  }
}

// MARK: - S5: NanoHTML escaping (decision pending: 1.0.2 for attributes, 2.0 for inner text)

final class HTMLEscapingTests: XCTestCase {

  private func render(_ scope: @escaping NanoHTMLClosure) -> String {
    return htmlHandler(scope)(NanoHTTPRequest(method: "GET", path: "/")).capturedBody()
  }

  func testAttributeValueCannotBreakOutOfTheAttribute() throws {
    let html = self.render {
      a { href = "x\" onclick=\"evil()"; inner = "link" }
    }
    expectKnownIssue("S5", "attribute values are not escaped") {
      XCTAssertFalse(html.contains("\" onclick=\""), html)
    }
  }

  func testInnerTextIsEscaped() throws {
    let html = self.render {
      p { inner = "<script>alert(1)</script>" }
    }
    expectKnownIssue("S5", "inner text is emitted verbatim (design decision: raw vs. escaped)") {
      XCTAssertFalse(html.contains("<script>alert(1)</script>"), html)
    }
  }
}

// MARK: - S7: header / response splitting

final class HeaderInjectionTests: XCTestCase {

  func testCRLFInRedirectLocationCannotInjectHeaders() throws {
    try withTestServer(configure: { server in
      server["/redir"] = { _ in .movedTemporarily("/ok\r\nSet-Cookie: pwned=1") }
    }) { _, port in
      let response = try RawClient.get("/redir", port: port)
      expectKnownIssue("S7", "CR/LF in header values is written verbatim") {
        XCTAssertNil(response.header("set-cookie"), "injected header reached the client")
      }
    }
  }

  func testCRLFInCustomHeaderValueCannotInjectHeaders() throws {
    try withTestServer(configure: { server in
      server["/h"] = { _ in .ok(headers: ["X-Echo": "a\r\nInjected: yes"], .text("x")) }
    }) { _, port in
      let response = try RawClient.get("/h", port: port)
      expectKnownIssue("S7", "CR/LF in header values is written verbatim") {
        XCTAssertNil(response.header("injected"), "injected header reached the client")
      }
    }
  }

  func testRedirectWithPlainLocationStillWorks() throws {
    try withTestServer(configure: { server in
      server["/redir"] = { _ in .movedTemporarily("/ok") }
    }) { _, port in
      let response = try RawClient.get("/redir", port: port)
      XCTAssertEqual(response.status, 307)
      XCTAssertEqual(response.header("location"), "/ok")
    }
  }
}
