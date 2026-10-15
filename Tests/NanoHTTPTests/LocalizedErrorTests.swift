//
//  LocalizedErrorTests.swift
//  NanoHTTPTests
//
//  2.1.2: the errors of NanoHTTP conform to `LocalizedError`, so that `localizedDescription` says in
//  English what failed (and not "The operation couldn't be completed. (NanoHTTP.NanoSocketError error
//  3.)"). `description` and what string interpolation gives are not changed, and the server still
//  answers an error that is not a `NanoHTTPError` with a `500` without details.
//

import XCTest
@testable import NanoHTTP

/// What a caller that has only an `Error` gets.
private func text(_ error: Error) -> String {
  return error.localizedDescription
}

/// A router that is not a `NanoHTTPSegmentRouter`, so that nothing can be merged with it.
private final class OtherRouter: NanoHTTPRouter {
  func register(_ method: String?, path: String, handler: NanoHTTPRequestHandler?) {}
  func merge(_ router: NanoHTTPRouter, withPrefix prefix: String) throws {}
  func route(_ method: String, path: String) -> ([String: String], NanoHTTPRequestHandler)? { return nil }
  func routes() -> [String] { return [] }
}

final class LocalizedErrorTests: XCTestCase {

  /// Compiles only for types that conform to `LocalizedError`.
  private func isLocalized<E: LocalizedError>(_ type: E.Type) -> Bool {
    return true
  }

  func testEveryErrorTypeOfTheLibraryIsLocalized() {
    XCTAssertTrue(isLocalized(NanoHTTPError.self))
    XCTAssertTrue(isLocalized(NanoHTTPParserError.self))
    XCTAssertTrue(isLocalized(NanoHTTPRouterError.self))
    XCTAssertTrue(isLocalized(NanoSocketError.self))
    XCTAssertTrue(isLocalized(NanoFileError.self))
    XCTAssertTrue(isLocalized(NanoHTTPResponse.ResponseError.self))
    XCTAssertTrue(isLocalized(NanoWebSocketSession.WsError.self))
    XCTAssertTrue(isLocalized(NanoWebSocketSession.Control.self))
    XCTAssertTrue(isLocalized(NanoHTTPCookie.Invalid.self))
  }

  // MARK: NanoHTTPError

  func testAnHTTPErrorIsItsStatusAndItsMessage() {
    XCTAssertEqual(text(NanoHTTPError.notFound("There is no item 7")), "404 Not Found: There is no item 7")
    XCTAssertEqual(text(NanoHTTPError.badRequest()), "400 Bad Request")
    XCTAssertEqual(text(NanoHTTPError.badRequest("")), "400 Bad Request")
    XCTAssertEqual(text(NanoHTTPError.tooManyRequests("slow down", retryAfter: 3)), "429 Too Many Requests: slow down")
    XCTAssertEqual(text(NanoHTTPError(status: 799)), "799", "a status without a reason phrase")
    XCTAssertEqual(text(NanoHTTPError(status: 799, message: "odd")), "799: odd")
    XCTAssertEqual(NanoHTTPError.conflict("x").errorDescription, "409 Conflict: x")
  }

  func testTheDescriptionOfAnHTTPErrorStaysAsItWas() {
    XCTAssertEqual(NanoHTTPError.notFound("gone").description, "NanoHTTPError(404 Not Found: gone)")
    XCTAssertEqual("\(NanoHTTPError.notFound("gone"))", "NanoHTTPError(404 Not Found: gone)")
    XCTAssertEqual(NanoHTTPError.badRequest().description, "NanoHTTPError(400 Bad Request)")
  }

  // MARK: Sockets and files

