//
//  HTTPProtocolTests.swift
//  NanoHTTPTests
//
//  End-to-end tests of the HTTP/1.1 behavior of a running server, driven over a raw socket.
//
//  Two kinds of tests live here:
//    * plain tests pin behavior that is correct today (they protect later refactorings), and
//    * `expectKnownIssue` tests assert the CORRECT behavior for findings H4–H7 and H10 of the
//      assessment plan and currently fail as expected; see Support/KnownIssue.swift.
//

import XCTest
@testable import NanoHTTP

final class HTTPProtocolTests: XCTestCase {

  private func serve(_ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.get["/ping"] = { _ in .ok(.text("pong!")) }
      server.post["/echo"] = { request in .ok(.text(String(decoding: request.body, as: UTF8.self))) }
    }, body)
  }

  // MARK: Behavior that is correct today

  func testResponseCarriesStatusLineLengthAndContentType() throws {
    try serve { _, port in
      let response = try RawClient.get("/ping", port: port)
      XCTAssertTrue(response.statusLine.hasPrefix("HTTP/1.1 200 "), response.statusLine)
      XCTAssertEqual(response.header("content-length"), "5")
      XCTAssertTrue(response.header("content-type")?.hasPrefix("text/plain") ?? false)
      XCTAssertEqual(response.bodyString, "pong!")
    }
  }

  func testUnknownRouteIs404() throws {
    try serve { _, port in
      XCTAssertEqual(try RawClient.get("/nope", port: port).status, 404)
    }
  }

  func testCustomNotFoundHandlerIsUsed() throws {
    try withTestServer(configure: { server in
      server.notFoundHandler = { request in .notFound(.text("no \(request.path)")) }
    }) { _, port in
      let response = try RawClient.get("/missing", port: port)
      XCTAssertEqual(response.status, 404)
      XCTAssertEqual(response.bodyString, "no /missing")
    }
  }

  func testMiddlewareCanShortCircuitTheRequest() throws {
    try withTestServer(configure: { server in
      server.get["/secret"] = { _ in .ok(.text("secret")) }
      server.middleware.append { request in
        request.header("x-token") == "ok" ? nil : .unauthorized(.text("denied"))
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/secret", port: port).status, 401)
      XCTAssertEqual(try RawClient.get("/secret", port: port, headers: ["X-Token: ok", "Connection: close"]).bodyString,
                     "secret")
    }
  }

  func testRoutedMethodIsRespected() throws {
    try serve { _, port in
      XCTAssertEqual(try RawClient.request("POST", "/echo", port: port, body: Array("hi".utf8)).bodyString, "hi")
      XCTAssertEqual(try RawClient.request("GET", "/echo", port: port).status, 404)
    }
  }

  func testRequestBodyReachesHandlerByteForByte() throws {
    try serve { _, port in
      let payload = String(repeating: "héllo €\n", count: 2000) // > several read chunks
      let response = try RawClient.request("POST", "/echo", port: port, body: Array(payload.utf8))
      XCTAssertEqual(response.bodyString, payload)
    }
  }

  func testRouteParametersArePercentDecodedAndQueryIsAvailable() throws {
    try withTestServer(configure: { server in
      server.get["/users/:id"] = { request in
        .ok(.text("\(request.params["id"] ?? "-")|\(request.queryParams.count)"))
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/users/a%20b?x=1&y=2", port: port).bodyString, "a b|2")
    }
  }

  func testNonASCIIBodyLengthCountsBytes() throws {
    try withTestServer(configure: { server in
      server.get["/t"] = { _ in .ok(.text("héllo €")) }
    }) { _, port in
      let response = try RawClient.get("/t", port: port)
      XCTAssertEqual(response.header("content-length"), "\("héllo €".utf8.count)")
      XCTAssertEqual(response.bodyString, "héllo €")
    }
  }

  func testValidJSONBody() throws {
    try withTestServer(configure: { server in
      server.get["/j"] = { _ in .ok(.json(["a": 1])) }
    }) { _, port in
      let response = try RawClient.get("/j", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.header("content-type"), "application/json")
      XCTAssertEqual(response.bodyString, "{\"a\":1}")
    }
  }

  func testRedirectHelpers() throws {
    try withTestServer(configure: { server in
      server["/permanent"] = { _ in .movedPermanently("/target") }
      server["/temporary"] = { _ in .movedTemporarily("/target") }
    }) { _, port in
      let permanent = try RawClient.get("/permanent", port: port)
      XCTAssertEqual(permanent.status, 301)
      XCTAssertEqual(permanent.header("location"), "/target")
      XCTAssertEqual(try RawClient.get("/temporary", port: port).status, 307)
    }
  }

  func testKeepAliveWithExplicitHeaderServesSeveralRequestsOnOneConnection() throws {
    try serve { server, port in
      let client = try RawClient(port: port)
      for round in 0..<3 {
        client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: keep-alive"]))
        let response = client.readResponse()
        XCTAssertEqual(response?.status, 200, "round \(round)")
        XCTAssertEqual(response?.bodyString, "pong!", "round \(round)")
        XCTAssertEqual(response?.header("connection")?.lowercased(), "keep-alive", "round \(round)")
      }
      XCTAssertEqual(server.openConnections, 1)
    }
  }

  func testConnectionCloseIsHonored() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/ping", headers: ["Connection: close"]))
      XCTAssertEqual(client.readResponse()?.status, 200)
      XCTAssertTrue(client.waitForClose(timeout: 2), "server kept the connection open")
    }
  }

  func testPipelinedRequestsAreAnsweredInOrder() throws {
    try withTestServer(configure: { server in
      server.get["/a"] = { _ in .ok(.text("A")) }
      server.get["/b"] = { _ in .ok(.text("B")) }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/a", headers: ["Connection: keep-alive"]) +
                  RawClient.requestText("GET", "/b", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.bodyString, "A")
      XCTAssertEqual(client.readResponse()?.bodyString, "B")
    }
  }

  func testCustomBodyWithoutLengthIsDelimitedByClose() throws {
    try withTestServer(configure: { server in
      server["/stream"] = { _ in .custom(200) { writer in
        for index in 0..<5 { try writer.write([UInt8]("[\(index)]".utf8)) }
      } }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/stream", headers: ["Connection: keep-alive"]))
      let response = client.readResponse()
      XCTAssertNil(response?.header("content-length"))
      XCTAssertEqual(response?.bodyString, "[0][1][2][3][4]")
      XCTAssertTrue(client.waitForClose(timeout: 1))
    }
  }

  // MARK: H4: persistent connections and framing

  func testHTTP11ConnectionIsPersistentByDefault() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/ping", headers: [])) // no Connection header
      XCTAssertEqual(client.readResponse()?.status, 200)
      client.send(RawClient.requestText("GET", "/ping", headers: []))
      expectKnownIssue("H4", "HTTP/1.1 is persistent by default; the server closes unless 'Connection: keep-alive' was sent") {
        XCTAssertEqual(client.readResponse()?.status, 200, "second request on the same connection")
      }
    }
  }

  func testServerAnnouncesConnectionCloseWhenItClosesTheConnection() throws {
    try serve { _, port in
      let response = try RawClient.get("/ping", port: port, headers: ["Connection: close"])
      expectKnownIssue("H4", "no 'Connection: close' header is sent although the server closes") {
        XCTAssertEqual(response.header("connection")?.lowercased(), "close")
      }
    }
  }

  func testChunkedRequestBodyIsDecodedOrRejected() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("POST", "/echo",
                                        headers: ["Transfer-Encoding: chunked", "Connection: close"],
                                        body: Array("5\r\nhello\r\n0\r\n\r\n".utf8)))
      let response = client.readResponse()
      expectKnownIssue("H4", "chunked request bodies are silently ignored (empty body, 200)") {
        XCTAssertTrue(response?.bodyString == "hello" || response?.status == 501 || response?.status == 411,
                      "status \(String(describing: response?.status)), body '\(response?.bodyString ?? "")'")
      }
    }
  }

  // MARK: H5, H6: response content

  func testJSONSerializationFailureIsAServerError() throws {
    try withTestServer(configure: { server in
      server.get["/bad-json"] = { _ in .ok(.json(Date())) } // not a valid JSON object
    }) { _, port in
      let response = try RawClient.get("/bad-json", port: port)
      XCTAssertEqual(response.status, 500)
    }
  }

  func testTextAndHTMLResponsesDeclareACharset() throws {
    try withTestServer(configure: { server in
      server.get["/text"] = { _ in .ok(.text("héllo")) }
      server.get["/html"] = { _ in .ok(.html("<p>héllo</p>")) }
    }) { _, port in
      for path in ["/text", "/html"] {
        let response = try RawClient.get(path, port: port)
        XCTAssertTrue(response.header("content-type")?.lowercased().contains("charset=utf-8") ?? false,
                      response.header("content-type") ?? "<none>")
      }
    }
  }

  func testReasonPhrasesAreStandard() throws {
    try withTestServer(configure: { server in
      server.get["/ok"] = { _ in .ok(.text("x")) }
    }) { _, port in
      let ok = try RawClient.get("/ok", port: port)
      let missing = try RawClient.get("/missing", port: port)
      // Observed: derived from HTTPURLResponse.localizedString, i.e. localized, not the RFC text.
      XCTAssertEqual(ok.statusLine, "HTTP/1.1 200 OK")
      XCTAssertEqual(missing.statusLine, "HTTP/1.1 404 Not Found")
    }
  }

  func testFailedJSONSerializationAnswers500WithoutDetailsAndKeepsTheConnection() throws {
    try withTestServer(configure: { server in
      server.get["/bad"] = { _ in .ok(headers: ["X-Mine": "1"], .json(Date())) }
      server.get["/good"] = { _ in .ok(.json(["ok": true])) }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/bad", headers: ["Connection: keep-alive"]))
      let failed = client.readResponse()
      XCTAssertEqual(failed?.status, 500)
      XCTAssertEqual(failed?.bodyString, "Internal Server Error")
      XCTAssertEqual(failed?.header("content-type"), "text/plain; charset=utf-8")
      XCTAssertNil(failed?.header("x-mine"))
      client.send(RawClient.requestText("GET", "/good", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.bodyString, "{\"ok\":true}")
    }
  }

  func testStatusLinesUseTheStandardReasonPhrases() throws {
    let expected: [Int: String] = [200: "OK", 201: "Created", 204: "No Content", 301: "Moved Permanently",
                                   304: "Not Modified", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                                   405: "Method Not Allowed", 413: "Content Too Large", 429: "Too Many Requests",
                                   500: "Internal Server Error", 503: "Service Unavailable"]
    for (code, phrase) in expected {
      XCTAssertEqual(NanoHTTPResponse(statusCode: code).reasonPhrase, phrase, "\(code)")
    }
    XCTAssertEqual(NanoHTTPResponse(statusCode: 299).reasonPhrase, "")
    try withTestServer(configure: { server in
      server["/odd"] = { _ in NanoHTTPResponse(statusCode: 299) }
    }) { _, port in
      let client = try RawClient(port: port)
      client.send("GET /odd HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      XCTAssertEqual(client.readResponse()?.statusLine, "HTTP/1.1 299 ") // an empty reason phrase is allowed
    }
  }

  func testOnlyTextualBodiesGetACharset() throws {
    XCTAssertEqual(NanoHTTPResponse.Body.text("x").contentType(), "text/plain; charset=utf-8")
    XCTAssertEqual(NanoHTTPResponse.Body.html("x").contentType(), "text/html; charset=utf-8")
    XCTAssertEqual(NanoHTTPResponse.Body.htmlBody("x").contentType(), "text/html; charset=utf-8")
    XCTAssertEqual(NanoHTTPResponse.Body.json([:]).contentType(), "application/json")
    XCTAssertEqual(NanoHTTPResponse.Body.data(Data(), contentType: nil).contentType(), "application/octet-stream")
    XCTAssertEqual(NanoHTTPResponse.Body.data(Data(), contentType: "image/png").contentType(), "image/png")
    XCTAssertNil(NanoHTTPResponse.Body.empty.contentType())
  }

  // MARK: H7: HEAD and 405

  func testHeadResponseHasNoBody() throws {
    try withTestServer(configure: { server in
      server["/any"] = { _ in .ok(.text("hello")) } // registered for every method
    }) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("HEAD", "/any", headers: ["Connection: close"]))
      let response = client.readResponse(head: true)
      XCTAssertEqual(response?.status, 200)
      XCTAssertEqual(response?.header("content-length"), "5") // length of the GET representation
      let leftover = client.readToEnd(timeout: 1)
      expectKnownIssue("H7", "a body is sent in response to HEAD") {
        XCTAssertEqual(leftover.count, 0, "HEAD response carried body '\(String(decoding: leftover, as: UTF8.self))'")
      }
    }
  }

  func testWrongMethodGets405WithAllowHeader() throws {
    try withTestServer(configure: { server in
      server.get["/only-get"] = { _ in .ok(.text("x")) }
    }) { _, port in
      let response = try RawClient.request("POST", "/only-get", port: port)
      expectKnownIssue("H7", "wrong method answers 404 instead of 405 + Allow") {
        XCTAssertEqual(response.status, 405)
        XCTAssertNotNil(response.header("allow"))
      }
    }
  }
}

