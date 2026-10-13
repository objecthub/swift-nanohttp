//
//  RouterBehaviorTests.swift
//  NanoHTTPTests
//
//  Characterization tests for `NanoHTTPSegmentRouter` / `NanoHTTPServer` routing. They pin the
//  behavior the framework has today (including two questionable details, marked "DECISION")
//  so that refactorings of the router cannot change it unnoticed. Complements the original
//  HTTPRouterTests.swift.
//

import XCTest
@testable import NanoHTTP

final class RouterBehaviorTests: XCTestCase {
  var router: NanoHTTPSegmentRouter!

  override func setUp() {
    super.setUp()
    self.router = NanoHTTPSegmentRouter()
  }

  private func handler(_ label: String) -> NanoHTTPRequestHandler {
    return { _ in .ok(.text(label)) }
  }

  /// Routes `path` and returns the label of the matched handler plus the captured parameters.
  private func match(_ method: String, _ path: String) throws -> (label: String, params: [String: String])? {
    guard let (params, handler) = self.router.route(method, path: path) else {
      return nil
    }
    return (try handler(NanoHTTPRequest(method: method, path: path)).capturedBody(), params)
  }

  func testMethodSpecificRouteWinsOverAnyMethodRoute() {
    self.router.register(nil, path: "/x", handler: handler("any"))
    self.router.register("POST", path: "/x", handler: handler("post"))
    XCTAssertEqual(try match("POST", "/x")?.label, "post")
    XCTAssertEqual(try match("GET", "/x")?.label, "any")
    XCTAssertEqual(try match("DELETE", "/x")?.label, "any")
  }

  func testMethodSpecificRouteDoesNotAnswerOtherMethods() {
    self.router.register("GET", path: "/x", handler: handler("get"))
    XCTAssertNil(try match("POST", "/x"))
  }

  func testStaticSegmentBeatsVariableAndRoutingBacktracks() {
    self.router.register(nil, path: "/a/b/c", handler: handler("static"))
    self.router.register(nil, path: "/a/:v/d", handler: handler("variable"))
    XCTAssertEqual(try match("GET", "/a/b/c")?.label, "static")
    XCTAssertEqual(try match("GET", "/a/b/d")?.label, "variable") // static branch fails, backtrack
    XCTAssertEqual(try match("GET", "/a/b/d")?.params, ["v": "b"])
  }

  func testNamedVariableValuesArePercentDecoded() {
    self.router.register(nil, path: "/u/:name", handler: handler("u"))
    XCTAssertEqual(try match("GET", "/u/J%C3%BCrgen%20M")?.params["name"], "Jürgen M")
  }

  /// 2.0: path variables are decoded like all others (they were left raw in 1.x, and the file handlers decoded them).
  func testPathVariableCapturesRemainingSegmentsDecoded() {
    self.router.register(nil, path: "/files/::rest", handler: handler("files"))
    XCTAssertEqual(try match("GET", "/files/a/b%20c/d.txt")?.params["rest"], "a/b c/d.txt")
  }

  func testPathVariableMayBeEmpty() {
    self.router.register(nil, path: "/files/::rest", handler: handler("files"))
    XCTAssertEqual(try match("GET", "/files")?.params["rest"], "")
    XCTAssertEqual(try match("GET", "/files/")?.params["rest"], "")
  }

  func testTrailingAndDuplicateSlashesAreIgnored() {
    self.router.register(nil, path: "/a/b", handler: handler("ab"))
    XCTAssertNotNil(try match("GET", "/a/b/"))
    XCTAssertNotNil(try match("GET", "//a///b"))
  }

  func testUndecodablePercentSequenceDoesNotMatch() {
    self.router.register(nil, path: "/a/:v", handler: handler("v"))
    XCTAssertNil(try match("GET", "/a/%zz"))
  }

  func testQueryStringInRoutedPathIsIgnored() {
    self.router.register(nil, path: "/a", handler: handler("a"))
    XCTAssertNotNil(try match("GET", "/a?x=1"))
  }

  /// DECISION (finding H8): a `:var` / `*` placeholder also matches a *missing* trailing segment.
  /// The "empty match" change (commit 2ad983b) was probably meant for `::var` / `**` only.
  /// Pinned as-is; decide when the router is touched.
  func testSingleSegmentVariableMatchesMissingTrailingSegment_currentBehavior() {
    self.router.register(nil, path: "/users/:id", handler: handler("user"))
    XCTAssertEqual(try match("GET", "/users")?.params, ["id": ""])
    XCTAssertEqual(try match("GET", "/users/")?.params, ["id": ""])
  }

  func testRoutesListsRegisteredPatterns() {
    self.router.register(nil, path: "/a", handler: handler("a"))
    self.router.register("GET", path: "/b/:x", handler: handler("b"))
    self.router.register("GET", path: "/c/::rest", handler: handler("c"))
    self.router.register("GET", path: "/d/*/e/**", handler: handler("d"))
    XCTAssertEqual(Set(self.router.routes()), ["/a", "/b/:x", "/c/::rest", "/d/*/e/**"])
  }

  func testUnregisteringAHandler() {
    self.router.register(nil, path: "/a", handler: handler("a"))
    self.router.register(nil, path: "/a", handler: nil)
    XCTAssertNil(try match("GET", "/a"))
  }

  func testMergeMountsASubRouterUnderAPrefix() throws {
    let sub = NanoHTTPSegmentRouter()
    sub.register("GET", path: "/items/:id", handler: handler("item"))
    sub.register(nil, path: "/", handler: handler("root"))
    try self.router.merge(sub, withPrefix: "/api/v1")
    XCTAssertEqual(try match("GET", "/api/v1/items/7")?.params, ["id": "7"])
    XCTAssertEqual(try match("GET", "/api/v1")?.label, "root")
    XCTAssertNil(try match("GET", "/items/7"))
  }

  func testMergeCopiesInsteadOfSharingSubRouterState() throws {
    let sub = NanoHTTPSegmentRouter()
    sub.register(nil, path: "/a", handler: handler("first"))
    try self.router.merge(sub, withPrefix: "/p")
    sub.register(nil, path: "/a", handler: handler("second")) // later change to the sub-router
    XCTAssertEqual(try match("GET", "/p/a")?.label, "first")
  }

  func testServerUseMountsSubRouter() throws {
    let server = NanoHTTPServer()
    let sub = NanoHTTPSegmentRouter()
    sub.register("GET", path: "/ping", handler: handler("pong"))
    try server.use("/sub", router: sub)
    XCTAssertEqual(server.routes, ["/sub/ping"])
  }

  func testRegistrationDuringConcurrentRoutingIsSafe() {
    self.router.register(nil, path: "/stable", handler: handler("stable"))
    let group = DispatchGroup()
    for worker in 0..<4 {
      group.enter()
      DispatchQueue.global().async {
        for index in 0..<500 {
          if worker % 2 == 0 {
            self.router.register(nil, path: "/w\(worker)/\(index)", handler: self.handler("x"))
          } else {
            XCTAssertNotNil(self.router.route("GET", path: "/stable"))
          }
        }
        group.leave()
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
  }
}