  func testSocketErrorsSayWhatFailedAndWhy() {
    let cases: [(NanoSocketError, String)] = [
      (.socketCreationFailed("Too many open files"), "Unable to create a socket: Too many open files"),
      (.socketSettingReUseAddrFailed("Bad file descriptor"),
       "Unable to set SO_REUSEADDR on the socket: Bad file descriptor"),
      (.bindFailed("Address already in use"), "Unable to bind the socket to the address: Address already in use"),
      (.listenFailed("Operation not supported"), "Unable to listen on the socket: Operation not supported"),
      (.writeFailed("Broken pipe"), "Unable to write to the socket: Broken pipe"),
      (.getPeerNameFailed("Socket is not connected"),
       "Unable to determine the address of the peer: Socket is not connected"),
      (.convertingPeerNameFailed, "Unable to convert the address of the peer"),
      (.getNameInfoFailed("nodename nor servname provided"),
       "Unable to convert an address into text: nodename nor servname provided"),
      (.acceptFailed("Software caused connection abort"),
       "Unable to accept a connection: Software caused connection abort"),
      (.recvFailed("Connection reset by peer"), "Unable to read from the socket: Connection reset by peer"),
      (.getSockNameFailed("Bad file descriptor"),
       "Unable to determine the local address of the socket: Bad file descriptor"),
      (.timedOut, "The socket did not finish reading or writing in time")
    ]
    for (error, expected) in cases {
      XCTAssertEqual(text(error), expected)
      XCTAssertEqual(error.errorDescription, expected)
    }
  }

  func testASocketErrorWithoutAReasonHasNoColon() {
    XCTAssertEqual(text(NanoSocketError.bindFailed("")), "Unable to bind the socket to the address")
    XCTAssertEqual(text(NanoSocketError.recvFailed("")), "Unable to read from the socket")
  }

  func testTheErrorOfAServerThatCannotBeStartedIsReadable() {
    let server = NanoHTTPServer()
    server.configuration.listenAddress = .address("127.0.0.1x")
    XCTAssertThrowsError(try server.start(0)) { error in
      XCTAssertTrue(text(error).hasPrefix("Unable to bind the socket to the address: "), text(error))
      XCTAssertTrue(text(error).contains("invalid listen address"), text(error))
      XCTAssertFalse(text(error).contains("The operation couldn"), "not the generic text of Foundation")
    }
  }

  func testAFileErrorHasTheDescriptionOfTheSystem() {
    XCTAssertEqual(text(NanoFileError.error(ENOENT)), "The file operation failed: No such file or directory")
    XCTAssertEqual(text(NanoFileError.error(0)), "The file operation failed", "errno does not say why")
    XCTAssertThrowsError(try NanoFile(path: "/nanohttp-test-no-such-directory/file")) { error in
      XCTAssertEqual(text(error), "The file operation failed: No such file or directory")
    }
  }

  // MARK: Requests

