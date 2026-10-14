//
//  HandlerErrorTests.swift
//  NanoHTTPTests
//
//  2.0: handlers can throw. A `NanoHTTPError` becomes the response with its status code, every other
//  error becomes a `500` without details, and a server can decide differently (`errorHandler`).
//

import XCTest
@testable import NanoHTTP

/// A server that remembers what it logs.
private final class LoggingServer: NanoHTTPServer {
  let captured = CapturingLogger()

  var messages: [String] {
    return self.captured.messages
  }

  public override init(configuration: Configuration = Configuration()) {
    super.init(configuration: configuration)
    self.configuration.logger = self.captured
  }
}

/// An error of the application, with a description that must not reach the client.
private struct DatabaseError: Error, CustomStringConvertible {
  let password = "hunter2"
  var description: String { return "cannot connect to the database with password \(self.password)" }
}

// MARK: - The error type

final class NanoHTTPErrorTests: XCTestCase {

  func testAnErrorIsAnswerWithItsStatusHeadersAndMessage() {
    let error = NanoHTTPError(status: 418, message: "short and stout", headers: ["X-Pot": "tea"])
    let response = error.response
    XCTAssertEqual(response.statusCode, 418)
    XCTAssertEqual(response.headers["X-Pot"], "tea")
    XCTAssertEqual(response.body.contentType(), "text/plain; charset=utf-8")
    XCTAssertEqual(response.capturedBody(), "short and stout")
  }

  func testWithoutAMessageTheBodyIsEmpty() {
    let response = NanoHTTPError.notFound().response
    XCTAssertEqual(response.statusCode, 404)
    XCTAssertNil(response.body.contentType())
    XCTAssertEqual(response.capturedBody(), "")
  }

  func testTheNamedErrorsHaveTheirStatusCodes() {
    let errors: [(NanoHTTPError, Int)] = [
      (.badRequest(), 400), (.unauthorized(), 401), (.forbidden(), 403), (.notFound(), 404),
      (.methodNotAllowed(), 405), (.notAcceptable(), 406), (.conflict(), 409), (.payloadTooLarge(), 413),
      (.unsupportedMediaType(), 415), (.unprocessableContent(), 422), (.tooManyRequests(), 429),
      (.internalServerError(), 500), (.notImplemented(), 501), (.serviceUnavailable(), 503),
    ]
    for (error, status) in errors {
      XCTAssertEqual(error.status, status)
      XCTAssertEqual(error.response.statusCode, status)
      XCTAssertFalse(error.response.reasonPhrase.isEmpty, "\(status)")
    }
  }

  func testTheNamedErrorsTakeTheirSpecialHeaders() {
    XCTAssertEqual(NanoHTTPError.unauthorized(wwwAuthenticate: "Bearer").headers["WWW-Authenticate"], "Bearer")
    XCTAssertEqual(NanoHTTPError.methodNotAllowed(allow: ["GET", "HEAD"]).headers["Allow"], "GET, HEAD")
    XCTAssertNil(NanoHTTPError.methodNotAllowed().headers["Allow"])
    XCTAssertEqual(NanoHTTPError.tooManyRequests(retryAfter: 30).headers["Retry-After"], "30")
    XCTAssertEqual(NanoHTTPError.serviceUnavailable("later", retryAfter: 5).headers["Retry-After"], "5")
    XCTAssertEqual(NanoHTTPError.badRequest("x", headers: ["A": "b"]).headers["A"], "b")
  }

  func testDescriptionAndEquality() {
    XCTAssertEqual(NanoHTTPError.badRequest("no name").description, "NanoHTTPError(400 Bad Request: no name)")
    XCTAssertEqual(NanoHTTPError.notFound().description, "NanoHTTPError(404 Not Found)")
    XCTAssertEqual(NanoHTTPError(status: 799).description, "NanoHTTPError(799)")
    XCTAssertEqual(NanoHTTPError.badRequest("a"), NanoHTTPError.badRequest("a"))
    XCTAssertNotEqual(NanoHTTPError.badRequest("a"), NanoHTTPError.badRequest("b"))
  }
}

