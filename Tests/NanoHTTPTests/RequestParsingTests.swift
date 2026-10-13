//
//  RequestParsingTests.swift
//  NanoHTTPTests
//
//  Unit tests for request parsing and the request helpers (query, headers, url-encoded forms,
//  multipart), covering findings H1–H3 and H9 of the assessment plan. Requests are fed to the
//  real `NanoHTTPParser` through a `FileSocket`, so no network is involved.
//

import XCTest
@testable import NanoHTTP

private func parse(_ text: String) throws -> NanoHTTPRequest {
  return try NanoHTTPParser(socket: FileSocket(text)).readHttpRequest()
}

private func parse(target: String) throws -> NanoHTTPRequest {
  return try parse("GET \(target) HTTP/1.1\r\n\r\n")
}

// MARK: - Request line, query and path

final class RequestLineTests: XCTestCase {

  func testMethodPathAndHeaders() throws {
    let request = try parse("POST /a/b HTTP/1.1\r\nHost: example\r\nX-Custom:  value \r\nContent-Length: 3\r\n\r\nabc")
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/a/b")
    XCTAssertEqual(request.header("host"), "example")
    XCTAssertEqual(request.header("X-CUSTOM"), "value") // case-insensitive name, value trimmed
    XCTAssertEqual(request.body, Array("abc".utf8))
  }

  func testQueryParametersKeepOrderAndDuplicates() throws {
    let request = try parse(target: "/s?b=2&a=1&a=3")
    XCTAssertEqual(request.queryParams.map { "\($0.0)=\($0.1)" }, ["b=2", "a=1", "a=3"])
  }

  func testPathIsKeptPercentEncoded() throws {
    // Router and file handlers decode path segments themselves, so `path` must stay raw.
    // Documented invariant, pinned here. (See H1: query values should NOT stay raw.)
    let request = try parse(target: "/a%20b/%C3%A9?x=1")
    XCTAssertEqual(request.path, "/a%20b/%C3%A9")
  }

  func testQueryValuesArePercentDecoded() throws {
    let request = try parse(target: "/s?q=hello%20world&e=%E2%82%AC")
    expectKnownIssue("H1", "query values keep their percent-encoding") {
      XCTAssertEqual(request.queryParams.first { $0.0 == "q" }?.1, "hello world")
      XCTAssertEqual(request.queryParams.first { $0.0 == "e" }?.1, "€")
    }
  }

  func testPlusInQueryValueMeansSpace() throws {
    let request = try parse(target: "/s?q=a+b")
    expectKnownIssue("H1", "'+' is not translated to a space in query values") {
      XCTAssertEqual(request.queryParams.first { $0.0 == "q" }?.1, "a b")
    }
  }

  func testQueryValueMayContainQuestionMarkAndColon() throws {
    let request = try parse(target: "/open?link=https://www.youtube.com/watch?v=D2cUBG4PnOA")
    XCTAssertEqual(request.queryParams.first?.1, "https://www.youtube.com/watch?v=D2cUBG4PnOA")
  }
}

// MARK: - Headers

final class HeaderParsingTests: XCTestCase {

  func testHeaderValueMayContainColons() throws {
    let request = try parse("GET / HTTP/1.1\r\nX-Time: 12:30:45\r\n\r\n")
    XCTAssertEqual(request.header("x-time"), "12:30:45")
  }

  func testEmptyHeaderValueIsEmptyString() throws {
    let request = try parse("GET / HTTP/1.1\r\nX-Empty:\r\nX-Next: 1\r\n\r\n")
    XCTAssertEqual(request.header("x-next"), "1")
    expectKnownIssue("H3", "an empty header value comes back as the header NAME") {
      XCTAssertEqual(request.header("x-empty"), "")
    }
  }

  func testLineWithoutColonIsIgnored() throws {
    let request = try parse("GET / HTTP/1.1\r\ngarbage\r\nX-Next: 1\r\n\r\n")
    expectKnownIssue("H3", "a colon-less line becomes a header whose value is its own name") {
      XCTAssertNil(request.header("garbage"))
    }
  }

  func testRepeatedHeadersAreCombined() throws {
    let request = try parse("GET / HTTP/1.1\r\nAccept: text/html\r\nAccept: application/json\r\n\r\n")
    expectKnownIssue("H3", "the last of several same-named headers silently wins") {
      XCTAssertEqual(request.header("accept"), "text/html, application/json")
    }
  }

  func testHeaderNameIsTrimmed() throws {
    let request = try parse("GET / HTTP/1.1\r\nX-Spaced : 1\r\n\r\n")
    expectKnownIssue("H3", "whitespace before the colon becomes part of the header name") {
      XCTAssertEqual(request.header("x-spaced"), "1")
    }
  }

  func testHasTokenForHeaderRequiresLowercaseToken() throws {
    // Quirk, not a defect: the header side is lowercased, the `token` argument is not.
    let request = try parse("GET / HTTP/1.1\r\nConnection: keep-alive, Upgrade\r\n\r\n")
    XCTAssertTrue(request.hasTokenForHeader("connection", token: "upgrade"))
    XCTAssertFalse(request.hasTokenForHeader("connection", token: "Upgrade"))
  }

  func testSupportsKeepAliveNeedsTheExplicitHeader() throws {
    XCTAssertTrue(try parse("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n").supportsKeepAlive)
    XCTAssertFalse(try parse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n").supportsKeepAlive)
    // Pinned current behavior; the HTTP/1.1 default is the opposite (finding H4).
    XCTAssertFalse(try parse("GET / HTTP/1.1\r\n\r\n").supportsKeepAlive)
  }
}

// MARK: - application/x-www-form-urlencoded

final class UrlencodedFormTests: XCTestCase {