// MARK: - H10: file responses

final class FileResponseTests: XCTestCase {
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
      server["/file"] = share(file: self.fixture.helloFile)
      server["/public/::path"] = share(directory: self.fixture.publicDir)
    }) { _, port in
      try body(port)
    }
  }

  func testShareFileSendsContentAndHeaders() throws {
    try serve { port in
      let response = try RawClient.get("/file", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.bodyString, "hello")
      XCTAssertEqual(response.header("content-length"), "5")
      XCTAssertEqual(response.header("content-type"), "text/plain")
    }
  }

  func testMissingSharedFileIs404() throws {
    try withTestServer(configure: { server in
      server["/file"] = share(file: "/definitely/not/here.txt")
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/file", port: port).status, 404)
    }
  }

  func testFileResponsesKeepTheConnectionAlive() throws {
    try serve { port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/file", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.bodyString, "hello")
      client.send(RawClient.requestText("GET", "/file", headers: ["Connection: keep-alive"]))
      expectKnownIssue("H10", "file bodies have no framework-known length, so keep-alive is disabled") {
        XCTAssertEqual(client.readResponse()?.bodyString, "hello", "second request on the same connection")
      }
    }
  }

  func testRequestingADirectoryIsNotAnEmpty200() throws {
    try serve { port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("GET", "/public/sub", headers: ["Connection: close"]))
      let response = client.readResponse()
      expectKnownIssue("H10", "fopen() succeeds on a directory: 200 with a Content-Length but no body") {
        XCTAssertNotEqual(response?.status, 200)
      }
    }
  }

  func testIndexFileIsServedForTheRootOfASharedDirectory() throws {
    try "<h1>index</h1>".write(toFile: self.fixture.publicDir + "/index.html", atomically: true, encoding: .utf8)
    try serve { port in
      let response = try RawClient.get("/public/", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.bodyString, "<h1>index</h1>")
    }
  }

  func testBrowseFileResponseHasTypeAndLength() throws {
    try withTestServer(configure: { server in
      server["/files/::path"] = browse(directory: self.fixture.publicDir)
    }) { _, port in
      let response = try RawClient.get("/files/hello.txt", port: port)
      XCTAssertEqual(response.bodyString, "hello")
      XCTAssertEqual(response.header("content-type"), "text/plain")
      XCTAssertEqual(response.header("content-length"), "5")
    }
  }

  func testIndexResponseDeclaresAContentType() throws {
    try "<h1>index</h1>".write(toFile: self.fixture.publicDir + "/index.html", atomically: true, encoding: .utf8)
    try serve { port in
      let response = try RawClient.get("/public/", port: port)
      XCTAssertEqual(response.header("content-type"), "text/html")
      XCTAssertEqual(response.header("content-length"), "14")
    }
  }
}
