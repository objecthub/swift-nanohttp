//
//  ResponseHelperTests.swift
//  NanoHTTPTests
//
//  The helpers that build responses: JSON from any `Encodable`, the redirects (303, 307, 308) and the status
//  responses that were missing (204, 304, 413, 422, 503), on the wire in both threading modes.
//

import XCTest
@testable import NanoHTTP

private struct Item: Encodable {
  let id: Int
  let name: String
}

private struct Unencodable: Encodable {
  struct Failure: Error {}
  func encode(to encoder: Encoder) throws {
    throw Failure()
  }
}

final class JSONResponseTests: XCTestCase {

  private func body(_ response: NanoHTTPResponse) -> String {
    if case .data(let data, _) = response.body {
      return String(decoding: data, as: UTF8.self)
    }
    return "(no data)"
  }

  func testAModelBecomesAJSONResponse() throws {
    let response = try NanoHTTPResponse.json(Item(id: 7, name: "Lamp"), encoder: {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      return encoder
    }())
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(self.body(response), "{\"id\":7,\"name\":\"Lamp\"}")
    XCTAssertEqual(response.allHeaders()["Content-Type"], "application/json")
  }

  func testStatusHeadersAndEncoderAreYours() throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    struct Profile: Encodable { let firstName: String }
    let response = try NanoHTTPResponse.json(Profile(firstName: "Ada"),
                                             status: 201,
                                             headers: ["Location": "/profiles/1"],
                                             encoder: encoder)
    XCTAssertEqual(response.statusCode, 201)
    XCTAssertEqual(response.headers["Location"], "/profiles/1")
    XCTAssertEqual(self.body(response), "{\"first_name\":\"Ada\"}")
  }

  func testCollectionsAndSingleValuesAreJSONToo() throws {
    XCTAssertEqual(self.body(try .json([1, 2, 3])), "[1,2,3]")
    XCTAssertEqual(self.body(try .json(["a": 1])), "{\"a\":1}")
    XCTAssertEqual(self.body(try .json("text")), "\"text\"")
    XCTAssertEqual(self.body(try .json(5)), "5")
    XCTAssertEqual(self.body(try .json(Optional<Int>.none)), "null")
    let sorted = JSONEncoder()
    sorted.outputFormatting = .sortedKeys
    XCTAssertEqual(self.body(try .json([Item(id: 1, name: "a€\"")], encoder: sorted)), "[{\"id\":1,\"name\":\"a€\\\"\"}]")
  }

  func testTheExistingJSONBodyIsNotAffected() throws {
    // `.json(Any)` of a body, with its objects of Foundation, still works next to the helper.
    let response = NanoHTTPResponse.ok(.json(["a": 1]))
    let head = NanoHTTPResponseSerializer.head(response, framing: .none)
    XCTAssertTrue(String(decoding: head, as: UTF8.self).contains("Content-Type: application/json"))
  }

  func testAnEncoderThatFailsGivesTheUsualErrorResponse() throws {
    XCTAssertThrowsError(try NanoHTTPResponse.json(Unencodable()))
    let logger = CapturingLogger()
    try withTestServer(configure: { server in
      server.configuration.logger = logger
      server.get["/ok"] = { _ in try .json(Item(id: 1, name: "x")) }
      server.get["/fail"] = { _ in try .json(Unencodable()) }
    }) { _, port in
      let good = try RawClient.get("/ok", port: port)
      XCTAssertEqual(good.status, 200)
      XCTAssertEqual(good.header("Content-Type"), "application/json")
      let bad = try RawClient.get("/fail", port: port)
      XCTAssertEqual(bad.status, 500)
      XCTAssertEqual(String(decoding: bad.body, as: UTF8.self), "Internal Server Error", "without the details of the error")
      XCTAssertTrue(logger.waitFor("/fail", level: .error), "\(logger.messages)")
    }
  }
}

/// A `.json` body takes what `JSONSerialization` accepts (dictionaries and arrays of Foundation values), and any value that is
/// `Encodable`, which is written by a `JSONEncoder`: a model, a collection of models, a recursive enum for JSON values (like
/// the `JSON` type of the package DynamicJSON, which `JSONSerialization` does not know).
final class JSONBodyTests: XCTestCase {
  
