//
//  MultipartParserTests.swift
//  NanoHTTPTests
//
//  The parser of `multipart/form-data` bodies (finding H9): it works on the bytes, so a part keeps every byte that is
//  not the line break before the next boundary, boundary lookalikes in the content do not end a part, header lines can
//  have colons and continuations, parameters can have quotes with `;`, `=` and `:` in them, and a body that is not
//  well-formed is refused as a whole. A property test writes random parts (full of line breaks and dashes) and reads them
//  again; a fuzz test feeds random bytes.
//

import XCTest
@testable import NanoHTTP

private func bytes(_ text: String) -> [UInt8] {
  return Array(text.utf8)
}

private func string(_ bytes: [UInt8]) -> String {
  return String(decoding: bytes, as: UTF8.self)
}

private func request(_ body: [UInt8],
                     boundary: String = "XyZ",
                     contentType: String? = nil,
                     parts maxParts: Int = 1000,
                     headerBytes maxHeaderBytes: Int = 16 * 1024) -> NanoHTTPRequest {
  let request = NanoHTTPRequest(method: "POST",
                                path: "/",
                                headers: ["Content-Type": contentType ?? "multipart/form-data; boundary=\(boundary)"],
                                body: body)
  request.multipartLimits = (maxParts, maxHeaderBytes)
  return request
}

private func request(_ text: String, boundary: String = "XyZ") -> NanoHTTPRequest {
  return request(bytes(text), boundary: boundary)
}

private func field(_ name: String, _ value: String, boundary: String = "XyZ") -> String {
  return "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
}

final class MultipartParserTests: XCTestCase {

  // MARK: Structure

  func testAnOrdinaryFormWithTwoFieldsAndAFile() {
    let body = field("a", "1") + field("b", "two words") +
               "--XyZ\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.txt\"\r\nContent-Type: text/plain\r\n\r\nline 1\r\nline 2\r\n" +
               "--XyZ--\r\n"
    let parts = request(body).parseMultiPartFormData()
    XCTAssertEqual(parts.map { $0.name }, ["a", "b", "f"])
    XCTAssertEqual(parts.map { string($0.body) }, ["1", "two words", "line 1\r\nline 2"])
    XCTAssertEqual(parts[2].fileName, "x.txt")
    XCTAssertEqual(parts[2].headers["content-type"], "text/plain")
    XCTAssertNil(parts[0].fileName)
  }

  func testAnEmptyFormHasNoParts() {
    XCTAssertEqual(request("--XyZ--\r\n").parseMultiPartFormData().count, 0)
  }

  func testTextBeforeTheFirstAndAfterTheClosingBoundaryIsIgnored() {
    let body = "This is a multipart message.\r\nIgnore this.\r\n" + field("a", "1") + "--XyZ--\r\nAnd this: --XyZ\r\nToo.\r\n"
    let parts = request(body).parseMultiPartFormData()
    XCTAssertEqual(parts.map { string($0.body) }, ["1"])
  }

  func testLineFeedsAloneAreAcceptedAsLineBreaks() {
    let body = "--XyZ\nContent-Disposition: form-data; name=\"a\"\n\nline 1\nline 2\n--XyZ\nContent-Disposition: form-data; name=\"b\"\n\nv\n--XyZ--\n"
    let parts = request(body).parseMultiPartFormData()
    XCTAssertEqual(parts.map { $0.name }, ["a", "b"])
    XCTAssertEqual(parts.map { string($0.body) }, ["line 1\nline 2", "v"])
  }

  func testBlanksAfterABoundaryAreAllowed() {
    let body = "--XyZ  \t\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--XyZ \r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--XyZ-- \r\n"
    XCTAssertEqual(request(body).parseMultiPartFormData().map { string($0.body) }, ["1", "2"])
  }

  func testAClosingBoundaryWithoutTheDashesAtTheEndOfTheBodyIsAccepted() {
    let body = field("a", "1") + "--XyZ"
    XCTAssertEqual(request(body).parseMultiPartFormData().map { string($0.body) }, ["1"])
  }

