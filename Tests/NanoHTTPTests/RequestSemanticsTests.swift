//
//  RequestSemanticsTests.swift
//  NanoHTTPTests
//
//  2.0 (H1): `path`, `queryParams` and the variables of a route are percent-decoded; `rawPath` and
//  `rawQuery` are what the client sent, and routing works on the raw path. Plus the helpers `query`,
//  `queries`, `bodyString` and `json`.
//

import XCTest
@testable import NanoHTTP

private func parse(target: String) throws -> NanoHTTPRequest {
  return try NanoHTTPParser(socket: FileSocket("GET \(target) HTTP/1.1\r\n\r\n")).readHttpRequest()
}

private func parse(target: String, bytes: [UInt8]) throws -> NanoHTTPRequest {
  return try NanoHTTPParser(socket: FileSocket(Array("GET ".utf8) + bytes + Array(" HTTP/1.1\r\n\r\n".utf8))).readHttpRequest()
}

// MARK: - Path and query as the parser reads them

final class RequestTargetTests: XCTestCase {

  func testThePathIsDecodedAndTheRawPathIsKept() throws {
    let request = try parse(target: "/a%20b/%C3%A9?x=1")
    XCTAssertEqual(request.path, "/a b/é")
    XCTAssertEqual(request.rawPath, "/a%20b/%C3%A9")
  }

  func testAPlusInThePathIsAPlus() throws {
    XCTAssertEqual(try parse(target: "/a+b").path, "/a+b")
    XCTAssertEqual(try parse(target: "/a%2Bb").path, "/a+b")
  }

  func testAnEncodedSlashIsDecodedInThePathButNotInTheRawPath() throws {
    let request = try parse(target: "/a%2Fb/c")
    XCTAssertEqual(request.rawPath, "/a%2Fb/c")
    XCTAssertEqual(request.path, "/a/b/c")
  }

  func testQueryNamesAndValuesAreDecoded() throws {
    let request = try parse(target: "/s?q=hello%20world&e=%E2%82%AC&n%61me=x")
    XCTAssertEqual(request.queryParams.map { "\($0.0)=\($0.1)" }, ["q=hello world", "e=€", "name=x"])
  }

  func testAPlusInTheQueryMeansASpaceAndAnEncodedPlusIsAPlus() throws {
    let request = try parse(target: "/s?q=a+b&p=1%2B1")
    XCTAssertEqual(request.queryParam("q"), "a b")
    XCTAssertEqual(request.queryParam("p"), "1+1")
  }

  func testTheRawQueryIsKept() throws {
    XCTAssertEqual(try parse(target: "/s?q=a%20b&r=1").rawQuery, "q=a%20b&r=1")
    XCTAssertNil(try parse(target: "/s").rawQuery)
    XCTAssertEqual(try parse(target: "/s?").rawQuery, "")
    XCTAssertEqual(try parse(target: "/s?").queryParams.count, 0)
  }

  func testAFragmentIsNotPartOfTheTarget() throws {
    let request = try parse(target: "/p?a=1#frag")
    XCTAssertEqual(request.rawQuery, "a=1")
    XCTAssertEqual(try parse(target: "/p#frag").rawPath, "/p")
  }

  func testQueryParametersWithoutValuesAndEmptyPairs() throws {
    let request = try parse(target: "/s?a&b=&=c&&d=1")
    XCTAssertEqual(request.queryParams.map { "\($0.0)=\($0.1)" }, ["a=", "b=", "=c", "d=1"])
  }

  func testAValueMayContainEqualsSignsAndQuestionMarks() throws {
    XCTAssertEqual(try parse(target: "/s?token=abc==").queryParam("token"), "abc==")
    let link = try parse(target: "/open?link=https://www.youtube.com/watch?v=D2cUBG4PnOA")
    XCTAssertEqual(link.queryParam("link"), "https://www.youtube.com/watch?v=D2cUBG4PnOA")
    XCTAssertEqual(link.rawPath, "/open")
  }

  func testInvalidPercentSequencesAreKept() throws {
    let request = try parse(target: "/a%zz?x=%4&y=100%")
    XCTAssertEqual(request.path, "/a%zz")
    XCTAssertEqual(request.queryParam("x"), "%4")
    XCTAssertEqual(request.queryParam("y"), "100%")
  }