  /// A recursive JSON value, written like DynamicJSON's `JSON`: `Encodable`, and no Foundation object.
  private indirect enum Json: Encodable {
    case null
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([Json])
    case object([String: Json])
    
    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
      }
    }
  }
  
  private struct Item: Encodable {
    let id: Int
    let tags: [String]
  }
  
  private final class NoJSON {}
  
  /// What the body writes, read back as Foundation values (the order of the keys is not specified).
  private func written(_ object: Any, file: StaticString = #filePath, line: UInt = #line) -> Any? {
    do {
      guard case .data(let data)? = try NanoHTTPResponse.Body.json(object).inline() else {
        XCTFail("a .json body is in memory", file: file, line: line)
        return nil
      }
      return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      XCTFail("\(error)", file: file, line: line)
      return nil
    }
  }
  
  private func isEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
    return (lhs as? NSObject)?.isEqual(rhs) ?? false
  }
  
  func testAModelThatIsEncodableBecomesJSON() {
    XCTAssertTrue(isEqual(written(Item(id: 7, tags: ["a", "b"])), ["id": 7, "tags": ["a", "b"]] as NSDictionary))
  }
  
  func testARecursiveEnumForJSONValuesBecomesJSON() {
    let value = Json.object(["name": .string("Ada"), "age": .integer(36), "pi": .number(3.5), "ok": .boolean(true),
                             "none": .null, "list": .array([.integer(1), .string("x"), .array([])])])
    let expected: NSDictionary = ["name": "Ada", "age": 36, "pi": 3.5, "ok": true, "none": NSNull(), "list": [1, "x", []] as NSArray]
    XCTAssertTrue(isEqual(written(value), expected))
  }
  
  func testCollectionsOfEncodableValuesBecomeJSON() {
    XCTAssertTrue(isEqual(written([Json.integer(1), Json.string("two"), Json.null]), [1, "two", NSNull()] as NSArray))
    XCTAssertTrue(isEqual(written(["a": Json.boolean(false)]), ["a": false] as NSDictionary))
    XCTAssertTrue(isEqual(written([Item(id: 1, tags: [])]), [["id": 1, "tags": []]] as NSArray))
  }
  
  func testSingleValuesAtTheTopLevelAreJSONToo() {
    XCTAssertTrue(isEqual(written("text"), "text" as NSString))
    XCTAssertTrue(isEqual(written(5), 5 as NSNumber))
    XCTAssertTrue(isEqual(written(true), true as NSNumber))
    XCTAssertTrue(isEqual(written(1.5), 1.5 as NSNumber))
    XCTAssertTrue(isEqual(written(Optional<Int>.none as Any), NSNull()))
  }
  
  func testFoundationValuesAreWrittenAsBefore() {
    let object: [String: Any] = ["a": 1, "b": [true, NSNull(), "x"], "c": ["d": 2.5]]
    XCTAssertTrue(isEqual(written(object), object as NSDictionary))
    XCTAssertTrue(isEqual(written([1, 2, 3] as [Any]), [1, 2, 3] as NSArray))
    // A dictionary of values of different types is no `Encodable`, and goes through `JSONSerialization`.
    XCTAssertTrue(isEqual(written(["x": "y", "n": NSNumber(value: 3)]), ["x": "y", "n": 3] as NSDictionary))
  }
  
  func testDatesAreWrittenAsTheDefaultOfJSONEncoderDoes() {
    // A date by itself is `Encodable`: seconds since 2001, like `JSONEncoder` writes it unless you choose a strategy
    // (`NanoHTTPResponse.json(_:status:headers:encoder:)` takes an encoder).
    XCTAssertTrue(isEqual(written(Date(timeIntervalSinceReferenceDate: 60)), 60 as NSNumber))
  }
  
  func testWhatIsNeitherFoundationJSONNorEncodableIsRefused() {
    for value in [NoJSON(), NSObject(), ["when": Date()] as [String: Any], ["x": NoJSON()] as [String: Any]] as [Any] {
      XCTAssertThrowsError(try NanoHTTPResponse.Body.json(value).inline(), "\(value)") { error in
        XCTAssertEqual(error as? NanoHTTPResponse.ResponseError, .invalidObject, "\(value)")
      }
    }
  }
  
  func testAnErrorOfTheEncoderIsThrown() {
    XCTAssertThrowsError(try NanoHTTPResponse.Body.json(Double.nan).inline())
    XCTAssertThrowsError(try NanoHTTPResponse.Body.json(Unencodable()).inline())
  }
  
  func testTheBodyWritesTheSameBytesWhenItIsWrittenByContent() {
    // `capturedBody()` goes the way of the writers (`content()`), the server the one of `inline()`; both give the same.
    let response = NanoHTTPResponse(statusCode: 200, body: .json(Json.object(["k": .integer(1)])))
    XCTAssertEqual(response.capturedBody(), "{\"k\":1}")
  }
  
  func testAServerAnswersWithAnEncodableBody() throws {
    let logger = CapturingLogger()
    try withTestServer(configure: { server in
      server.configuration.logger = logger
      server.get["/dynamic"] = { _ in .ok(.json(Json.object(["items": .array([.integer(1), .integer(2)])]))) }
      server.get["/model"] = { _ in .ok(.json(Item(id: 3, tags: ["x"]))) }
      server.get["/nothing"] = { _ in .ok(.json(NoJSON())) }
    }) { _, port in
      for (path, expected) in [("/dynamic", ["items": [1, 2]] as NSDictionary), ("/model", ["id": 3, "tags": ["x"]] as NSDictionary)] {
        let response = try RawClient.get(path, port: port)
        XCTAssertEqual(response.status, 200, path)
        XCTAssertEqual(response.header("Content-Type"), "application/json", path)
        XCTAssertTrue(isEqual(try JSONSerialization.jsonObject(with: Data(response.body)), expected), path)
      }
      let refused = try RawClient.get("/nothing", port: port)
      XCTAssertEqual(refused.status, 500)
      XCTAssertTrue(logger.waitFor("Unable to produce the body", level: .error), "\(logger.messages)")
    }
  }
}

