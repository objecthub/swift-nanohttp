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

// MARK: - S1: path traversal in NanoFiles.share(directory:) / NanoFiles.browse(directory:)

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
      server["/public/::path"] = NanoFiles.share(directory: self.fixture.publicDir)
      server["/files/::path"] = NanoFiles.browse(directory: self.fixture.publicDir)
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
      server["/alias"] = NanoFiles.share(file: self.fixture.publicDir + "/alias.txt")
    }) { _, port in
      let response = try RawClient.get("/alias", port: port)
      XCTAssertEqual(response.header("content-length"), "5")
      XCTAssertEqual(response.bodyString, "hello")
    }
  }

  func testSharedDirectoryMayBeGivenAsASymlink() throws {
    try withTestServer(configure: { server in
      server["/public/::path"] = NanoFiles.share(directory: self.fixture.root + "/public-link")
      server["/files/::path"] = NanoFiles.browse(directory: self.fixture.root + "/public-link")
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

  // MARK: S5 (browse part, fixed): file names are escaped

  func testBrowseEscapesFileNames() throws {
    try self.serve { port in
      let response = try RawClient.get("/files/", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertFalse(response.bodyString.contains(FileFixture.xssName),
                     "listing contains a raw HTML element built from a file name")
      XCTAssertTrue(response.bodyString.contains(">&lt;img src=x onerror=alert(1)&gt;.txt</a>"), response.bodyString)
    }
  }

  func testBrowseLinksStayUsableAndCannotBreakOutOfTheAttribute() throws {
    try self.serve { port in
      let response = try RawClient.get("/files/sub/", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertTrue(response.bodyString.contains("<a href=\"/files/sub/nested.txt\">nested.txt</a>"), response.bodyString)
      // The request path is echoed into the links: a quote in it must not end the attribute.
      let hostile = try RawClient.get("/files/sub/%22%3E%3Cb%3E/", port: port) // does not exist: 404, no echo
      XCTAssertEqual(hostile.status, 404)
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
      server["/public/::path"] = NanoFiles.share(directory: self.fixture.publicDir, followSymlinks: followSymlinks)
      server["/files/::path"] = NanoFiles.browse(directory: self.fixture.publicDir, followSymlinks: followSymlinks)
    }) { _, port in
      try body(port)
    }
  }

  func testLinksLeavingTheDirectoryAreRefusedByDefault() throws {
    try withTestServer(configure: { server in // parameter omitted
      server["/public/::path"] = NanoFiles.share(directory: self.fixture.publicDir)
      server["/files/::path"] = NanoFiles.browse(directory: self.fixture.publicDir)
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

// MARK: - S2: size limits while parsing a request (fixed)

final class RequestSizeLimitTests: XCTestCase {

  private func parser(_ text: String, _ limits: NanoHTTPParser.Limits = .init()) -> NanoHTTPParser {
    return NanoHTTPParser(socket: FileSocket(text), limits: limits)
  }

  private func assertParserError(_ expected: NanoHTTPParserError,
                                 _ text: String,
                                 _ limits: NanoHTTPParser.Limits = .init(),
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
    XCTAssertThrowsError(try parser(text, limits).readHttpRequest(), file: file, line: line) { error in
      XCTAssertEqual(error as? NanoHTTPParserError, expected, file: file, line: line)
    }
  }

  // Body size

  func testHugeContentLengthIsRejectedWithoutAllocating() {
    // Used to abort the process: "failed to allocate 9223372036854775839 bytes".
    assertParserError(.bodyTooLarge, "POST / HTTP/1.1\r\nContent-Length: 9223372036854775807\r\n\r\n")
  }

  func testContentLengthBeyondIntIsTooLargeNotInvalid() {
    assertParserError(.bodyTooLarge, "POST / HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n")
  }

  func testBodyAtTheLimitIsAcceptedOneByteMoreIsNot() throws {
    let limits = NanoHTTPParser.Limits(maxBodyBytes: 10)
    XCTAssertEqual(try parser("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789", limits).readHttpRequest().body.count, 10)
    assertParserError(.bodyTooLarge, "POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\n01234567890", limits)
  }

  func testAnnouncedButMissingBodyFailsWithoutReservingMemory() {
    // 50 MB are announced (within the default limit), none arrive.
    XCTAssertThrowsError(try parser("POST / HTTP/1.1\r\nContent-Length: 50000000\r\n\r\n").readHttpRequest()) { error in
      XCTAssertTrue(error is NanoSocketError, "\(error)")
    }
  }

  func testNegativeContentLengthIsRejected() {
    assertParserError(.negativeContentLength, "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n")
  }

  func testNonNumericContentLengthIsRejected() {
    for value in ["abc", "1x", "1.5", "0x10", "1 2"] {
      assertParserError(.invalidContentLength, "POST / HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n")
    }
  }

  // Line and header sizes

  func testRequestLineAtTheLimitIsAcceptedOneByteMoreIsNot() throws {
    let limits = NanoHTTPParser.Limits(maxLineLength: 20)
    let ok = "GET /" + String(repeating: "a", count: 6) + " HTTP/1.1"      // exactly 20 characters
    XCTAssertEqual(ok.count, 20)
    XCTAssertNoThrow(try parser(ok + "\r\n\r\n", limits).readHttpRequest()) // CR does not count
    assertParserError(.requestLineTooLong, ok + "a\r\n\r\n", limits)
  }

  func testOverlongRequestLineIsRejected() {
    assertParserError(.requestLineTooLong, "GET /" + String(repeating: "a", count: 100_000) + " HTTP/1.1\r\n\r\n")
  }

  func testHeaderLineAtTheLimitIsAcceptedOneByteMoreIsNot() throws {
    let limits = NanoHTTPParser.Limits(maxLineLength: 20)
    let ok = "X: " + String(repeating: "v", count: 17)                      // exactly 20 characters
    XCTAssertEqual(ok.count, 20)
    XCTAssertEqual(try parser("GET / HTTP/1.1\r\n\(ok)\r\n\r\n", limits).readHttpRequest().header("x"), String(repeating: "v", count: 17))
    assertParserError(.headerLineTooLong, "GET / HTTP/1.1\r\n\(ok)v\r\n\r\n", limits)
  }

  func testOversizedHeaderBlockIsRejected() {
    var text = "GET / HTTP/1.1\r\n"
    let value = String(repeating: "v", count: 1000)
    for index in 0..<2000 {
      text += "X-Header-\(index): \(value)\r\n"                            // ~2 MB in total
    }
    assertParserError(.headersTooLarge, text + "\r\n")
  }

  func testHeaderBlockBudgetIsExact() throws {
    let text = "GET / HTTP/1.1\r\nA: b\r\n\r\n"                             // 16 + 6 + 2 bytes
    let size = text.utf8.count
    XCTAssertNoThrow(try parser(text, .init(maxHeaderBytes: size)).readHttpRequest())
    assertParserError(.headersTooLarge, text, .init(maxHeaderBytes: size - 1))
  }

  func testControlCharactersFloodCannotBypassTheHeaderBudget() {
    // Control characters are dropped from lines, so they never count as line length; the total
    // byte budget still stops them.
    let flood = String(repeating: "\u{1}", count: 200_000)
    assertParserError(.headersTooLarge, "GET / HTTP/1.1\r\nX: \(flood)\r\n\r\n")
  }

  func testLimitsAreAppliedToLaterRequestsOnTheSameParser() throws {
    // The budget is per request, not per connection.
    let two = "GET /1 HTTP/1.1\r\nA: b\r\n\r\nGET /2 HTTP/1.1\r\nA: b\r\n\r\n"
    let reader = parser(two, .init(maxHeaderBytes: 30))
    XCTAssertEqual(try reader.readHttpRequest().path, "/1")
    XCTAssertEqual(try reader.readHttpRequest().path, "/2")
  }
}

// MARK: - S2: the server answers refused requests

final class RequestSizeLimitServerTests: XCTestCase {

  private func serve(limits: NanoHTTPParser.Limits = .init(),
                     _ body: (Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.limits = limits
      server.get["/ping"] = { _ in .ok(.text("pong")) }
      server.post["/echo"] = { request in .ok(.text("\(request.body.count)")) }
    }) { _, port in
      try body(port)
    }
  }

  func testOverlongRequestLineGets414() throws {
    try serve { port in
      let client = try RawClient(port: port)
      client.send("GET /" + String(repeating: "a", count: 20_000) + " HTTP/1.1\r\n\r\n")
      let response = client.readResponse()
      XCTAssertEqual(response?.status, 414)
      XCTAssertEqual(response?.header("connection"), "close")
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testOverlongHeaderLineAndOversizedHeaderBlockGet431() throws {
    try serve { port in
      var client = try RawClient(port: port)
      client.send("GET / HTTP/1.1\r\nX: " + String(repeating: "v", count: 20_000) + "\r\n\r\n")
      XCTAssertEqual(client.readResponse()?.status, 431)
      client = try RawClient(port: port)
      var text = "GET / HTTP/1.1\r\n"
      for index in 0..<200 { text += "X-\(index): " + String(repeating: "v", count: 1000) + "\r\n" }
      client.send(text + "\r\n")
      XCTAssertEqual(client.readResponse()?.status, 431)
    }
  }

  func testBodyAboveTheConfiguredLimitGets413AndAtTheLimitWorks() throws {
    try serve(limits: .init(maxBodyBytes: 100)) { port in
      let atLimit = try RawClient.request("POST", "/echo", port: port, body: [UInt8](repeating: 65, count: 100))
      XCTAssertEqual(atLimit.status, 200)
      XCTAssertEqual(atLimit.bodyString, "100")
      // The body is not even read: the announcement alone is refused.
      let client = try RawClient(port: port)
      client.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 101\r\n\r\n")
      XCTAssertEqual(client.readResponse()?.status, 413)
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testAbsurdContentLengthGets413AndTheServerKeepsServing() throws {
    try serve { port in
      let client = try RawClient(port: port)
      client.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 9223372036854775807\r\n\r\n")
      XCTAssertEqual(client.readResponse()?.status, 413)
      XCTAssertEqual(try RawClient.get("/ping", port: port).bodyString, "pong")
    }
  }

  func testMalformedContentLengthGets400() throws {
    try serve { port in
      for value in ["abc", "-5"] {
        let client = try RawClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: \(value)\r\n\r\n")
        XCTAssertEqual(client.readResponse()?.status, 400, value)
      }
    }
  }

  func testOversizedFollowUpRequestOnAKeepAliveConnectionGets413() throws {
    try serve(limits: .init(maxBodyBytes: 10)) { port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.bodyString, "pong")
      client.send("POST /echo HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\nContent-Length: 11\r\n\r\n")
      XCTAssertEqual(client.readResponse()?.status, 413)
      XCTAssertTrue(client.waitForClose(timeout: 2))
    }
  }

  func testRefusedRequestsDoNotLeakConnections() throws {
    try withTestServer(configure: { $0.configuration.limits = .init(maxLineLength: 100) }) { server, port in
      for _ in 0..<20 {
        let client = try RawClient(port: port)
        client.send("GET /" + String(repeating: "a", count: 500) + " HTTP/1.1\r\n\r\n")
        XCTAssertEqual(client.readResponse()?.status, 414)
        client.close()
      }
      usleep(200_000)
      XCTAssertEqual(server.openConnections, 0)
    }
  }
}

// MARK: - NanoSocket.read(length:)

final class SocketReadTests: XCTestCase {

  func testReadsExactlyTheRequestedBytesAcrossChunkBoundaries() throws {
    let chunk = NanoSocket.kChunkLength
    for size in [0, 1, 1023, 1024, 1025, chunk - 1, chunk, chunk + 1, 3 * chunk + 7] {
      let data = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
      XCTAssertEqual(try FileSocket(data).read(length: size), data, "size \(size)")
    }
  }

  func testReadsOnlyWhatWasRequested() throws {
    let socket = FileSocket([1, 2, 3, 4, 5])
    XCTAssertEqual(try socket.read(length: 2), [1, 2])
    XCTAssertEqual(try socket.read(length: 3), [3, 4, 5])
  }

  func testShortInputFailsInsteadOfReturningFewerBytes() {
    XCTAssertThrowsError(try FileSocket([1, 2, 3]).read(length: 4))
    XCTAssertThrowsError(try FileSocket([]).read(length: 1))
  }

  func testNegativeLengthFailsInsteadOfTrapping() {
    XCTAssertThrowsError(try FileSocket([1]).read(length: -1))
  }

  func testHugeLengthFailsWithoutAllocatingIt() {
    XCTAssertThrowsError(try FileSocket([1, 2, 3]).read(length: Int.max))
    XCTAssertThrowsError(try FileSocket([1, 2, 3]).read(length: 1 << 40))
  }
}

// MARK: - S3: WebSocket frame limits (fixed)

final class WebSocketFrameLimitTests: XCTestCase {

  private func session(_ bytes: [UInt8], maxPayloadSize: Int? = nil) -> NanoWebSocketSession {
    let session = NanoWebSocketSession(FileSocket(bytes))
    if let maxPayloadSize {
      session.maxPayloadSize = maxPayloadSize
    }
    return session
  }

  /// FIN + text, masked + length marker 127 (8-byte length follows), the length, a 4-byte mask.
  private func header64(_ lengthBytes: [UInt8]) -> [UInt8] {
    return [0x81, 0xFF] + lengthBytes + [0, 0, 0, 0]
  }

  private func assertProtocolError(_ bytes: [UInt8],
                                   maxPayloadSize: Int? = nil,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
    XCTAssertThrowsError(try session(bytes, maxPayloadSize: maxPayloadSize).readFrame(), file: file, line: line) { error in
      guard case NanoWebSocketSession.WsError.protocolError = error else {
        return XCTFail("expected a protocol error, got \(error)", file: file, line: line)
      }
    }
  }

  /// A frame that announces more than the limit allows (close code 1009, not 1002).
  private func assertTooBig(_ bytes: [UInt8],
                            maxPayloadSize: Int? = nil,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
    XCTAssertThrowsError(try session(bytes, maxPayloadSize: maxPayloadSize).readFrame(), file: file, line: line) { error in
      guard case NanoWebSocketSession.WsError.messageTooBig = error else {
        return XCTFail("expected messageTooBig, got \(error)", file: file, line: line)
      }
    }
  }

  func testHugeFrameLengthIsRejectedBeforeReadingOrAllocating() {
    // Used to abort the process: "failed to allocate 2305843009213693984 bytes".
    assertTooBig(header64([0x80, 0, 0, 0, 0, 0, 0, 0]))
    assertTooBig(header64([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
  }

  func testOneTerabyteFrameLengthIsRejected() {
    assertTooBig(header64([0, 0, 1, 0, 0, 0, 0, 0]))
  }

  /// The first length byte used to be shifted by 54 instead of 56, so 2^63 was decoded as 2^61.
  /// With an unbounded limit the two differ: 2^63 does not fit an `Int` and is a protocol error,
  /// 2^61 would be read (and fail with an I/O error).
  func testTheMostSignificantLengthByteHasWeight2To56() {
    assertTooBig(header64([0x80, 0, 0, 0, 0, 0, 0, 0]), maxPayloadSize: Int.max)
  }

  func testLengthBytesAreBigEndian() throws {
    let cases: [([UInt8], Int)] = [([0, 0, 0, 0, 0, 0, 0, 5], 5), ([0, 0, 0, 0, 0, 0, 1, 2], 258), ([0, 0, 0, 0, 0, 0, 2, 1], 513)]
    for (lengthBytes, size) in cases {
      let payload = [UInt8](repeating: 0x41, count: size)
      let frame = try session(header64(lengthBytes) + payload).readFrame()
      XCTAssertEqual(frame.payload.count, size, "\(lengthBytes)")
    }
    // 16-bit form
    let frame = try session([0x81, 0xFE, 1, 2, 0, 0, 0, 0] + [UInt8](repeating: 0x41, count: 258)).readFrame()
    XCTAssertEqual(frame.payload.count, 258)
  }

  func testPayloadAtTheLimitIsAcceptedOneByteMoreIsNot() throws {
    let payload = [UInt8](repeating: 0x41, count: 10)
    XCTAssertEqual(try session([0x81, 0x8A, 0, 0, 0, 0] + payload, maxPayloadSize: 10).readFrame().payload, payload)
    assertTooBig([0x81, 0x8B, 0, 0, 0, 0] + payload + [0x41], maxPayloadSize: 10)
  }

  func testMaskingStillWorksOnLargerPayloads() throws {
    let plain = (0..<1000).map { UInt8(truncatingIfNeeded: $0) }
    let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
    let masked = plain.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    let frame = try session([0x82, 0xFE, UInt8(1000 >> 8), UInt8(1000 & 0xFF)] + mask + masked).readFrame()
    XCTAssertEqual(frame.payload, plain)
  }

  func testControlFramesMayNotCarryMoreThan125Bytes() {
    for opcode: UInt8 in [0x88, 0x89, 0x8A] { // close, ping, pong; 126 bytes via the 16-bit length
      assertProtocolError([opcode, 0xFE, 0, 126, 0, 0, 0, 0] + [UInt8](repeating: 0x41, count: 126))
    }
    XCTAssertNoThrow(try session([0x89, 0xFD, 0, 0, 0, 0] + [UInt8](repeating: 0x41, count: 125)).readFrame())
  }
}

// MARK: - S5: HTML escaping is tested in HTMLDSLTests.swift (HTMLEscapingTests, HTMLEscapedTests)

// MARK: - S7: header / response splitting (fixed)

final class HeaderInjectionTests: XCTestCase {

  func testCRLFInRedirectLocationCannotInjectHeaders() throws {
    try withTestServer(configure: { server in
      server["/redir"] = { _ in .movedTemporarily("/ok\r\nSet-Cookie: pwned=1") }
    }) { _, port in
      let response = try RawClient.get("/redir", port: port)
      XCTAssertEqual(response.status, 307)
      XCTAssertNil(response.header("set-cookie"), "injected header reached the client")
      XCTAssertEqual(response.header("location"), "/ok  Set-Cookie: pwned=1") // one line, line break -> space
    }
  }

  func testCRLFInCustomHeaderValueCannotInjectHeaders() throws {
    try withTestServer(configure: { server in
      server["/h"] = { _ in .ok(headers: ["X-Echo": "a\r\nInjected: yes"], .text("x")) }
    }) { _, port in
      let response = try RawClient.get("/h", port: port)
      XCTAssertNil(response.header("injected"), "injected header reached the client")
      XCTAssertEqual(response.header("x-echo"), "a  Injected: yes")
      XCTAssertEqual(response.bodyString, "x")
    }
  }

  func testEveryKindOfLineBreakIsNeutralized() throws {
    try withTestServer(configure: { server in
      server["/h"] = { _ in .ok(headers: ["A": "1\rX-R: r", "B": "2\nX-N: n", "C": "3\r\n\r\n<script>", "D": "4\0X-Z: z"], .text("ok")) }
    }) { _, port in
      let response = try RawClient.get("/h", port: port)
      for injected in ["x-r", "x-n", "x-z"] {
        XCTAssertNil(response.header(injected), injected)
      }
      XCTAssertEqual(response.bodyString, "ok", "a blank line in a header value must not start the body")
    }
  }

  func testInvalidHeaderNamesAreDropped() throws {
    try withTestServer(configure: { server in
      server["/h"] = { _ in .ok(headers: ["X-Good": "1", "Bad Name": "2", "X-Colon:": "3", "X-A\r\nInjected": "4", "": "5"], .text("ok")) }
    }) { _, port in
      let response = try RawClient.get("/h", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.header("x-good"), "1")
      XCTAssertNil(response.header("injected"))
      XCTAssertEqual(response.headerFields.filter { $0.name.contains(" ") || $0.name.isEmpty || $0.name.contains(":") }.count, 0)
      XCTAssertEqual(response.bodyString, "ok")
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

  func testNonASCIIHeaderValuesAreKept() throws {
    try withTestServer(configure: { server in
      server["/h"] = { _ in .ok(headers: ["X-Name": "Jürgen €"], .text("ok")) }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/h", port: port).header("x-name"), "Jürgen €")
    }
  }
}