  func testBytesThatAreNotUTF8BecomeReplacementCharacters() throws {
    XCTAssertEqual(try parse(target: "/a%FFb").path, "/a\u{FFFD}b")
  }

  func testNULCharactersAndControlCharactersAreDecodedAndNotHidden() throws {
    let request = try parse(target: "/a%00b%0Ac")
    XCTAssertEqual(request.path, "/a\0b\nc")
    XCTAssertEqual(request.rawPath, "/a%00b%0Ac")
  }

  func testUTF8BytesThatAreSentWithoutEncodingAreReadAsUTF8() throws {
    // Some clients send non-ASCII characters in the target as they are.
    let request = try parse(target: "/caf\u{E9}?q=\u{20AC}", bytes: Array("/caf".utf8) + [0xC3, 0xA9] + Array("?q=".utf8) + [0xE2, 0x82, 0xAC])
    XCTAssertEqual(request.path, "/café")
    XCTAssertEqual(request.rawPath, "/caf%C3%A9")
    XCTAssertEqual(request.queryParam("q"), "€")
  }

  func testAnAbsoluteTargetGivesItsPathAndQuery() throws {
    let request = try parse(target: "http://example.com:8080/a/b?x=1")
    XCTAssertEqual(request.rawPath, "/a/b")
    XCTAssertEqual(request.rawQuery, "x=1")
    XCTAssertEqual(try parse(target: "http://example.com").rawPath, "/")
    XCTAssertEqual(try parse(target: "https://example.com?x=1").rawQuery, "x=1")
  }

  func testTheTargetOfAnAsteriskRequestIsAnAsterisk() throws {
    let request = try NanoHTTPParser(socket: FileSocket("OPTIONS * HTTP/1.1\r\n\r\n")).readHttpRequest()
    XCTAssertEqual(request.rawPath, "*")
    XCTAssertEqual(request.path, "*")
  }
}

private extension NanoHTTPRequest {
  func queryParam(_ name: String) -> String? {
    return self.queryParams.first { $0.0 == name }?.1
  }
}

// MARK: - The request object

final class RequestHelperTests: XCTestCase {

  func testSettingThePathEncodesItForTheRawPath() {
    let request = NanoHTTPRequest(method: "GET", path: "/a b/é")
    XCTAssertEqual(request.path, "/a b/é")
    XCTAssertEqual(request.rawPath, "/a%20b/%C3%A9")
    request.path = "/50% off/a+b"
    XCTAssertEqual(request.rawPath, "/50%25%20off/a+b")
    XCTAssertEqual(request.path, "/50% off/a+b")
    request.rawPath = "/x%20y"
    XCTAssertEqual(request.path, "/x y")
  }

  func testAPathThatIsAlreadyDecodedRoundTrips() {
    for path in ["/", "/a/b", "/a b", "/é/€/😀", "/100%", "/a%20b", "/a?b", "/a#b", "/a;b=c", "/@user/:id"] {
      let request = NanoHTTPRequest(method: "GET", path: path)
      XCTAssertEqual(request.path, path, path)
    }
  }

  func testQueryHelpers() {
    let request = NanoHTTPRequest(method: "GET", path: "/",
                                  queryParams: [("a", "1"), ("b", "2"), ("a", "3"), ("e", "")])
    XCTAssertEqual(request.query("a"), "1")
    XCTAssertEqual(request.query("b"), "2")
    XCTAssertEqual(request.query("e"), "")
    XCTAssertNil(request.query("missing"))
    XCTAssertEqual(request.queries("a"), ["1", "3"])
    XCTAssertEqual(request.queries("missing"), [])
    XCTAssertNil(request.query("A")) // names are case-sensitive
  }

  // MARK: bodyString

  private func request(body: [UInt8], contentType: String? = nil) -> NanoHTTPRequest {
    return NanoHTTPRequest(method: "POST", path: "/",
                           headers: contentType.map { ["Content-Type": $0] } ?? [:], body: body)
  }