// MARK: - Errors in a server

final class HandlerErrorTests: XCTestCase {

  private func serve(threading: NanoHTTPServer.Configuration.Threading = .perConnection,
                     configure: (LoggingServer) -> Void,
                     _ body: (LoggingServer, Int) throws -> Void) throws {
    let server = LoggingServer()
    server.configuration.threading = threading
    server.get["/ok"] = { _ in .ok(.text("fine")) }
    configure(server)
    try server.start(0)
    defer { server.stop() }
    try body(server, try server.port())
  }

  func testANanoHTTPErrorBecomesItsResponse() throws {
    try serve(configure: { server in
      server.get["/item"] = { _ in throw NanoHTTPError.badRequest("Missing name") }
    }) { _, port in
      let response = try RawClient.get("/item", port: port)
      XCTAssertEqual(response.status, 400)
      XCTAssertEqual(response.reason, "Bad Request")
      XCTAssertEqual(response.bodyString, "Missing name")
      XCTAssertEqual(response.header("content-type"), "text/plain; charset=utf-8")
    }
  }

  func testTheHeadersOfTheErrorAreSent() throws {
    try serve(configure: { server in
      server.get["/teapot"] = { _ in throw NanoHTTPError(status: 418, message: "no coffee", headers: ["X-Pot": "tea"]) }
      server.get["/auth"] = { _ in throw NanoHTTPError.unauthorized(wwwAuthenticate: "Bearer") }
    }) { _, port in
      let teapot = try RawClient.get("/teapot", port: port)
      XCTAssertEqual(teapot.status, 418)
      XCTAssertEqual(teapot.header("x-pot"), "tea")
      let auth = try RawClient.get("/auth", port: port)
      XCTAssertEqual(auth.status, 401)
      XCTAssertEqual(auth.header("www-authenticate"), "Bearer")
      XCTAssertEqual(auth.header("content-length"), "0")
    }
  }

  func testOtherErrorsBecomeA500WithoutDetails() throws {
    try serve(configure: { server in
      server.get["/db"] = { _ in throw DatabaseError() }
    }) { server, port in
      let response = try RawClient.get("/db", port: port)
      XCTAssertEqual(response.status, 500)
      XCTAssertEqual(response.bodyString, "Internal Server Error")
      XCTAssertFalse(response.bodyString.contains("hunter2"))
      XCTAssertFalse(response.headerFields.contains { $0.value.contains("hunter2") })
      // ... but the server tells whoever reads its log.
      let logged = server.messages.joined(separator: "\n")
      XCTAssertTrue(logged.contains("GET /db"), logged)
      XCTAssertTrue(logged.contains("hunter2"), logged)
      XCTAssertTrue(server.captured.contains("GET /db", level: .error), "a failing handler is an error")
    }
  }

  func testAThrownNanoHTTPErrorIsNotLogged() throws {
    try serve(configure: { server in
      server.get["/missing"] = { _ in throw NanoHTTPError.notFound() }
    }) { server, port in
      XCTAssertEqual(try RawClient.get("/missing", port: port).status, 404)
      XCTAssertEqual(server.messages, [])
    }
  }

  func testAConnectionStaysUsableAfterAnError() throws {
    try serve(configure: { server in
      server.get["/bad"] = { _ in throw NanoHTTPError.conflict("busy") }
    }) { _, port in
      let client = try RawClient(port: port)
      for _ in 0..<3 {
        client.send(RawClient.requestText("GET", "/bad", headers: ["Connection: keep-alive"]))
        XCTAssertEqual(client.readResponse()?.status, 409)
        client.send(RawClient.requestText("GET", "/ok", headers: ["Connection: keep-alive"]))
        XCTAssertEqual(client.readResponse()?.bodyString, "fine")
      }
    }
  }