  func testAPartMayBeEmptyWithOneTwoOrThreeLineBreaksBeforeTheNextBoundary() {
    let three = "--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n\r\n--XyZ\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nB\r\n--XyZ--"
    let two = "--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n--XyZ\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nB\r\n--XyZ--"
    for body in [three, two] {
      let parts = request(body).parseMultiPartFormData()
      XCTAssertEqual(parts.map { $0.name }, ["a", "b"], body)
      XCTAssertEqual(parts.map { string($0.body) }, ["", "B"], body)
    }
  }

  func testAPartWithoutHeaders() {
    let parts = request("--XyZ\r\n\r\nbody\r\n--XyZ--\r\n").parseMultiPartFormData()
    XCTAssertEqual(parts.count, 1)
    XCTAssertEqual(string(parts[0].body), "body")
    XCTAssertTrue(parts[0].headers.isEmpty)
    XCTAssertNil(parts[0].name)
  }

  func testAnAbsentBodyAndOtherContentTypesGiveNothing() {
    XCTAssertEqual(request([]).parseMultiPartFormData().count, 0)
    XCTAssertEqual(request(bytes(field("a", "1") + "--XyZ--"), contentType: "text/plain").parseMultiPartFormData().count, 0)
    XCTAssertEqual(request(bytes(field("a", "1") + "--XyZ--"), contentType: "multipart/form-data").parseMultiPartFormData().count, 0)
    XCTAssertEqual(request(bytes(field("a", "1") + "--XyZ--"), contentType: "multipart/form-data; boundary=").parseMultiPartFormData().count, 0)
    let noHeader = NanoHTTPRequest(method: "POST", path: "/", body: bytes(field("a", "1") + "--XyZ--"))
    XCTAssertEqual(noHeader.parseMultiPartFormData().count, 0)
  }

  func testTheMediaTypeIsMatchedWithoutRegardToCaseAndTheBoundaryMayBeQuoted() {
    let body = bytes("--a b\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nv\r\n--a b--\r\n")
    XCTAssertEqual(request(body, contentType: "Multipart/Form-Data; Boundary=\"a b\"").parseMultiPartFormData().count, 1)
    XCTAssertEqual(request(body, contentType: "multipart/form-data;charset=utf-8; boundary=\"a b\"; x=y").parseMultiPartFormData().count, 1)
    let odd = bytes("--'()+_,-./:=?\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nv\r\n--'()+_,-./:=?--\r\n")
    XCTAssertEqual(request(odd, contentType: "multipart/form-data; boundary=\"'()+_,-./:=?\"").parseMultiPartFormData().count, 1)
  }

  // MARK: Content

  func testBoundaryLookalikesInTheContentDoNotEndThePart() {
    let content = "a\r\n--XyZk\r\nb\r\n--Xy\r\nc\r\n-- XyZ\r\nd\r\n--XyZ-x\r\ne"
    let parts = request(field("a", content) + "--XyZ--").parseMultiPartFormData()
    XCTAssertEqual(parts.count, 1)
    XCTAssertEqual(string(parts.first?.body ?? []), content)
  }

  func testNoByteOfTheContentIsDropped() {
    // Every byte value, including the control characters that an earlier version of the parser dropped.
    let payload = (0...255).map { UInt8($0) } + [13, 10, 13, 10, 45, 45, 13, 10, 0, 13]
    var body = bytes("--XyZ\r\nContent-Disposition: form-data; name=\"f\"; filename=\"all.bin\"\r\n\r\n")
    body += payload
    body += bytes("\r\n--XyZ--\r\n")
    XCTAssertEqual(request(body).parseMultiPartFormData().first?.body, payload)
  }

  func testAContentThatEndsWithACarriageReturnKeepsIt() {
    // The line break before the boundary is CR LF: a CR that is part of the content stays if there is a line break too.
    let parts = request(bytes("--XyZ\r\n\r\nabc\r\r\n--XyZ--")).parseMultiPartFormData()
    XCTAssertEqual(parts.first?.body, bytes("abc\r"))
  }

  // MARK: Headers