  func testTheBodyAsText() {
    XCTAssertEqual(request(body: Array("héllo €".utf8)).bodyString, "héllo €")
    XCTAssertEqual(request(body: []).bodyString, "")
    XCTAssertEqual(request(body: Array("x".utf8), contentType: "text/plain; charset=utf-8").bodyString, "x")
  }

  func testABodyThatIsNotUTF8HasNoText() {
    XCTAssertNil(request(body: [0xFF, 0xFE, 0x41]).bodyString)
  }

  func testTheBodyIsReadInTheCharsetOfTheContentType() {
    XCTAssertEqual(request(body: [0x63, 0x61, 0x66, 0xE9], contentType: "text/plain; charset=ISO-8859-1").bodyString, "café")
    XCTAssertEqual(request(body: [0x63, 0x61, 0x66, 0xE9], contentType: "text/plain;charset=\"latin1\"").bodyString, "café")
    XCTAssertEqual(request(body: Array("abc".utf8), contentType: "text/plain; charset=us-ascii").bodyString, "abc")
    XCTAssertEqual(request(body: [0x61, 0x00, 0x62, 0x00], contentType: "text/plain; charset=utf-16le").bodyString, "ab")
  }

  func testAnUnknownCharsetFallsBackToUTF8() {
    XCTAssertEqual(request(body: Array("é".utf8), contentType: "text/plain; charset=no-such-charset").bodyString, "é")
  }

  // MARK: JSON

  private struct Person: Decodable, Equatable {
    let name: String
    let age: Int
    let tags: [String]?
  }

