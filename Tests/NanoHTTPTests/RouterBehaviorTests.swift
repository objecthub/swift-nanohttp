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

  /// 2.0 (finding H8): a variable matches exactly one segment. `/users/:id` used to answer `/users` as well,
  /// with an empty `id`; the empty match is meant for path variables only.
  func testAVariableDoesNotMatchAMissingSegment() {
    self.router.register(nil, path: "/users/:id", handler: handler("user"))
    self.router.register(nil, path: "/things/*", handler: handler("thing"))
    XCTAssertNil(try match("GET", "/users"))
    XCTAssertNil(try match("GET", "/users/"))
    XCTAssertNil(try match("GET", "/things"))
    XCTAssertEqual(try match("GET", "/users/7")?.params, ["id": "7"])
    XCTAssertEqual(try match("GET", "/things/7")?.label, "thing")
    XCTAssertNil(try match("GET", "/users/7/8"))
  }

  func testAVariableInTheMiddleNeedsItsSegment() {
    self.router.register(nil, path: "/a/:x/c", handler: handler("c"))
    XCTAssertNil(try match("GET", "/a/c"), "the path has no segment for the variable")
    XCTAssertEqual(try match("GET", "/a/b/c")?.params, ["x": "b"])
  }

  func testAPathVariableMayStandForNothing() {
    self.router.register(nil, path: "/files/::rest", handler: handler("files"))
    self.router.register(nil, path: "/any/**", handler: handler("any"))
    self.router.register(nil, path: "/mid/::p/end", handler: handler("mid"))
    XCTAssertEqual(try match("GET", "/files")?.params, ["rest": ""])
    XCTAssertEqual(try match("GET", "/any")?.label, "any")
    XCTAssertEqual(try match("GET", "/mid/end")?.params, ["p": ""])
    XCTAssertEqual(try match("GET", "/mid/a/b/end")?.params, ["p": "a/b"])
    XCTAssertNil(try match("GET", "/mid"), "the fixed segment after the path variable is missing")
  }

  func testAPathVariableAfterAVariableAndAfterAnotherPathVariable() {
    self.router.register(nil, path: "/u/:id/::rest", handler: handler("rest"))
    self.router.register(nil, path: "/p/::a/::b", handler: handler("both"))
    XCTAssertEqual(try match("GET", "/u/7")?.params, ["id": "7", "rest": ""])
    XCTAssertEqual(try match("GET", "/u/7/x/y")?.params, ["id": "7", "rest": "x/y"])
    XCTAssertNil(try match("GET", "/u"), "the variable still needs a segment")
    XCTAssertEqual(try match("GET", "/p")?.params, ["a": "", "b": ""], "two path variables may both be empty")
    XCTAssertEqual(try match("GET", "/p/x")?.params, ["a": "", "b": "x"], "the first one takes as little as it can")
  }

  /// 2.0 (finding H8): routes that could both match the same path are tried in the order in which they were registered.
  /// (They used to be tried in the order of a dictionary, which differs from run to run.)
  func testVariablesAtTheSamePlaceAreTriedInTheOrderOfTheirRegistration() {
    self.router.register(nil, path: "/a/:first", handler: handler("first"))
    self.router.register(nil, path: "/a/:second", handler: handler("second"))
    self.router.register(nil, path: "/a/*", handler: handler("star"))
    for _ in 0..<20 {
      XCTAssertEqual(try match("GET", "/a/1")?.label, "first")
      XCTAssertEqual(try match("GET", "/a/1")?.params, ["first": "1"])
    }
    let other = NanoHTTPSegmentRouter()
    other.register(nil, path: "/a/*", handler: handler("star"))
    other.register(nil, path: "/a/:second", handler: handler("second"))
    other.register(nil, path: "/a/:first", handler: handler("first"))
    XCTAssertEqual(try other.route("GET", path: "/a/1").map { try $0.1(NanoHTTPRequest(method: "GET", path: "/a/1")).capturedBody() }, "star")
  }

  func testBacktrackingGoesThroughTheVariablesInTheOrderOfTheirRegistration() {
    self.router.register(nil, path: "/a/:x/b", handler: handler("x-b"))
    self.router.register(nil, path: "/a/:y/c", handler: handler("y-c"))
    self.router.register(nil, path: "/a/:z", handler: handler("z"))
    XCTAssertEqual(try match("GET", "/a/1/b")?.params, ["x": "1"])
    XCTAssertEqual(try match("GET", "/a/1/c")?.params, ["y": "1"])
    XCTAssertEqual(try match("GET", "/a/1")?.params, ["z": "1"])
  }

  func testAMergeKeepsTheOrderOfWhatWasThereAndAppendsTheRest() throws {
    self.router.register(nil, path: "/a/:old", handler: handler("old"))
    let sub = NanoHTTPSegmentRouter()
    sub.register(nil, path: "/:new", handler: handler("new"))
    sub.register(nil, path: "/:old", handler: handler("old merged"))
    try self.router.merge(sub, withPrefix: "/a")
    XCTAssertEqual(try match("GET", "/a/1")?.label, "old merged", "the variable that was there first stays first")
    XCTAssertEqual(try match("GET", "/a/1")?.params, ["old": "1"])
  }

  func testManyStaticRoutesAreAllFound() {
    for index in 0..<500 {
      self.router.register("GET", path: "/api/v1/resource\(index)/items", handler: handler("r\(index)"))
    }
    for index in [0, 1, 249, 498, 499] {
      XCTAssertEqual(try match("GET", "/api/v1/resource\(index)/items")?.label, "r\(index)")
    }
    XCTAssertNil(try match("GET", "/api/v1/resource500/items"))
    XCTAssertEqual(self.router.routes().count, 500)
  }

  func testRoutesThatAreRegisteredLaterAreFoundAtOnce() {
    self.router.register("GET", path: "/a", handler: handler("a"))
    XCTAssertEqual(try match("GET", "/a")?.label, "a")
    XCTAssertNil(try match("GET", "/b"))
    self.router.register("GET", path: "/b", handler: handler("b"))
    XCTAssertEqual(try match("GET", "/b")?.label, "b")
    self.router.register("GET", path: "/a", handler: handler("a again"))
    XCTAssertEqual(try match("GET", "/a")?.label, "a again")
    self.router.register("GET", path: "/a", handler: nil)
    XCTAssertNil(try match("GET", "/a"))
  }

  /// Routing does not wait for other threads, and registering routes while requests are routed is safe (the
  /// thread sanitizer is the judge): every answer is a route that existed.
  func testRegisteringWhileRoutingIsSafe() {
    self.router.register("GET", path: "/stable/:id", handler: handler("stable"))
    let stop = StopFlag()
    let failures = FailureCounter()
    let writer = Thread {
      var index = 0
      while !stop.isSet {
        self.router.register("GET", path: "/dynamic\(index % 20)/:x", handler: self.handler("d"))
        if index % 3 == 0 {
          self.router.register("GET", path: "/dynamic\((index + 7) % 20)/:x", handler: nil)
        }
        let sub = NanoHTTPSegmentRouter()
        sub.register("GET", path: "/m\(index % 5)", handler: self.handler("m"))
        try? self.router.merge(sub, withPrefix: "/mounted")
        index += 1
      }
    }
    writer.start()
    DispatchQueue.concurrentPerform(iterations: 4) { _ in
      for index in 0..<20_000 {
        guard let found = self.router.route("GET", path: "/stable/\(index)"), found.0["id"] == "\(index)" else {
          failures.add()
          continue
        }
        _ = self.router.route("GET", path: "/dynamic\(index % 20)/1")
        _ = self.router.allowedMethods(path: "/mounted/m\(index % 5)")
      }
    }
    stop.set()
    XCTAssertEqual(failures.count, 0, "a route that was never removed was not found")
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

  // MARK: Raw values of variables

  private func raw(_ method: String,
                   _ path: String) -> (params: [String: String], rawParams: [String: String])? {
    return self.router.routeWithRawParams(method, path: path).map { ($0.params, $0.rawParams) }
  }

  func testRawValuesOfAMergedRoute() throws {
    let sub = NanoHTTPSegmentRouter()
    sub.register("GET", path: "/items/:id/::rest", handler: handler("item"))
    try self.router.merge(sub, withPrefix: "/api/v1")
    let found = raw("GET", "/api/v1/items/a%2Fb/c%20d/e%2Ff")
    XCTAssertEqual(found?.params, ["id": "a/b", "rest": "c d/e/f"])
    XCTAssertEqual(found?.rawParams, ["id": "a%2Fb", "rest": "c%20d/e%2Ff"])
  }

  func testRawValuesOfARouteMountedOnAServer() throws {
    let server = NanoHTTPServer()
    let sub = NanoHTTPSegmentRouter()
    sub.register("GET", path: "/items/:id", handler: handler("item"))
    try server.use("/api", router: sub)
    let request = NanoHTTPRequest(method: "GET", rawPath: "/api/items/a%2Fb", rawQuery: nil)
    _ = server.dispatch(request: request)
    XCTAssertEqual(request.rawParams, ["id": "a%2Fb"])
  }

  func testHeadIsAnsweredByTheRouteOfGetWithItsRawValues() {
    self.router.register("GET", path: "/p/:name", handler: handler("get"))
    self.router.register("GET", path: "/q/::path", handler: handler("get"))
    self.router.register("HEAD", path: "/own/:name", handler: handler("head"))
    self.router.register("GET", path: "/own/:name", handler: handler("get"))
    self.router.register(nil, path: "/any/:name", handler: handler("any"))
    XCTAssertEqual(raw("HEAD", "/p/a%2Fb")?.params, ["name": "a/b"])
    XCTAssertEqual(raw("HEAD", "/p/a%2Fb")?.rawParams, ["name": "a%2Fb"])
    XCTAssertEqual(raw("HEAD", "/q/caf%C3%A9/x%20y")?.rawParams, ["path": "caf%C3%A9/x%20y"])
    XCTAssertEqual(raw("HEAD", "/own/a%2Fb")?.rawParams, ["name": "a%2Fb"])
    XCTAssertEqual(raw("HEAD", "/any/a%2Fb")?.rawParams, ["name": "a%2Fb"])
    XCTAssertEqual(raw("POST", "/any/a%2Fb")?.rawParams, ["name": "a%2Fb"])
    XCTAssertNil(raw("POST", "/p/a%2Fb"))
  }

  func testAPathWithAnInvalidPercentSequenceStillMatchesNoRoute() throws {
    self.router.register(nil, path: "/p/:name", handler: handler("p"))
    self.router.register(nil, path: "/q/::path", handler: handler("q"))
    self.router.register(nil, path: "/*/x", handler: handler("x"))
    for path in ["/p/%zz", "/p/%", "/p/a%2", "/p/%FF", "/q/a/%zz", "/q/%C3", "/%zz/x"] {
      XCTAssertNil(self.router.routeWithRawParams("GET", path: path), path)
      XCTAssertNil(self.router.routeWithRawParams("HEAD", path: path), path)
      XCTAssertNil(self.router.route("GET", path: path), path)
      XCTAssertEqual(self.router.allowedMethods(path: path), [], path)
    }
  }

  func testNoVariablesHaveNoRawValues() {
    self.router.register(nil, path: "/plain/path", handler: handler("plain"))
    self.router.register(nil, path: "/", handler: handler("root"))
    XCTAssertEqual(raw("GET", "/plain/path")?.rawParams, [:])
    XCTAssertEqual(raw("GET", "/")?.rawParams, [:])
  }

  func testARequestThatWasCreatedByHandHasNoRawValues() {
    XCTAssertEqual(NanoHTTPRequest(method: "GET", path: "/a%2Fb").rawParams, [:])
    XCTAssertEqual(NanoHTTPRequest(method: "GET", rawPath: "/a%2Fb", rawQuery: nil).rawParams, [:])
  }

  func testASubclassThatChangesRoutingOverridesTheFunctionTheServerCalls() throws {
    final class Lowercase: NanoHTTPSegmentRouter {
      override func routeWithRawParams(_ method: String, path: String)
        -> (params: [String: String],
            rawParams: [String: String],
            handler: NanoHTTPRequestHandler)? {
        return super.routeWithRawParams(method, path: path.lowercased())
      }
    }
    let router = Lowercase()
    router.register(nil, path: "/p/:name", handler: handler("p"))
    XCTAssertEqual(router.route("GET", path: "/P/AB")?.0, ["name": "ab"])
    XCTAssertEqual(router.routeWithRawParams("GET", path: "/P/A%2fB")?.rawParams, ["name": "a%2fb"])
  }

  // MARK: Routers that do not know the raw values

  /// A router that implements only what the protocol required in 2.1.1.
  private final class FixedRouter: NanoHTTPRouter {
    func register(_ method: String?, path: String, handler: NanoHTTPRequestHandler?) {}
    func merge(_ router: NanoHTTPRouter, withPrefix prefix: String) throws {}
    func routes() -> [String] { return ["/*"] }
    func route(_ method: String, path: String) -> ([String: String], NanoHTTPRequestHandler)? {
      guard path.hasPrefix("/x/") else {
        return nil
      }
      return (["name": "decoded"], { request in
        .ok(.text("\(request.params["name"] ?? "-")|\(request.rawParams.count)"))
      })
    }
  }

  func testTheDefaultOfARouterHasTheDecodedValuesAndNoRawValues() throws {
    let router = FixedRouter()
    let found = router.routeWithRawParams("GET", path: "/x/a%2Fb")
    XCTAssertEqual(found?.params, ["name": "decoded"])
    XCTAssertEqual(found?.rawParams, [:])
    XCTAssertNil(router.routeWithRawParams("GET", path: "/y/a"))
    let request = NanoHTTPRequest(method: "GET", path: "/x/a%2Fb")
    request.params = found?.params ?? [:]
    request.rawParams = found?.rawParams ?? ["-": "-"]
    XCTAssertEqual(try found?.handler(request).capturedBody(), "decoded|0")
  }

  func testAServerWithSuchARouterLeavesTheRawValuesEmpty() throws {
    final class FixedServer: NanoHTTPServer {
      override class func initialRouter() -> NanoHTTPRouter {
        return FixedRouter()
      }
    }
    for layers in [0, 1] {
      let server = FixedServer()
      if layers > 0 {
        server.middleware.append { request, next in try next(request) }
      }
      let request = NanoHTTPRequest(method: "GET", rawPath: "/x/a%2Fb", rawQuery: nil)
      let (params, handler) = server.dispatch(request: request)
      request.params = params
      XCTAssertEqual(try handler(request).capturedBody(), "decoded|0", "\(layers) middleware")
      XCTAssertEqual(request.params, ["name": "decoded"])
      XCTAssertEqual(request.rawParams, [:])
    }
  }

}

private final class StopFlag {
  private let lock = NSLock()
  private var value = false

  func set() {
    self.lock.lock()
    self.value = true
    self.lock.unlock()
  }

  var isSet: Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.value
  }
}

private final class FailureCounter {
  private let lock = NSLock()
  private var value = 0

  func add() {
    self.lock.lock()
    self.value += 1
    self.lock.unlock()
  }

  var count: Int {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.value
  }
}