  func testHeaders() {
    let body = "--XyZ\r\n" +
               "Content-Disposition: form-data; name=\"a:b\"\r\n" +
               "content-TYPE:   text/plain; note=\"x:y\"  \r\n" +
               "X-Folded: first\r\n  second\r\n\tthird\r\n" +
               "X-Twice: 1\r\n" +
               "x-twice: 2\r\n" +
               "garbage without a colon\r\n" +
               ": no name\r\n" +
               "\r\nbody\r\n--XyZ--"
    let part = request(body).parseMultiPartFormData().first
    XCTAssertEqual(part?.name, "a:b")
    XCTAssertEqual(part?.headers["content-type"], "text/plain; note=\"x:y\"")
    XCTAssertEqual(part?.headers["x-folded"], "first second third")
    XCTAssertEqual(part?.headers["x-twice"], "1, 2")
    XCTAssertEqual(part?.headers.count, 4)
  }

  func testNonASCIIHeaderValuesAreReadAsUTF8() {
    let part = request(field("a", "v").replacingOccurrences(of: "name=\"a\"", with: "name=\"a\"; filename=\"Grüße €.txt\"") + "--XyZ--").parseMultiPartFormData().first
    XCTAssertEqual(part?.fileName, "Grüße €.txt")
  }

  // MARK: Parameters

  private func disposition(_ parameters: String) -> NanoHTTPRequest.MultiPart? {
    return request("--XyZ\r\nContent-Disposition: form-data; \(parameters)\r\n\r\nv\r\n--XyZ--").parseMultiPartFormData().first
  }

  func testQuotedParametersMayContainSemicolonsEqualsSignsAndColons() {
    let part = disposition("name=\"a;b=c:d\"; filename=\"x; y=z.txt\"")
    XCTAssertEqual(part?.name, "a;b=c:d")
    XCTAssertEqual(part?.fileName, "x; y=z.txt")
  }

  func testEscapedQuotesAndBackslashesInQuotedParameters() {
    XCTAssertEqual(disposition("name=\"a\\\"b\"")?.name, "a\"b")
    XCTAssertEqual(disposition("name=\"a\\\\b\"")?.name, "a\\b")
    // Other backslashes stay: a Windows path.
    XCTAssertEqual(disposition("name=\"f\"; filename=\"C:\\dir\\file.txt\"")?.fileName, "C:\\dir\\file.txt")
    // Only what is inside the quotes counts.
    XCTAssertEqual(disposition("name=\"a\" garbage; filename=\"b\"")?.name, "a")
  }

  func testParametersWithoutQuotesBlanksAndTheOrderOfParameters() {
    XCTAssertEqual(disposition("name=field")?.name, "field")
    XCTAssertEqual(disposition("  name = \"spaced\"  ;   filename =x.txt")?.name, "spaced")
    XCTAssertEqual(disposition("  name = \"spaced\"  ;   filename =x.txt")?.fileName, "x.txt")
    XCTAssertEqual(disposition("filename=\"f.txt\"; name=\"n\"")?.name, "n")
    XCTAssertEqual(disposition("NAME=\"upper\"")?.name, "upper")
    XCTAssertEqual(disposition("name=\"n\"; filename=\"\"")?.fileName, "")
    XCTAssertNil(disposition("name=\"n\"")?.fileName)
    XCTAssertNil(disposition("form-data")?.name)
  }

  func testTheExtendedFormOfAFileNameTakesPrecedence() {
    XCTAssertEqual(disposition("name=\"f\"; filename=\"fallback.txt\"; filename*=UTF-8''%E2%82%AC%20rates.txt")?.fileName, "€ rates.txt")
    XCTAssertEqual(disposition("name=\"f\"; filename*=iso-8859-1'en'caf%E9.txt")?.fileName, "café.txt")
    XCTAssertEqual(disposition("name*=UTF-8''na%C3%AFve; filename=\"x\"")?.name, "naïve")
    // What cannot be decoded is ignored: the plain parameter is used.
    XCTAssertEqual(disposition("name=\"f\"; filename=\"plain.txt\"; filename*=UTF-8''%E2%82")?.fileName, "plain.txt")
    XCTAssertEqual(disposition("name=\"f\"; filename=\"plain.txt\"; filename*=KOI8-R''x")?.fileName, "plain.txt")
    XCTAssertEqual(disposition("name=\"f\"; filename=\"plain.txt\"; filename*=nonsense")?.fileName, "plain.txt")
  }

  // MARK: Refused bodies and limits

