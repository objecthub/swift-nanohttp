//
//  SecurityTests.swift
//  NanoHTTPTests
//
//  Regression tests for the security findings S1–S7 of the assessment plan.
//  Tests wrapped in `expectKnownIssue` assert the CORRECT behavior and currently fail as
//  expected; see Support/KnownIssue.swift. Fixed findings are plain tests (S1: path traversal).
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

  /// The secret lives *outside* the shared directory; no request may ever return it, and a
  /// request that tries to reach it is answered with 403.
  private func assertRefused(_ path: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws {
    try self.serve { port in
      let response = try RawClient.get(path, port: port)
      XCTAssertFalse(response.bodyString.contains(FileFixture.secret),
                     "\(path) leaked a file outside the shared directory", file: file, line: line)
      XCTAssertEqual(response.status, 403, "\(path) must be refused", file: file, line: line)
    }
  }

  /// Like `assertRefused`, but the request may also simply find nothing (404).
  private func assertSecretIsNotServed(_ path: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) throws {
    try self.serve { port in
      let response = try RawClient.get(path, port: port)
      XCTAssertFalse(response.bodyString.contains(FileFixture.secret),
                     "\(path) leaked a file outside the shared directory", file: file, line: line)
      XCTAssertNotEqual(response.status, 200, "\(path) must not succeed", file: file, line: line)
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

  func testNamesContainingDotsAreStillServed() throws {
    try self.serve { port in
      let response = try RawClient.get("/public/my..file.txt", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.bodyString, "dotted")
    }
  }

  func testSymlinkInsideRootIsFollowed() throws {
    try self.serve { port in
      let response = try RawClient.get("/public/alias.txt", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.bodyString, "hello")
      // The size of the target (5), not the length of the link text "hello.txt" (9).
      XCTAssertEqual(response.header("content-length"), "5")
    }
  }

  func testSharedFileThatIsASymlinkSendsTheSizeOfItsTarget() throws {
    try withTestServer(configure: { server in
      server["/alias"] = share(file: self.fixture.publicDir + "/alias.txt")
    }) { _, port in
      let response = try RawClient.get("/alias", port: port)
      XCTAssertEqual(response.header("content-length"), "5")
      XCTAssertEqual(response.bodyString, "hello")
    }
  }

  func testSharedDirectoryMayBeGivenAsASymlink() throws {
    try withTestServer(configure: { server in
      server["/public/::path"] = share(directory: self.fixture.root + "/public-link")
      server["/files/::path"] = browse(directory: self.fixture.root + "/public-link")
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/public/hello.txt", port: port).bodyString, "hello")
      XCTAssertEqual(try RawClient.get("/public/alias.txt", port: port).bodyString, "hello")
      XCTAssertEqual(try RawClient.get("/files/", port: port).status, 200)
      XCTAssertEqual(try RawClient.get("/public/../secret.txt", port: port).status, 403)
      XCTAssertEqual(try RawClient.get("/public/escape.txt", port: port).status, 403)
    }
  }

  // The attacks (S1, fixed): none of them may leave the shared directory.

  func testTraversalWithLiteralDotDotSegments() throws {
    try self.assertRefused("/public/../secret.txt")
    try self.assertRefused("/public/sub/../../secret.txt")
    try self.assertRefused("/files/../secret.txt")
  }

  func testTraversalWithPercentEncodedDotDotSegments() throws {
    try self.assertRefused("/public/%2e%2e/secret.txt")
    try self.assertRefused("/public/%2E%2E/secret.txt")
    try self.assertRefused("/public/.%2e/secret.txt")
  }

  func testTraversalWithPercentEncodedSlash() throws {
    try self.assertRefused("/public/..%2fsecret.txt")
    try self.assertRefused("/public/sub%2f..%2f..%2fsecret.txt")
    // A backslash is an ordinary file name character here, so "..\\.." is just a name that does
    // not exist: 404, and in any case not the secret.
    try self.assertSecretIsNotServed("/public/..%5C..%5Csecret.txt")
  }

  func testBrowseRefusesToListTheParentDirectory() throws {
    try self.serve { port in
      for path in ["/files/%2e%2e/", "/files/..", "/files/sub/../..", "/files/outerdir/"] {
        let response = try RawClient.get(path, port: port)
        XCTAssertEqual(response.status, 403, path)
        XCTAssertFalse(response.bodyString.contains("secret.txt"), "listing of the parent directory was served: \(path)")
      }
    }
  }

  func testBrowseRefusesToReadFilesOutsideTheRoot() throws {
    try self.assertRefused("/files/%2e%2e/secret.txt")
    try self.assertRefused("/files/escape.txt")
    try self.assertRefused("/files/outerdir/secret.txt")
  }

  func testSymlinksPointingOutsideTheRootAreNotFollowed() throws {
    // Policy: a static file server does not follow links that leave its root.
    try self.assertRefused("/public/escape.txt")
    try self.assertRefused("/public/outerdir/secret.txt") // a directory link works the same way
  }

  func testEncodedNulByteIsRejected() throws {
    try self.assertRefused("/public/hello.txt%00.png")
    try self.assertRefused("/files/hello.txt%00")
  }

  func testAbsoluteLookingPathsStayInsideTheRoot() throws {
    // "%2f" at the start must not turn the request into an absolute path.
    try self.assertSecretIsNotServed("/public/%2fsecret.txt")
    let absolute = (self.fixture.root + "/secret.txt").replacingOccurrences(of: "/", with: "%2f")
    try self.assertSecretIsNotServed("/public/\(absolute)")
  }

  func testPercentEncodingIsDecodedOnlyOnce() throws {
    // %252e%252e decodes to the literal file name "%2e%2e", not to "..".
    try self.assertSecretIsNotServed("/public/%252e%252e/secret.txt")
  }

  func testDefaultFileThatLinksOutsideTheRootIsNotServed() throws {
    try FileManager.default.createSymbolicLink(atPath: self.fixture.publicDir + "/index.html",
                                               withDestinationPath: "../secret.txt")
    try self.serve { port in
      let response = try RawClient.get("/public/", port: port)
      XCTAssertFalse(response.bodyString.contains(FileFixture.secret))
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

// MARK: - followSymlinks

final class FollowSymlinksTests: XCTestCase {
  var fixture: FileFixture!

  override func setUpWithError() throws {
    self.fixture = try FileFixture()
  }

  override func tearDown() {
    self.fixture?.remove()
    self.fixture = nil
  }

  private func serve(followSymlinks: Bool, _ body: (Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server["/public/::path"] = share(directory: self.fixture.publicDir, followSymlinks: followSymlinks)
      server["/files/::path"] = browse(directory: self.fixture.publicDir, followSymlinks: followSymlinks)
    }) { _, port in
      try body(port)
    }
  }

  func testLinksLeavingTheDirectoryAreRefusedByDefault() throws {
    try withTestServer(configure: { server in // parameter omitted
      server["/public/::path"] = share(directory: self.fixture.publicDir)
      server["/files/::path"] = browse(directory: self.fixture.publicDir)
    }) { _, port in
      for path in ["/public/escape.txt", "/public/outerdir/secret.txt", "/files/escape.txt", "/files/outerdir/"] {
        XCTAssertEqual(try RawClient.get(path, port: port).status, 403, path)
      }
    }
  }

  func testExplicitFalseBehavesLikeTheDefault() throws {
    try serve(followSymlinks: false) { port in
      for path in ["/public/escape.txt", "/public/outerdir/secret.txt", "/files/escape.txt", "/files/outerdir/"] {
        XCTAssertEqual(try RawClient.get(path, port: port).status, 403, path)
      }
      XCTAssertEqual(try RawClient.get("/public/alias.txt", port: port).bodyString, "hello") // inside: fine
    }
  }

  func testEnabledFollowsLinksLeavingTheDirectory() throws {
    try serve(followSymlinks: true) { port in
      XCTAssertEqual(try RawClient.get("/public/escape.txt", port: port).bodyString, FileFixture.secret)
      XCTAssertEqual(try RawClient.get("/public/outerdir/secret.txt", port: port).bodyString, FileFixture.secret)
      XCTAssertEqual(try RawClient.get("/files/escape.txt", port: port).bodyString, FileFixture.secret)
      let listing = try RawClient.get("/files/outerdir/", port: port)
      XCTAssertEqual(listing.status, 200)
      XCTAssertTrue(listing.bodyString.contains("secret.txt"))
    }
  }

  func testEnabledStillServesOrdinaryFilesAndLinksInsideTheDirectory() throws {
    try serve(followSymlinks: true) { port in
      XCTAssertEqual(try RawClient.get("/public/hello.txt", port: port).bodyString, "hello")
      XCTAssertEqual(try RawClient.get("/public/alias.txt", port: port).bodyString, "hello")
      XCTAssertEqual(try RawClient.get("/public/sub/nested.txt", port: port).bodyString, "nested")
      XCTAssertEqual(try RawClient.get("/public/nope.txt", port: port).status, 404)
    }
  }

  /// `followSymlinks` is about links on disk only; it never permits `..` in the request.
  func testEnabledStillRefusesDotDotAndNul() throws {
    try serve(followSymlinks: true) { port in
      for path in ["/public/../secret.txt", "/public/%2e%2e/secret.txt", "/public/..%2fsecret.txt",
                   "/files/../secret.txt", "/files/%2e%2e/", "/public/hello.txt%00.png", "/files/hello.txt%00"] {
        let response = try RawClient.get(path, port: port)
        XCTAssertEqual(response.status, 403, path)
        XCTAssertFalse(response.bodyString.contains(FileFixture.secret), path)
      }
    }
  }

  func testEnabledAllowsADefaultFileThatIsALinkOutOfTheDirectory() throws {
    try FileManager.default.createSymbolicLink(atPath: self.fixture.publicDir + "/index.html",
                                               withDestinationPath: "../secret.txt")
    try serve(followSymlinks: true) { port in
      XCTAssertEqual(try RawClient.get("/public/", port: port).bodyString, FileFixture.secret)
    }
    try serve(followSymlinks: false) { port in
      XCTAssertFalse(try RawClient.get("/public/", port: port).bodyString.contains(FileFixture.secret))
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
