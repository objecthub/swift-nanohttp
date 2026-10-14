//
//  CORSTests.swift
//  NanoHTTPTests
//
//  4.2 (S6): `NanoMiddleware.cors` lets the pages of other sites use a server: it answers preflight requests
//  and adds the headers that make a browser hand the response to the page.
//

import XCTest
@testable import NanoHTTP

private let bothModes: [NanoHTTPServer.Configuration.Threading] = [.perConnection, .singleThread]

final class CORSTests: XCTestCase {

  /// Counts the requests that reach the handlers.
  private final class Handled {
    private let lock = NSLock()
    private var value = 0

    func count() {
      self.lock.lock()
      self.value += 1
      self.lock.unlock()
    }

    var total: Int {
      self.lock.lock()
      defer { self.lock.unlock() }
      return self.value
    }
  }

  private func serve(_ policy: NanoCORSPolicy,
                     threading: NanoHTTPServer.Configuration.Threading = .perConnection,
                     handled: Handled = Handled(),
                     configure: (NanoHTTPServer) -> Void = { _ in },
                     _ body: (Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.middleware.append(NanoMiddleware.cors(policy))
      server["/data"] = { _ in handled.count(); return .ok(headers: ["X-Custom": "1"], .text("data")) }
      server["/vary"] = { _ in .ok(headers: ["Vary": "Accept-Encoding"], .text("v")) }
      server["/bad"] = { _ in throw NanoHTTPError.badRequest("no") }
      server["/boom"] = { _ in throw NSError(domain: "test", code: 1) }
      configure(server)
    }) { _, port in
      try body(port)
    }
  }

  private func send(_ port: Int,
                    _ method: String = "GET",
                    _ path: String = "/data",
                    _ headers: [String] = []) throws -> RawResponse {
    let client = try RawClient(port: port)
    defer { client.close() }
    client.send(RawClient.requestText(method, path, headers: headers + ["Connection: close"]))
    return try XCTUnwrap(client.readResponse())
  }

  func testARequestWithoutAnOriginIsLeftAlone() throws {
    try serve(NanoCORSPolicy(allowedOrigins: ["https://app.example"])) { port in
      let response = try self.send(port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.bodyString, "data")
      XCTAssertNil(response.header("access-control-allow-origin"))
      XCTAssertNil(response.header("vary"))
    }
  }

  func testEveryOriginMayUseTheServerWithAStar() throws {
    for threading in bothModes {
      try serve(NanoCORSPolicy(), threading: threading) { port in
        let response = try self.send(port, "GET", "/data", ["Origin: https://anything.example"])
        XCTAssertEqual(response.header("access-control-allow-origin"), "*", "\(threading)")
        XCTAssertNil(response.header("access-control-allow-credentials"))
        XCTAssertNil(response.header("vary"), "the answer is the same for every origin")
      }
    }
  }

  func testAListedOriginIsNamedInTheAnswer() throws {
    for threading in bothModes {
      try serve(NanoCORSPolicy(allowedOrigins: ["https://app.example", "http://localhost:3000"]), threading: threading) { port in
        let allowed = try self.send(port, "GET", "/data", ["Origin: http://localhost:3000"])
        XCTAssertEqual(allowed.status, 200)
        XCTAssertEqual(allowed.header("access-control-allow-origin"), "http://localhost:3000", "\(threading)")
        XCTAssertEqual(allowed.header("vary"), "Origin")
        XCTAssertEqual(allowed.header("x-custom"), "1", "the headers of the handler stay")
        let withDefaultPort = try self.send(port, "GET", "/data", ["Origin: https://app.example:443"])
        XCTAssertEqual(withDefaultPort.header("access-control-allow-origin"), "https://app.example:443")
      }
    }
  }

  func testAnOriginThatIsNotListedGetsTheAnswerWithoutPermission() throws {
    try serve(NanoCORSPolicy(allowedOrigins: ["https://app.example"])) { port in
      for origin in ["https://evil.example", "http://app.example", "https://app.example:8443", "null", "garbage"] {
        let response = try self.send(port, "GET", "/data", ["Origin: \(origin)"])
        XCTAssertEqual(response.status, 200, "the server does not decide: the browser keeps the page from reading \(origin)")
        XCTAssertNil(response.header("access-control-allow-origin"), origin)
        XCTAssertEqual(response.header("vary"), "Origin", origin)
      }
    }
  }

  func testCredentialsNameTheOriginAndNeverUseAStar() throws {
    try serve(NanoCORSPolicy(allowsCredentials: true)) { port in
      let response = try self.send(port, "GET", "/data", ["Origin: https://page.example"])
      XCTAssertEqual(response.header("access-control-allow-origin"), "https://page.example")
      XCTAssertEqual(response.header("access-control-allow-credentials"), "true")
      XCTAssertEqual(response.header("vary"), "Origin")
    }
  }

  func testExposedHeaders() throws {
    try serve(NanoCORSPolicy(exposedHeaders: ["X-Custom", "ETag"])) { port in
      let response = try self.send(port, "GET", "/data", ["Origin: https://page.example"])
      XCTAssertEqual(response.header("access-control-expose-headers"), "X-Custom, ETag")
    }
  }

  func testVaryIsExtendedAndNotReplaced() throws {
    try serve(NanoCORSPolicy(allowedOrigins: ["https://app.example"])) { port in
      let response = try self.send(port, "GET", "/vary", ["Origin: https://app.example"])
      XCTAssertEqual(response.header("vary"), "Accept-Encoding, Origin")
    }
  }

  func testThePreflightRequestIsAnsweredWithoutCallingTheHandler() throws {
    for threading in bothModes {
      let handled = Handled()
      try serve(NanoCORSPolicy(allowedOrigins: ["https://app.example"]), threading: threading, handled: handled) { port in
        let response = try self.send(port, "OPTIONS", "/data",
                                     ["Origin: https://app.example", "Access-Control-Request-Method: PUT",
                                      "Access-Control-Request-Headers: content-type, x-token"])
        XCTAssertEqual(response.status, 204, "\(threading)")
        XCTAssertEqual(response.body.count, 0)
        XCTAssertEqual(response.header("access-control-allow-origin"), "https://app.example")
        XCTAssertEqual(response.header("access-control-allow-methods"), "GET, HEAD, POST, PUT, PATCH, DELETE")
        XCTAssertEqual(response.header("access-control-allow-headers"), "content-type, x-token", "the headers that were asked for")
        XCTAssertEqual(response.header("access-control-max-age"), "600")
        XCTAssertNil(response.header("access-control-allow-credentials"))
        XCTAssertEqual(response.header("vary"),
                       "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")
        XCTAssertEqual(handled.total, 0, "\(threading)")
      }
    }
  }

  func testThePreflightRequestOfAPathThatDoesNotExistIsAnswered() throws {
    try serve(NanoCORSPolicy()) { port in
      let response = try self.send(port, "OPTIONS", "/nothing/here",
                                   ["Origin: https://page.example", "Access-Control-Request-Method: POST"])
      XCTAssertEqual(response.status, 204)
      XCTAssertEqual(response.header("access-control-allow-origin"), "*")
    }
  }

  func testAPreflightRequestCanListTheAllowedHeadersItself() throws {
    let policy = NanoCORSPolicy(allowedOrigins: ["https://app.example"],
                                allowedMethods: ["GET", "POST"],
                                allowedHeaders: ["Content-Type", "Authorization"],
                                allowsCredentials: true,
                                maxAge: 3600)
    try serve(policy) { port in
      let response = try self.send(port, "OPTIONS", "/data",
                                   ["Origin: https://app.example", "Access-Control-Request-Method: POST",
                                    "Access-Control-Request-Headers: x-other"])
      XCTAssertEqual(response.header("access-control-allow-methods"), "GET, POST")
      XCTAssertEqual(response.header("access-control-allow-headers"), "Content-Type, Authorization")
      XCTAssertEqual(response.header("access-control-allow-credentials"), "true")
      XCTAssertEqual(response.header("access-control-max-age"), "3600")
      XCTAssertEqual(response.header("access-control-allow-origin"), "https://app.example")
    }
  }

  func testAPreflightRequestWithoutMaxAgeAndWithoutRequestedHeaders() throws {
    try serve(NanoCORSPolicy(maxAge: nil)) { port in
      let response = try self.send(port, "OPTIONS", "/data", ["Origin: https://page.example", "Access-Control-Request-Method: GET"])
      XCTAssertNil(response.header("access-control-max-age"))
      XCTAssertNil(response.header("access-control-allow-headers"))
    }
  }

  func testAPreflightRequestFromAnOriginOrForAMethodThatIsNotAllowedGetsNoPermission() throws {
    try serve(NanoCORSPolicy(allowedOrigins: ["https://app.example"], allowedMethods: ["GET"])) { port in
      let origin = try self.send(port, "OPTIONS", "/data", ["Origin: https://evil.example", "Access-Control-Request-Method: GET"])
      XCTAssertEqual(origin.status, 204)
      XCTAssertNil(origin.header("access-control-allow-origin"))
      XCTAssertNil(origin.header("access-control-allow-methods"))
      let method = try self.send(port, "OPTIONS", "/data", ["Origin: https://app.example", "Access-Control-Request-Method: DELETE"])
      XCTAssertEqual(method.status, 204)
      XCTAssertNil(method.header("access-control-allow-origin"))
    }
  }

  func testAnOptionsRequestThatIsNoPreflightGoesToTheRouter() throws {
    let handled = Handled()
    try serve(NanoCORSPolicy(), handled: handled) { port in
      let response = try self.send(port, "OPTIONS", "/data", ["Origin: https://page.example"])
      XCTAssertEqual(response.status, 200, "this route answers every method: the handler is the one that answers")
      XCTAssertEqual(handled.total, 1)
      XCTAssertEqual(response.header("access-control-allow-origin"), "*")
    }
  }

  func testTheErrorOfAHandlerStillGetsThePermission() throws {
    try serve(NanoCORSPolicy(allowedOrigins: ["https://app.example"])) { port in
      let response = try self.send(port, "GET", "/bad", ["Origin: https://app.example"])
      XCTAssertEqual(response.status, 400, "the page can read the status")
      XCTAssertEqual(response.bodyString, "no")
      XCTAssertEqual(response.header("access-control-allow-origin"), "https://app.example")
    }
  }

  func testOtherErrorsBecomeTheServersOwn500() throws {
    try serve(NanoCORSPolicy()) { port in
      let response = try self.send(port, "GET", "/boom", ["Origin: https://page.example"])
      XCTAssertEqual(response.status, 500)
      XCTAssertNil(response.header("access-control-allow-origin"))
    }
  }

  func testTheOriginPolicyAndCORSWorkTogether() throws {
    let policy = NanoCORSPolicy(allowedOrigins: ["https://app.example"])
    try serve(policy, configure: { server in
      server.configuration.originPolicy = .origins(["https://app.example"])
      server.get["/data"] = { _ in .ok(.text("data")) }
      server.post["/data"] = { _ in .ok(.text("posted")) }
    }) { port in
      let preflight = try self.send(port, "OPTIONS", "/data", ["Origin: https://app.example", "Access-Control-Request-Method: POST"])
      XCTAssertEqual(preflight.status, 204, "a preflight request changes nothing: the origin policy does not look at it")
      let allowed = try self.send(port, "POST", "/data", ["Origin: https://app.example"])
      XCTAssertEqual(allowed.status, 200)
      XCTAssertEqual(allowed.header("access-control-allow-origin"), "https://app.example")
      let foreign = try self.send(port, "POST", "/data", ["Origin: https://evil.example"])
      XCTAssertEqual(foreign.status, 403, "the request of the other site never reached the handler")
    }
  }

  func testPoliciesOfOriginsAreComparedByTheirParts() {
    let policy = NanoCORSPolicy(allowedOrigins: ["https://App.example", "http://localhost:3000"])
    XCTAssertTrue(policy.allows(origin: "https://app.example:443"))
    XCTAssertTrue(policy.allows(origin: "HTTP://LOCALHOST:3000"))
    XCTAssertFalse(policy.allows(origin: "http://app.example"))
    XCTAssertFalse(policy.allows(origin: "https://app.example.evil.example"))
    XCTAssertFalse(policy.allows(origin: "null"))
    XCTAssertTrue(NanoCORSPolicy().allows(origin: "null"), "every origin is every origin")
  }
}