  func testErrorsOfTheNotFoundHandlerAreAnswered() throws {
    try serve(configure: { server in
      server.notFoundHandler = { request in throw NanoHTTPError.notFound("No \(request.path) here") }
    }) { _, port in
      let response = try RawClient.get("/nothing", port: port)
      XCTAssertEqual(response.status, 404)
      XCTAssertEqual(response.bodyString, "No /nothing here")
    }
  }

  func testHandlersThatDoNotThrowStillWork() throws {
    // Closures that cannot throw are accepted where a throwing handler is expected.
    let plain: (NanoHTTPRequest) -> NanoHTTPResponse = { _ in .ok(.text("plain")) }
    try serve(configure: { server in
      server.get["/plain"] = plain
      server["/any"] = { _ in .ok(.text("any")) }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/plain", port: port).bodyString, "plain")
      XCTAssertEqual(try RawClient.get("/any", port: port).bodyString, "any")
    }
  }

  // MARK: errorHandler

  func testTheErrorHandlerAnswersEveryError() throws {
    try serve(configure: { server in
      server.get["/known"] = { _ in throw NanoHTTPError.badRequest("bad input") }
      server.get["/unknown"] = { _ in throw DatabaseError() }
      server.errorHandler = { error, request in
        let message: String
        if let error = error as? NanoHTTPError {
          message = error.message ?? "none"
          return NanoHTTPResponse(statusCode: error.status, body: .json(["error": message, "path": request.path]))
        }
        return NanoHTTPResponse(statusCode: 500, body: .json(["error": "internal", "path": request.path]))
      }
    }) { _, port in
      let known = try RawClient.get("/known", port: port)
      XCTAssertEqual(known.status, 400)
      XCTAssertEqual(known.header("content-type"), "application/json")
      XCTAssertTrue(known.bodyString.contains("\"bad input\""), known.bodyString)
      XCTAssertTrue(known.bodyString.contains("known"), known.bodyString) // the path, whose slash JSON escapes
      let unknown = try RawClient.get("/unknown", port: port)
      XCTAssertEqual(unknown.status, 500)
      XCTAssertTrue(unknown.bodyString.contains("\"internal\""), unknown.bodyString)
      XCTAssertFalse(unknown.bodyString.contains("hunter2"))
    }
  }

  func testTheErrorHandlerCanLeaveErrorsToTheDefault() throws {
    try serve(configure: { server in
      server.get["/known"] = { _ in throw NanoHTTPError.forbidden("no") }
      server.get["/teapot"] = { _ in throw NanoHTTPError(status: 418) }
      server.errorHandler = { error, _ in
        (error as? NanoHTTPError)?.status == 418 ? NanoHTTPResponse(statusCode: 200, body: .text("teapot is fine")) : nil
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/known", port: port).status, 403)
      XCTAssertEqual(try RawClient.get("/teapot", port: port).bodyString, "teapot is fine")
    }
  }

  func testTheDefaultMappingIsAvailableToSubclasses() {
    let server = NanoHTTPServerIO()
    let request = NanoHTTPRequest(method: "GET", path: "/x")
    XCTAssertEqual(server.response(for: NanoHTTPError.conflict("c"), to: request).statusCode, 409)
    XCTAssertEqual(server.response(for: DatabaseError(), to: request).statusCode, 500)
    XCTAssertEqual(server.response(for: NanoSocketError.timedOut, to: request).capturedBody(), "Internal Server Error")
  }

  // MARK: One thread

  func testAServerWithOneThreadAnswersErrorsAndGoesOn() throws {
    try serve(threading: .singleThread, configure: { server in
      server.get["/bad"] = { _ in throw DatabaseError() }
      server.get["/teapot"] = { _ in throw NanoHTTPError(status: 418) }
    }) { _, port in
      for _ in 0..<3 {
        XCTAssertEqual(try RawClient.get("/bad", port: port).status, 500)
        XCTAssertEqual(try RawClient.get("/teapot", port: port).status, 418)
        XCTAssertEqual(try RawClient.get("/ok", port: port).bodyString, "fine")
      }
    }
  }
}