  private func form(_ body: String, contentType: String = "application/x-www-form-urlencoded") -> NanoHTTPRequest {
    return NanoHTTPRequest(method: "POST", path: "/",
                           headers: ["Content-Type": contentType],
                           body: Array(body.utf8))
  }

  private func fields(_ request: NanoHTTPRequest) -> [String: String] {
    return Dictionary(request.parseUrlencodedForm(), uniquingKeysWith: { _, last in last })
  }

  func testBasicFields() {
    XCTAssertEqual(fields(form("name=John+Doe&city=Z%C3%BCrich&empty=")),
                   ["name": "John Doe", "city": "Zürich", "empty": ""])
  }

  func testCharsetParameterInContentTypeIsAccepted() {
    XCTAssertEqual(fields(form("a=1", contentType: "application/x-www-form-urlencoded; charset=UTF-8")), ["a": "1"])
  }

  func testOtherContentTypesYieldNothing() {
    XCTAssertTrue(form("a=1", contentType: "text/plain").parseUrlencodedForm().isEmpty)
  }

  func testEncodedPlusIsAPlusNotASpace() {
    let parsed = fields(form("a=1%2B1"))
    expectKnownIssue("H2", "'%' is decoded before '+', so %2B turns into a space") {
      XCTAssertEqual(parsed["a"], "1+1")
    }
  }

  func testUnencodedEqualsSignInValueIsKept() {
    let parsed = fields(form("token=abc==&x=1"))
    expectKnownIssue("H2", "pairs whose value contains '=' (e.g. base64 padding) are dropped") {
      XCTAssertEqual(parsed["token"], "abc==")
    }
  }

  func testMalformedPairIsSkippedNotInventedAsEmptyField() {
    let parsed = form("a=1&oops&b=2").parseUrlencodedForm()
    expectKnownIssue("H2", "a pair without '=' becomes a bogus ('', '') entry") {
      XCTAssertEqual(parsed.count, 2)
    }
  }
}

// MARK: - multipart/form-data

final class MultipartTests: XCTestCase {

  private func multipart(_ parts: [String], boundary: String = "XyZ") -> NanoHTTPRequest {
    let body = parts.map { "--\(boundary)\r\n\($0)\r\n" }.joined() + "--\(boundary)--\r\n"
    return NanoHTTPRequest(method: "POST", path: "/",
                           headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
                           body: Array(body.utf8))
  }

  func testTextFieldAndFile() {
    let request = multipart([
      "Content-Disposition: form-data; name=\"title\"\r\n\r\nHello",
      "Content-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nline1\r\nline2"
    ])
    let parts = request.parseMultiPartFormData()
    XCTAssertEqual(parts.count, 2)
    XCTAssertEqual(parts[0].name, "title")
    XCTAssertEqual(String(decoding: parts[0].body, as: UTF8.self), "Hello")
    XCTAssertEqual(parts[1].name, "upload")
    XCTAssertEqual(parts[1].fileName, "a.txt")
    XCTAssertEqual(parts[1].headers["content-type"], "text/plain")
    XCTAssertEqual(String(decoding: parts[1].body, as: UTF8.self), "line1\r\nline2")
  }

  func testBinaryBodyIsPreserved() {
    var body = Array("--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.bin\"\r\n\r\n".utf8)
    let payload: [UInt8] = [0, 1, 2, 13, 10, 45, 45, 255, 254, 13, 10, 45] // includes CRLF and "--"
    body += payload
    body += Array("\r\n--B--\r\n".utf8)
    let request = NanoHTTPRequest(method: "POST", path: "/",
                                  headers: ["Content-Type": "multipart/form-data; boundary=B"], body: body)
    XCTAssertEqual(request.parseMultiPartFormData().first?.body, payload)
  }

  func testNonMultipartRequestYieldsNothing() {
    let request = NanoHTTPRequest(method: "POST", path: "/", headers: ["Content-Type": "text/plain"], body: [1, 2])
    XCTAssertTrue(request.parseMultiPartFormData().isEmpty)
  }

  func testFieldNameMayContainAColon() {
    let request = multipart(["Content-Disposition: form-data; name=\"a:b\"\r\n\r\nv"])
    expectKnownIssue("H9", "a header line with more than one ':' is dropped, so the part has no name") {
      XCTAssertEqual(request.parseMultiPartFormData().first?.name, "a:b")
    }
  }

  func testFileNameMayContainASemicolon() {
    let request = multipart(["Content-Disposition: form-data; name=\"f\"; filename=\"a;b.txt\"\r\n\r\nv"])
    expectKnownIssue("H9", "parameters are split at every ';' even inside quotes") {
      XCTAssertEqual(request.parseMultiPartFormData().first?.fileName, "a;b.txt")
    }
  }

  func testFileNameMayContainAnEqualsSign() {
    let request = multipart(["Content-Disposition: form-data; name=\"f\"; filename=\"a=b.txt\"\r\n\r\nv"])
    expectKnownIssue("H9", "parameters are split at every '=' even inside quotes") {
      XCTAssertEqual(request.parseMultiPartFormData().first?.fileName, "a=b.txt")
    }
  }

  func testQuotedBoundaryIsAccepted() {
    let request = NanoHTTPRequest(
      method: "POST", path: "/",
      headers: ["Content-Type": "multipart/form-data; boundary=\"q q\""],
      body: Array("--q q\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--q q--\r\n".utf8))
    expectKnownIssue("H9", "a quoted boundary parameter is not unquoted") {
      XCTAssertEqual(request.parseMultiPartFormData().count, 1)
    }
  }
}