final class StatusHelperTests: XCTestCase {

  func testTheRedirects() throws {
    let table: [(NanoHTTPResponse, Int)] = [
      (.seeOther("/done"), 303),
      (.temporaryRedirect("/done"), 307),
      (.permanentRedirect("/done"), 308),
      (.movedTemporarily("/done"), 307),
      (.movedPermanently("/done"), 301)
    ]
    for (response, status) in table {
      XCTAssertEqual(response.statusCode, status)
      XCTAssertEqual(response.headers["Location"], "/done")
      XCTAssertEqual(response.body.contentType(), nil)
    }
    XCTAssertEqual(NanoHTTPResponse.seeOther("/x", ["Cache-Control": "no-store"]).headers["Cache-Control"], "no-store")
    XCTAssertEqual(NanoHTTPResponse.permanentRedirect("/x", ["A": "b"]).headers.count, 2)
  }

  func testALocationCannotInjectHeaders() {
    for response in [NanoHTTPResponse.seeOther("/a\r\nX-Evil: 1"), .temporaryRedirect("/a\r\nX-Evil: 1"), .permanentRedirect("/a\r\nX-Evil: 1")] {
      let head = String(decoding: NanoHTTPResponseSerializer.head(response, framing: .none), as: UTF8.self)
      XCTAssertFalse(head.contains("\r\nX-Evil"), head)
      XCTAssertTrue(head.contains("Location: /a  X-Evil: 1"), head)
    }
  }