  func testJSONIsDecoded() throws {
    let body = Array(#"{"name": "Ada", "age": 36, "tags": ["math"]}"#.utf8)
    XCTAssertEqual(try request(body: body).json(Person.self), Person(name: "Ada", age: 36, tags: ["math"]))
    let inferred: Person = try request(body: body).json()
    XCTAssertEqual(inferred.name, "Ada")
    XCTAssertEqual(try request(body: Array("[1, 2, 3]".utf8)).json([Int].self), [1, 2, 3])
  }

  func testJSONIsDecodedWithTheGivenDecoder() throws {
    struct Snake: Decodable { let firstName: String }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    XCTAssertEqual(try request(body: Array(#"{"first_name": "Ada"}"#.utf8)).json(Snake.self, decoder: decoder).firstName, "Ada")
  }

  private func jsonError(_ body: String) -> NanoHTTPError? {
    do {
      _ = try request(body: Array(body.utf8)).json(Person.self)
      return nil
    } catch {
      return error as? NanoHTTPError
    }
  }

  func testInvalidJSONIsABadRequestThatSaysWhy() {
    let broken = jsonError("{not json")
    XCTAssertEqual(broken?.status, 400)
    XCTAssertTrue(broken?.message?.contains("not valid JSON") == true, broken?.message ?? "nil")
    let missing = jsonError(#"{"name": "Ada", "tags": []}"#)
    XCTAssertEqual(missing?.status, 400)
    XCTAssertTrue(missing?.message?.contains("age") == true, missing?.message ?? "nil")
    let wrongType = jsonError(#"{"name": "Ada", "age": "old"}"#)
    XCTAssertEqual(wrongType?.status, 400)
    XCTAssertTrue(wrongType?.message?.contains("age") == true, wrongType?.message ?? "nil")
    let nested = jsonError(#"{"name": "Ada", "age": 1, "tags": [1]}"#)
    XCTAssertTrue(nested?.message?.contains("tags") == true, nested?.message ?? "nil")
  }

  func testAnEmptyBodyIsABadRequest() {
    let error = jsonError("")
    XCTAssertEqual(error?.status, 400)
    XCTAssertTrue(error?.message?.contains("empty") == true, error?.message ?? "nil")
  }

  func testAJSONObjectOfAnyShape() throws {
    let object = try request(body: Array(#"{"a": [1, 2], "b": {"c": null}}"#.utf8)).jsonObject() as? [String: Any]
    XCTAssertEqual((object?["a"] as? [Int]) ?? [], [1, 2])
    XCTAssertNotNil(object?["b"])
    XCTAssertThrowsError(try request(body: Array("{".utf8)).jsonObject()) { error in
      XCTAssertEqual((error as? NanoHTTPError)?.status, 400)
    }
  }

  func testAHandlerThatDecodesJSONAnswersBadInputWith400() throws {
    try withTestServer(configure: { server in
      server.post["/people"] = { request in
        let person = try request.json(Person.self)
        return .ok(.text("\(person.name) is \(person.age)"))
      }
    }) { _, port in
      let good = try RawClient.request("POST", "/people", port: port, body: Array(#"{"name": "Ada", "age": 36}"#.utf8))
      XCTAssertEqual(good.bodyString, "Ada is 36")
      let bad = try RawClient.request("POST", "/people", port: port, body: Array(#"{"name": "Ada"}"#.utf8))
      XCTAssertEqual(bad.status, 400)
      XCTAssertTrue(bad.bodyString.contains("age"), bad.bodyString)
    }
  }
}

// MARK: - Routing with decoded values

final class DecodedRoutingTests: XCTestCase {

  private func route(_ router: NanoHTTPSegmentRouter, _ path: String) -> [String: String]? {
    return router.route("GET", path: path)?.0
  }

  private func router(_ patterns: String...) -> NanoHTTPSegmentRouter {
    let router = NanoHTTPSegmentRouter()
    for pattern in patterns {
      router.register("GET", path: pattern, handler: { _ in .ok(.text(pattern)) })
    }
    return router
  }

  func testVariablesAreDecoded() {
    let router = router("/users/:name")
    XCTAssertEqual(route(router, "/users/J%C3%B6rg%20M"), ["name": "Jörg M"])
    XCTAssertEqual(route(router, "/users/a+b"), ["name": "a+b"])
    XCTAssertEqual(route(router, "/users/a%2Bb"), ["name": "a+b"])
  }

  func testPathVariablesAreDecodedToo() {
    let router = router("/files/::path")
    XCTAssertEqual(route(router, "/files/a%20b/c.txt"), ["path": "a b/c.txt"])
    XCTAssertEqual(route(router, "/files/%C3%A9/%E2%82%AC"), ["path": "é/€"])
    XCTAssertEqual(route(router, "/files"), ["path": ""])
  }

  func testAnEncodedSlashDoesNotSplitASegment() {
    let router = router("/a/b", "/:one")
    XCTAssertEqual(route(router, "/a%2Fb"), ["one": "a/b"])
    XCTAssertEqual(route(router, "/a/b"), [:])
  }

  func testStaticSegmentsAreComparedDecoded() {
    let router = router("/café")
    XCTAssertNotNil(route(router, "/caf%C3%A9"))
    XCTAssertNotNil(route(router, "/caf%c3%a9"))
    XCTAssertNil(route(router, "/cafe"))
  }

  func testAnInvalidEncodingMatchesNothing() {
    let router = router("/users/:name", "/files/::path")
    XCTAssertNil(route(router, "/users/%zz"))
    XCTAssertNil(route(router, "/users/%FF"))
    XCTAssertNil(route(router, "/files/a/%zz"))
  }

  func testAPercentSignThatIsEncodedTwiceIsDecodedOnce() {
    let router = router("/users/:name", "/files/::path")
    XCTAssertEqual(route(router, "/users/%252e%252e"), ["name": "%2e%2e"])
    XCTAssertEqual(route(router, "/files/%252e%252e/x"), ["path": "%2e%2e/x"])
  }

  // MARK: Through a server

  func testHandlersSeeDecodedValues() throws {
    try withTestServer(configure: { server in
      server.get["/echo/:name/::rest"] = { request in
        .ok(.text([request.path,
                   request.rawPath,
                   request.params["name"] ?? "-",
                   request.params["rest"] ?? "-",
                   request.query("q") ?? "-",
                   request.query("plus") ?? "-"].joined(separator: "|")))
      }
    }) { _, port in
      let response = try RawClient.get("/echo/J%C3%B6rg/a%20b/c?q=x%20y&plus=1+1", port: port)
      XCTAssertEqual(response.bodyString,
                     "/echo/Jörg/a b/c|/echo/J%C3%B6rg/a%20b/c|Jörg|a b/c|x y|1 1")
    }
  }

  func testTheNotFoundHandlerSeesTheDecodedPath() throws {
    try withTestServer(configure: { server in
      server.notFoundHandler = { request in .notFound(.text(request.path)) }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/no%20such/%C3%A9", port: port).bodyString, "/no such/é")
    }
  }

  // MARK: Files: decoded once

  private func withDirectory(_ body: (String) throws -> Void) throws {
    let directory = NSTemporaryDirectory() + "nanohttp-semantics-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory + "/sub dir", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try "plain".write(toFile: directory + "/a b.txt", atomically: true, encoding: .utf8)
    try "inner".write(toFile: directory + "/sub dir/é.txt", atomically: true, encoding: .utf8)
    try "%2e%2e".write(toFile: directory + "/%2e%2e", atomically: true, encoding: .utf8) // a file called "%2e%2e"
    try body(directory)
  }

  func testFileNamesWithSpecialCharactersAreServed() throws {
    try withDirectory { directory in
      try withTestServer(configure: { server in
        server["/files/::path"] = share(directory: directory)
        server["/browse/::path"] = browse(directory: directory)
      }) { _, port in
        XCTAssertEqual(try RawClient.get("/files/a%20b.txt", port: port).bodyString, "plain")
        XCTAssertEqual(try RawClient.get("/files/sub%20dir/%C3%A9.txt", port: port).bodyString, "inner")
        XCTAssertEqual(try RawClient.get("/browse/sub%20dir/%C3%A9.txt", port: port).bodyString, "inner")
      }
    }
  }

  /// A path is decoded once. If it was decoded twice, `%252e%252e` would become `..`.
  func testAFileNameIsNotDecodedTwice() throws {
    try withDirectory { directory in
      try withTestServer(configure: { server in
        server["/files/::path"] = share(directory: directory)
        server["/browse/::path"] = browse(directory: directory)
      }) { _, port in
        // `%252e%252e` is the name "%2e%2e": the file that was created above, not a way out of the directory.
        XCTAssertEqual(try RawClient.get("/files/%252e%252e", port: port).bodyString, "%2e%2e")
        XCTAssertEqual(try RawClient.get("/browse/%252e%252e", port: port).bodyString, "%2e%2e")
        // `%2e%2e` is `..`, which is refused as before.
        XCTAssertEqual(try RawClient.get("/files/%2e%2e/etc/hosts", port: port).status, 403)
        XCTAssertEqual(try RawClient.get("/files/%252e%252e/%252e%252e/etc/hosts", port: port).status, 404)
        XCTAssertEqual(try RawClient.get("/files/sub%2520dir/x", port: port).status, 404)
      }
    }
  }

  func testTheLinksOfAListingAreEncodedAndRelativeToTheRawPath() throws {
    try withDirectory { directory in
      try withTestServer(configure: { server in
        server["/browse/::path"] = browse(directory: directory)
      }) { _, port in
        let listing = try RawClient.get("/browse/sub%20dir", port: port).bodyString
        // (The file system may store the é as e and a combining accent, which the listing then shows.)
        XCTAssertTrue(listing.contains("href=\"/browse/sub%20dir/%C3%A9.txt\"") ||
                      listing.contains("href=\"/browse/sub%20dir/e%CC%81.txt\""), listing)
        let root = try RawClient.get("/browse/", port: port).bodyString
        XCTAssertTrue(root.contains("href=\"/browse/sub%20dir\""), root)
        XCTAssertTrue(root.contains("href=\"/browse/a%20b.txt\""), root)
      }
    }
  }

  // MARK: Middleware

  func testMiddlewareCanRewriteThePathBeforeRouting() throws {
    try withTestServer(configure: { server in
      server.get["/new/:name"] = { request in .ok(.text("new \(request.params["name"] ?? "?")")) }
      server.middleware.append { request, next in
        if request.path.hasPrefix("/old/") {
          request.path = "/new/" + request.path.dropFirst(5) // decoded text in, encoded for routing
        }
        return try next(request)
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/old/a%20b", port: port).bodyString, "new a b")
    }
  }
}
