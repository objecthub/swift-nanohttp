//
//  CookieTests.swift
//  NanoHTTPTests
//
//  Cookies: what a `Set-Cookie` header looks like (every attribute, the characters of values that are encoded),
//  which cookies the server refuses to send (names, paths and domains that would let a response add attributes or
//  headers), how the `Cookie` header of a request is read, and that a cookie survives the way to a browser and
//  back. Several cookies are several `Set-Cookie` lines.
//

import XCTest
@testable import NanoHTTP

private func cookieLines(_ response: NanoHTTPResponse,
                         dropped: ((String) -> Void)? = nil) -> [String] {
  let head = NanoHTTPResponseSerializer.head(response, framing: .none, droppedCookie: dropped ?? { _ in })
  return String(decoding: head, as: UTF8.self)
    .components(separatedBy: "\r\n")
    .filter { $0.hasPrefix("Set-Cookie: ") }
    .map { String($0.dropFirst("Set-Cookie: ".count)) }
}

private func line(_ cookie: NanoHTTPCookie) -> String? {
  return cookieLines(NanoHTTPResponse(statusCode: 200, cookies: [cookie])).first
}

final class CookieSerializationTests: XCTestCase {

  func testANewCookieHasTheSafeDefaults() {
    XCTAssertEqual(line(NanoHTTPCookie(name: "session", value: "abc")), "session=abc; Path=/; HttpOnly; SameSite=Lax")
  }

  func testEveryAttribute() {
    let cookie = NanoHTTPCookie(name: "id",
                                value: "7",
                                path: "/app",
                                domain: "example.org",
                                maxAge: 3600,
                                expires: Date(timeIntervalSince1970: 1_000_000_000),
                                secure: true,
                                httpOnly: true,
                                sameSite: .strict)
    XCTAssertEqual(line(cookie),
                   "id=7; Path=/app; Domain=example.org; Max-Age=3600; Expires=Sun, 09 Sep 2001 01:46:40 GMT; Secure; HttpOnly; SameSite=Strict")
  }

  func testTheAttributesThatAreSwitchedOffAreLeftOut() {
    let cookie = NanoHTTPCookie(name: "id", value: "7", path: nil, secure: false, httpOnly: false, sameSite: nil)
    XCTAssertEqual(line(cookie), "id=7")
    XCTAssertEqual(line(NanoHTTPCookie(name: "id", value: "7", path: nil, httpOnly: false, sameSite: .lax)), "id=7; SameSite=Lax")
    XCTAssertEqual(line(NanoHTTPCookie(name: "id", value: "7", path: nil, httpOnly: false, sameSite: .unrestricted)),
                   "id=7; SameSite=None")
  }

  func testAMaximumAgeBelowZeroIsZero() {
    XCTAssertEqual(line(NanoHTTPCookie(name: "a", value: "1", path: nil, maxAge: -5, httpOnly: false, sameSite: nil)),
                   "a=1; Max-Age=0")
  }