  func testTheStatusResponses() throws {
    let table: [(String, NanoHTTPResponse, Int, String)] = [
      ("/204", .noContent(), 204, "No Content"),
      ("/304", .notModified(headers: ["ETag": "\"x\""]), 304, "Not Modified"),
      ("/413", .payloadTooLarge(.text("too big")), 413, "Content Too Large"),
      ("/422", .unprocessableContent(.text("name is missing")), 422, "Unprocessable Content"),
      ("/503", .serviceUnavailable(headers: ["Retry-After": "30"], .text("try later")), 503, "Service Unavailable")
    ]
    for threading in [NanoHTTPServerIO.Configuration.Threading.perConnection, .singleThread] {
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        for (path, response, _, _) in table {
          server.get[path] = { _ in response }
        }
      }) { _, port in
        for (path, expected, status, reason) in table {
          let response = try RawClient.get(path, port: port)
          XCTAssertEqual(response.status, status, "\(path) \(threading)")
          XCTAssertEqual(response.reason, reason, path)
          XCTAssertEqual(response.body.count, expected.body.contentLength, path)
          if status == 204 || status == 304 {
            XCTAssertNil(response.header("Content-Length"), "no body, so no length: \(path)")
          }
        }
        XCTAssertEqual(try RawClient.get("/304", port: port).header("ETag"), "\"x\"")
        XCTAssertEqual(try RawClient.get("/503", port: port).header("Retry-After"), "30")
      }
    }
  }
}

/// The initializers of 2.0 are still there next to the ones that 2.1 added, and no call is ambiguous: the diff of the API
/// against 2.0.0 shows additions only.
final class InitializerCompatibilityTests: XCTestCase {
  
  func testTheInitializersOfAResponse() {
    XCTAssertEqual(NanoHTTPResponse(statusCode: 200).cookies.count, 0)
    XCTAssertEqual(NanoHTTPResponse(statusCode: 201, headers: ["A": "b"]).headers["A"], "b")
    XCTAssertEqual(NanoHTTPResponse(statusCode: 202, body: .text("x")).statusCode, 202)
    XCTAssertEqual(NanoHTTPResponse(statusCode: 203, headers: [:], body: .empty).statusCode, 203)
    let cookie = NanoHTTPCookie(name: "a", value: "1")
    XCTAssertEqual(NanoHTTPResponse(statusCode: 204, cookies: [cookie]).cookies, [cookie])
    XCTAssertEqual(NanoHTTPResponse(statusCode: 205, headers: ["A": "b"], cookies: [cookie]).cookies, [cookie])
    XCTAssertEqual(NanoHTTPResponse(statusCode: 206, headers: [:], body: .empty, cookies: [cookie]).cookies, [cookie])
    // The initializer of 2.0 can still be used as a function.
    let make: (Int, [String: String], NanoHTTPResponse.Body) -> NanoHTTPResponse = NanoHTTPResponse.init(statusCode:headers:body:)
    XCTAssertEqual(make(207, [:], .empty).statusCode, 207)
  }
  
  func testTheInitializersOfTheLimits() {
    XCTAssertEqual(NanoHTTPParser.Limits(), NanoHTTPParser.Limits(maxMultipartParts: 1000))
    XCTAssertEqual(NanoHTTPParser.Limits(maxBodyBytes: 5).maxBodyBytes, 5)
    XCTAssertEqual(NanoHTTPParser.Limits(maxLineLength: 1, maxHeaderBytes: 2, maxBodyBytes: 3).maxMultipartParts, 1000)
    XCTAssertEqual(NanoHTTPParser.Limits(maxMultipartParts: 7).maxMultipartHeaderBytes, 16 * 1024)
    let limits = NanoHTTPParser.Limits(maxLineLength: 1, maxHeaderBytes: 2, maxBodyBytes: 3,
                                       maxMultipartParts: 4, maxMultipartHeaderBytes: 5)
    XCTAssertEqual([limits.maxLineLength, limits.maxHeaderBytes, limits.maxBodyBytes,
                    limits.maxMultipartParts, limits.maxMultipartHeaderBytes], [1, 2, 3, 4, 5])
  }
}

private extension NanoHTTPResponse.Body {
  /// The number of bytes of a body in memory, for comparing with what arrives.
  var contentLength: Int {
    switch self {
      case .text(let text), .html(let text):
        return text.utf8.count
      case .data(let data, _):
        return data.count
      default:
        return 0
    }
  }
}