  func testABodyThatIsNotWellFormedIsRefusedAsAWhole() {
    let first = field("a", "1")
    XCTAssertEqual(request(first + field("b", "2") + "--XyZ--").parseMultiPartFormData().count, 2)
    // No closing boundary: the second part has no end.
    XCTAssertEqual(request(first + "--XyZ\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2").parseMultiPartFormData().count, 0)
    // Another boundary than the one of the Content-Type.
    XCTAssertEqual(request(first + "--XyZ--", boundary: "Other").parseMultiPartFormData().count, 0)
    // Headers that are not followed by an empty line.
    XCTAssertEqual(request("--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\nvalue").parseMultiPartFormData().count, 0)
    // The boundary line is cut off in the middle of its dashes, or by something that is no line break.
    XCTAssertEqual(request(first + "--XyZ-").parseMultiPartFormData().count, 0)
    XCTAssertEqual(request(first + "--XyZ\rContent").parseMultiPartFormData().count, 0)
    // No boundary at all.
    XCTAssertEqual(request("hello, this is no form").parseMultiPartFormData().count, 0)
  }

  func testTooManyPartsAreRefused() {
    let body = bytes((0..<10).map { field("f\($0)", "v") }.joined() + "--XyZ--")
    XCTAssertEqual(request(body, parts: 10).parseMultiPartFormData().count, 10)
    XCTAssertEqual(request(body, parts: 9).parseMultiPartFormData().count, 0)
    // A body of empty parts is the worst case: three bytes of content for a part with headers of its own.
    let empty = bytes(String(repeating: "--XyZ\r\n\r\n\r\n", count: 5000) + "--XyZ--")
    XCTAssertEqual(request(empty).parseMultiPartFormData().count, 0, "more than the default of 1000 parts")
    XCTAssertEqual(request(empty, parts: 5000).parseMultiPartFormData().count, 5000)
  }

  func testHeadersThatAreTooLongAreRefused() {
    let header = "X-Long: " + String(repeating: "x", count: 100)
    let body = "--XyZ\r\n" + header + "\r\n\r\nv\r\n--XyZ--"
    XCTAssertEqual(request(bytes(body), headerBytes: 200).parseMultiPartFormData().count, 1)
    XCTAssertEqual(request(bytes(body), headerBytes: 100).parseMultiPartFormData().count, 0)
    // An endless header block does not need a body that is large.
    let endless = "--XyZ\r\n" + String(repeating: "X-Header: value\r\n", count: 100_000)
    XCTAssertEqual(request(endless).parseMultiPartFormData().count, 0)
  }

  // MARK: Properties