  func testParserErrorsSayWhatIsWrongWithTheRequest() {
    let cases: [(NanoHTTPParserError, String)] = [
      (.invalidStatusLine("GET"), #"The request line is not of the form METHOD TARGET VERSION: "GET""#),
      (.requestLineTooLong, "The request line is too long"),
      (.headerLineTooLong, "A header line is too long"),
      (.headersTooLarge, "The request line and the headers are too large"),
      (.invalidContentLength, "The Content-Length header is not a number"),
      (.negativeContentLength, "The Content-Length header is negative"),
      (.bodyTooLarge, "The body of the request is larger than the limit"),
      (.unsupportedVersion("HTTP/2"), #"The protocol version "HTTP/2" is not supported (HTTP/1.0 and HTTP/1.1 are)"#),
      (.conflictingFraming, "The request has a Content-Length and a Transfer-Encoding header"),
      (.unsupportedTransferEncoding("gzip"), #"The transfer encoding "gzip" is not supported (only chunked is)"#),
      (.invalidChunk, "The body of the request is not a valid sequence of chunks"),
      (.expectationFailed("102-processing"),
       #"The expectation "102-processing" of the request cannot be met (only 100-continue can)"#)
    ]
    for (error, expected) in cases {
      XCTAssertEqual(text(error), expected)
      XCTAssertEqual(error.errorDescription, expected)
    }
  }

  /// The text that a client sent can hold anything: it must not reach a log with its control characters.
  func testTextFromTheClientIsQuotedAndEscaped() {
    let nasty = "GET /\u{1B}[31m\nX-Injected: yes\u{0} HTTP/1.1"
    let errors: [NanoHTTPParserError] = [.invalidStatusLine(nasty),
                                         .unsupportedVersion(nasty),
                                         .unsupportedTransferEncoding(nasty),
                                         .expectationFailed(nasty)]
    for error in errors {
      let description = text(error)
      XCTAssertTrue(description.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 },
                    "\(String(reflecting: description))")
      XCTAssertTrue(description.contains(#"\n"#), description)
    }
  }

  func testAMalformedRequestIsDescribedByTheParser() {
    var parser = NanoHTTPParser(socket: FileSocket("BAD\r\n\r\n"))
    XCTAssertThrowsError(try parser.readHttpRequest()) { error in
      XCTAssertEqual(error as? NanoHTTPParserError, .invalidStatusLine("BAD"))
      XCTAssertEqual(text(error), #"The request line is not of the form METHOD TARGET VERSION: "BAD""#)
    }
  }

  // MARK: Routers, responses, WebSockets, cookies

  func testRouterErrorsSayWhatFailed() throws {
    XCTAssertEqual(text(NanoHTTPRouterError.unableToMerge), "The routers could not be merged")
    XCTAssertEqual(text(NanoHTTPRouterError.incompatibleRouterForMerge),
                   "The router cannot be merged with a router of this type")
    XCTAssertThrowsError(try NanoHTTPSegmentRouter().merge(OtherRouter(), withPrefix: "/x")) { error in
      XCTAssertEqual(text(error), "The router cannot be merged with a router of this type")
    }
  }

  func testTheErrorOfABodyThatCannotBeWrittenIsReadable() {
    XCTAssertEqual(text(NanoHTTPResponse.ResponseError.invalidObject),
                   "The value of a .json body is neither Foundation JSON nor Encodable")
    XCTAssertThrowsError(try NanoHTTPResponse.Body.json(NSObject()).inline()) { error in
      XCTAssertEqual(text(error), "The value of a .json body is neither Foundation JSON nor Encodable")
    }
  }

  func testWebSocketErrorsSayWhatIsWrong() {
    typealias Ws = NanoWebSocketSession.WsError
    let cases: [(Ws, String)] = [
      (.unknownOpCode("15"), "A frame has an operation code that does not exist: 15"),
      (.unMaskedFrame("A client must mask all frames."), "A frame of the client is not masked: A client must mask all frames."),
      (.protocolError("Control frames must not be fragmented."),
       "The WebSocket protocol was violated: Control frames must not be fragmented."),
      (.invalidUTF8(""), "A text message is not valid UTF-8"),
      (.messageTooBig("Message exceeds 10 bytes."), "A frame or a message is larger than the limit: Message exceeds 10 bytes.")
    ]
    for (error, expected) in cases {
      XCTAssertEqual(text(error), expected)
    }
    XCTAssertEqual(text(NanoWebSocketSession.Control.close), "The client closed the connection")
  }

  func testACookieThatCannotBeSentSaysWhy() {
    XCTAssertThrowsError(try NanoHTTPCookie(name: "a b", value: "v").headerValue()) { error in
      XCTAssertEqual(text(error), "The cookie cannot be sent: the name is not a token")
      XCTAssertEqual("\(error)", "the name is not a token", "the description is as it was")
    }
  }

  // MARK: What does not change

  func testInterpolationOfAnErrorIsNotChanged() {
    // The log messages of the server interpolate errors: they keep the names of the cases.
    XCTAssertEqual("\(NanoSocketError.timedOut)", "timedOut")
    XCTAssertEqual("\(NanoSocketError.bindFailed("x"))", #"bindFailed("x")"#)
    XCTAssertEqual("\(NanoHTTPParserError.invalidChunk)", "invalidChunk")
    XCTAssertEqual("\(NanoHTTPResponse.ResponseError.invalidObject)", "invalidObject")
    XCTAssertEqual("\(NanoFileError.error(2))", "error(2)")
  }

  func testNSErrorAlsoUsesTheDescription() {
    let error: Error = NanoSocketError.timedOut
    XCTAssertEqual((error as NSError).localizedDescription, "The socket did not finish reading or writing in time")
  }

  /// A description made for people must not become what a client is told.
  func testTheServerStillAnswersOtherErrorsWithoutDetails() throws {
    try withTestServer(configure: { server in
      server.get["/fail"] = { _ in throw NanoSocketError.bindFailed("secret detail") }
    }) { _, port in
      let response = try RawClient.get("/fail", port: port)
      XCTAssertEqual(response.status, 500)
      XCTAssertFalse(response.bodyString.contains("secret"), response.bodyString)
      XCTAssertFalse(response.bodyString.contains("Unable to bind"), response.bodyString)
    }
  }
}