  func testAnExpiredCookieDeletesTheCookieOfTheSameNamePathAndDomain() {
    XCTAssertEqual(line(.expired(name: "session")),
                   "session=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
    XCTAssertEqual(line(.expired(name: "session", path: "/app", domain: "example.org")),
                   "session=; Path=/app; Domain=example.org; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
    var response = NanoHTTPResponse.ok(.text("bye"))
    response.setCookie(NanoHTTPCookie(name: "session", value: "abc"))
    response.deleteCookie(named: "session")
    XCTAssertEqual(response.cookies.count, 1, "the deleting cookie replaces the cookie of the same name, path and domain")
    XCTAssertEqual(response.cookies.first?.maxAge, 0)
  }

  func testSettingACookieReplacesTheOneWithTheSameNamePathAndDomain() {
    var response = NanoHTTPResponse.ok(.text("x"))
    response.setCookie(NanoHTTPCookie(name: "a", value: "1"))
    response.setCookie(NanoHTTPCookie(name: "a", value: "2"))
    response.setCookie(NanoHTTPCookie(name: "a", value: "3", path: "/other"))
    response.setCookie(NanoHTTPCookie(name: "a", value: "4", domain: "example.org"))
    response.setCookie(NanoHTTPCookie(name: "b", value: "5"))
    XCTAssertEqual(response.cookies.map { "\($0.name)=\($0.value)" }, ["a=2", "a=3", "a=4", "b=5"])
  }

  func testSeveralCookiesAreSeveralLines() {
    let lines = cookieLines(NanoHTTPResponse(statusCode: 200, cookies: [
      NanoHTTPCookie(name: "a", value: "1", httpOnly: false, sameSite: nil),
      NanoHTTPCookie(name: "b", value: "2", httpOnly: false, sameSite: nil),
      NanoHTTPCookie(name: "c", value: "3", httpOnly: false, sameSite: nil)
    ]))
    XCTAssertEqual(lines, ["a=1; Path=/", "b=2; Path=/", "c=3; Path=/"])
  }

  // MARK: Values

  func testValuesAreEncodedWhereACookieCannotHoldTheCharacter() {
    let table: [(String, String)] = [
      ("plain", "plain"),
      ("", ""),
      ("hello world", "hello%20world"),
      ("a;b", "a%3Bb"),
      ("a,b", "a%2Cb"),
      ("say \"hi\"", "say%20%22hi%22"),
      ("back\\slash", "back%5Cslash"),
      ("100%", "100%25"),
      ("€", "%E2%82%AC"),
      ("tab\there", "tab%09here"),
      ("line\r\nbreak", "line%0D%0Abreak"),
      ("allowed:!#$&'()*+-./:<=>?@[]^_`{|}~", "allowed:!#$&'()*+-./:<=>?@[]^_`{|}~")
    ]
    for (value, encoded) in table {
      XCTAssertEqual(line(NanoHTTPCookie(name: "v", value: value, path: nil, httpOnly: false, sameSite: nil)),
                     "v=\(encoded)", value)
    }
  }

  // MARK: Cookies that are not sent

  func testACookieThatWouldAddSomethingToTheResponseIsLeftOutAndReported() {
    let bad: [NanoHTTPCookie] = [
      NanoHTTPCookie(name: "", value: "x"),
      NanoHTTPCookie(name: "a b", value: "x"),
      NanoHTTPCookie(name: "a=b", value: "x"),
      NanoHTTPCookie(name: "a;b", value: "x"),
      NanoHTTPCookie(name: "a\r\nX-Evil: 1", value: "x"),
      NanoHTTPCookie(name: "a", value: "x", path: "/; Domain=evil.example"),
      NanoHTTPCookie(name: "a", value: "x", path: "/\r\nX-Evil: 1"),
      NanoHTTPCookie(name: "a", value: "x", path: "/\u{7F}"),
      NanoHTTPCookie(name: "a", value: "x", domain: "example.org; Secure"),
      NanoHTTPCookie(name: "a", value: "x", domain: "example.org\nX-Evil: 1")
    ]
    for cookie in bad {
      var reported = [String]()
      let response = NanoHTTPResponse(statusCode: 200, cookies: [cookie, NanoHTTPCookie(name: "good", value: "1")])
      let head = String(decoding: NanoHTTPResponseSerializer.head(response, framing: .none, droppedCookie: { reported.append($0) }),
                        as: UTF8.self)
      XCTAssertEqual(reported.count, 1, "\(cookie)")
      XCTAssertFalse(head.contains("X-Evil"), "\(cookie)")
      XCTAssertFalse(head.contains("evil.example"), "\(cookie)")
      XCTAssertEqual(head.components(separatedBy: "\r\n").filter { $0.hasPrefix("Set-Cookie:") }.count, 1,
                     "only the good cookie is written: \(cookie)")
      XCTAssertTrue(head.contains("Set-Cookie: good=1"), "\(cookie)")
    }
  }

  func testTheCookieThatIsLeftOutIsLoggedByTheServer() throws {
    let logger = CapturingLogger()
    try withTestServer(configure: { server in
      server.configuration.logger = logger
      server.get["/"] = { _ in
        NanoHTTPResponse(statusCode: 200, cookies: [NanoHTTPCookie(name: "bad name", value: "x")])
      }
    }) { _, port in
      let response = try RawClient.get("/", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.headers("set-cookie"), [])
      XCTAssertTrue(logger.waitFor("bad name", level: .warning), "\(logger.messages)")
    }
  }
}

final class CookieParsingTests: XCTestCase {

  private func parse(_ header: String) -> [String: String] {
    return NanoHTTPCookie.parse(requestHeader: header)
  }

  func testTheFormsOfTheCookieHeader() {
    XCTAssertEqual(parse("a=1"), ["a": "1"])
    XCTAssertEqual(parse("a=1; b=2"), ["a": "1", "b": "2"])
    XCTAssertEqual(parse("a=1;b=2"), ["a": "1", "b": "2"])
    XCTAssertEqual(parse("  a = 1 ;   b=2  ;"), ["a": "1", "b": "2"])
    XCTAssertEqual(parse("a=; b=2"), ["a": "", "b": "2"])
    XCTAssertEqual(parse("a=b=c"), ["a": "b=c"], "the value begins after the first =")
    XCTAssertEqual(parse(""), [:])
    XCTAssertEqual(parse(";;;"), [:])
  }

  func testEntriesWithoutANameOrAnEqualsSignAreIgnored() {
    XCTAssertEqual(parse("junk; a=1; =2; b=3; novalue"), ["a": "1", "b": "3"])
  }

  func testTheFirstCookieOfARepeatedNameWins() {
    XCTAssertEqual(parse("a=specific; a=general; b=1"), ["a": "specific", "b": "1"])
  }

  func testQuotesAroundAValueAreRemoved() {
    XCTAssertEqual(parse("a=\"x y\"; b=\"\"; c=\"unclosed; d=\"\""), ["a": "x y", "b": "", "c": "\"unclosed", "d": ""])
  }

  func testValuesAreDecodedOnce() {
    XCTAssertEqual(parse("a=hello%20world; b=%E2%82%AC; c=100%25; d=%2525"), ["a": "hello world", "b": "€", "c": "100%", "d": "%25"])
    XCTAssertEqual(parse("a=50%; b=%zz; c=%4"), ["a": "50%", "b": "%zz", "c": "%4"], "what is no escape stays")
    XCTAssertEqual(parse("a=x+y"), ["a": "x+y"], "a plus is a plus in a cookie")
  }

  func testTheRequestParsesTheHeaderOnceAndNoticesChanges() {
    let request = NanoHTTPRequest(method: "GET", path: "/", headers: ["Cookie": "a=1; b=2"])
    XCTAssertEqual(request.cookies, ["a": "1", "b": "2"])
    XCTAssertEqual(request.cookie("a"), "1")
    XCTAssertNil(request.cookie("missing"))
    request.setHeader("cookie", to: "c=3")
    XCTAssertEqual(request.cookies, ["c": "3"])
    request.removeHeader("Cookie")
    XCTAssertEqual(request.cookies, [:])
    XCTAssertEqual(NanoHTTPRequest(method: "GET", path: "/").cookies, [:])
  }

  func testWhatIsWrittenCanBeReadAgain() {
    var state: UInt64 = 20261014
    func next() -> UInt64 {
      state &+= 0x9E3779B97F4A7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
      z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
      return z ^ (z >> 31)
    }
    let pieces = [" ", ";", ",", "\"", "\\", "%", "%41", "=", "+", "€", "ü", "𝄞", "\t", "a", "Z", "0", "-", "_", "~", "/", "\n"]
    for round in 0..<500 {
      var value = ""
      for _ in 0..<Int(next() % 12) {
        value += pieces[Int(next() % UInt64(pieces.count))]
      }
      guard let header = try? NanoHTTPCookie(name: "v", value: value, path: nil).headerValue(),
            let pair = header.split(separator: ";").first else {
        XCTFail("round \(round): \(value.debugDescription) was refused")
        return
      }
      XCTAssertEqual(parse(String(pair))["v"], value, "round \(round): \(String(pair))")
    }
  }
}

final class CookieServerTests: XCTestCase {

  func testCookiesTravelToAClientAndBackLikeInABrowser() throws {
    let awkward = "a b;c=d,\"e\"\\ 100% €"
    for threading in [NanoHTTPServerIO.Configuration.Threading.perConnection, .singleThread] {
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.get["/set"] = { _ in
          var response = NanoHTTPResponse.ok(.text("set"))
          response.setCookie(NanoHTTPCookie(name: "token", value: awkward, maxAge: 60))
          response.setCookie(NanoHTTPCookie(name: "theme", value: "dark", httpOnly: false, sameSite: nil))
          return response
        }
        server.get["/show"] = { request in
          .ok(.text("token=\(request.cookie("token") ?? "-");theme=\(request.cookie("theme") ?? "-")"))
        }
      }) { _, port in
        let set = try RawClient.get("/set", port: port)
        let lines = set.headers("set-cookie")
        XCTAssertEqual(lines.count, 2, "two cookies are two lines: \(threading)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("token=a%20b%3Bc=d%2C%22e%22%5C%20100%25%20%E2%82%AC; Path=/; Max-Age=60; HttpOnly; SameSite=Lax") },
                      "\(lines)")
        XCTAssertTrue(lines.contains("theme=dark; Path=/"), "\(lines)")
        // What a browser does: it sends back the name=value part of every cookie, in one header.
        let sent = lines.map { String($0.split(separator: ";").first ?? "") }.joined(separator: "; ")
        let shown = try RawClient.get("/show", port: port, headers: ["Cookie: \(sent)", "Connection: close"])
        XCTAssertEqual(String(decoding: shown.body, as: UTF8.self), "token=\(awkward);theme=dark", "\(threading)")
      }
    }
  }

  func testSeveralCookieHeadersAreOneListOfCookies() throws {
    try withTestServer(configure: { server in
      server.get["/show"] = { request in
        .ok(.text(request.cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")))
      }
    }) { _, port in
      let response = try RawClient.get("/show", port: port,
                                       headers: ["Cookie: a=1; b=2", "Cookie: c=3, still=c", "Connection: close"])
      XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "a=1,b=2,c=3, still=c",
                     "the headers are joined with a semicolon, a comma stays in its value")
    }
  }

  func testAHeaderSetTheOldWayIsSentNextToTheCookies() throws {
    try withTestServer(configure: { server in
      server.get["/"] = { _ in
        NanoHTTPResponse(statusCode: 200,
                         headers: ["Set-Cookie": "raw=1; Path=/x"],
                         cookies: [NanoHTTPCookie(name: "new", value: "2")])
      }
    }) { _, port in
      let lines = try RawClient.get("/", port: port).headers("set-cookie")
      XCTAssertEqual(Set(lines), ["raw=1; Path=/x", "new=2; Path=/; HttpOnly; SameSite=Lax"])
    }
  }
}