  /// A generator of random numbers that gives the same sequence for the same seed.
  private struct Generator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
      self.state &+= 0x9E3779B97F4A7C15
      var z = self.state
      z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
      z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
      return z ^ (z >> 31)
    }
  }

  private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else {
      return false
    }
    for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
      return true
    }
    return false
  }

  func testWhatIsWrittenCanBeReadAgain() {
    var random = Generator(state: 20261014)
    let alphabet: [UInt8] = [13, 10, 45, 45, 45, 13, 10, 0, 255, 65, 66, 67, UInt8(ascii: ":"), UInt8(ascii: ";"),
                             UInt8(ascii: "\""), 32, 9]
    for round in 0..<400 {
      let boundary = String((0..<Int.random(in: 1...12, using: &random)).map {
        _ in "ABC-_xyz019".randomElement(using: &random)!
      })
      let delimiter = bytes("\n--" + boundary)
      var parts = [(name: String, body: [UInt8])]()
      for index in 0..<Int.random(in: 0...6, using: &random) {
        var content = [UInt8]()
        for _ in 0..<Int.random(in: 0...60, using: &random) {
          if Bool.random(using: &random) {
            content.append(alphabet.randomElement(using: &random)!)
          } else if Int.random(in: 0..<20, using: &random) == 0 {
            content += bytes("\r\n--" + boundary.prefix(Int.random(in: 0...boundary.count, using: &random))) // a lookalike
          } else {
            content.append(UInt8.random(in: 0...255, using: &random))
          }
        }
        // The one thing that cannot be written: the whole boundary line inside the content.
        if self.contains(content, delimiter) || content.starts(with: bytes("--" + boundary)) {
          continue
        }
        parts.append(("part\(index)", content))
      }
      var body = [UInt8]()
      for part in parts {
        body += bytes("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.name)\"\r\n\r\n")
        body += part.body
        body += bytes("\r\n")
      }
      body += bytes("--\(boundary)--\r\n")
      let read = request(body, boundary: boundary).parseMultiPartFormData()
      XCTAssertEqual(read.map { $0.name ?? "?" }, parts.map { $0.name }, "round \(round), boundary \(boundary)")
      XCTAssertEqual(read.map { $0.body }, parts.map { $0.body }, "round \(round), boundary \(boundary)")
      if read.count != parts.count {
        return
      }
    }
  }

  func testRandomBytesNeverTrapAndNeverYieldMoreThanTheBodyHolds() {
    var random = Generator(state: 7)
    let fragments: [[UInt8]] = [
      bytes("--B"), bytes("--B--"), bytes("\r\n"), bytes("\n"), bytes("\r"), bytes("--"), bytes("-"), bytes("B"),
      bytes("Content-Disposition: form-data; name=\"x\""), bytes(": "), bytes(";"), bytes("="), bytes("\""), bytes("\\"),
      bytes(" "), bytes("\t"), bytes("\r\n\r\n"), [0], [255], [0xE2, 0x82]
    ]
    for _ in 0..<4000 {
      var body = [UInt8]()
      for _ in 0..<Int.random(in: 0...40, using: &random) {
        if Int.random(in: 0..<5, using: &random) == 0 {
          body.append(UInt8.random(in: 0...255, using: &random))
        } else {
          body += fragments.randomElement(using: &random)!
        }
      }
      let parts = request(body, boundary: "B").parseMultiPartFormData()
      XCTAssertLessThanOrEqual(parts.reduce(0) { $0 + $1.body.count }, body.count)
      _ = parts.map { ($0.name, $0.fileName) } // the parameters of whatever headers came out
    }
  }

  func testALargeUploadIsReadExactlyAndQuickly() {
    let pattern: [UInt8] = [0, 1, 2, 13, 10, 45, 45, 255, 254, 13, 10, 45, 120, 89, 90, 45]
    var content = [UInt8]()
    content.reserveCapacity(8 * 1024 * 1024)
    for _ in 0..<(8 * 1024 * 1024 / pattern.count) {
      content += pattern
    }
    var body = bytes("--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue a\r\n")
    body += bytes("--XyZ\r\nContent-Disposition: form-data; name=\"f\"; filename=\"big.bin\"\r\n\r\n")
    body += content
    body += bytes("\r\n--XyZ\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nvalue b\r\n--XyZ--\r\n")
    let begin = Date()
    let parts = request(body).parseMultiPartFormData()
    XCTAssertLessThan(Date().timeIntervalSince(begin), 5, "8 MB")
    XCTAssertEqual(parts.map { $0.name }, ["a", "f", "b"])
    XCTAssertEqual(parts[1].body.count, content.count)
    XCTAssertTrue(parts[1].body == content)
  }
}

// MARK: - Through a server

final class MultipartServerTests: XCTestCase {

  func testTheLimitsOfTheServerReachTheParser() throws {
    for threading in [NanoHTTPServerIO.Configuration.Threading.perConnection, .singleThread] {
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.configuration.limits.maxMultipartParts = 2
        server.post["/upload"] = { request in
          let parts = request.parseMultiPartFormData()
          return .ok(.text(parts.map { $0.name ?? "?" }.joined(separator: ",") + ";\(parts.count)"))
        }
      }) { _, port in
        func post(_ names: [String]) throws -> String {
          let body = bytes(names.map { field($0, "v") }.joined() + "--XyZ--\r\n")
          let response = try RawClient.request("POST", "/upload", port: port,
                                               headers: ["Content-Type: multipart/form-data; boundary=XyZ",
                                                         "Connection: close"],
                                               body: body)
          return string(response.body)
        }
        XCTAssertEqual(try post(["a", "b"]), "a,b;2", "\(threading)")
        XCTAssertEqual(try post(["a", "b", "c"]), ";0", "\(threading): more parts than the limit")
      }
    }
  }
}
