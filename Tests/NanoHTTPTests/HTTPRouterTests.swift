//
//  NanoHTTPRouterTests.swift
//  NanoHTTPTests
//
//  Created by Matthias Zenger on 22/07/2024.
//  Based on `SwifterTestsHttpRouter` of framework `Swifter` by Damian Kołakowski.
//
//  Copyright © 2016 Damian Kołakowski. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  * Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
//
//  * Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
//  * Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software without
//    specific prior written permission.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
//  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
//  ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import XCTest
@testable import NanoHTTP

class HTTPRouterTests: XCTestCase {
  var router: NanoHTTPSegmentRouter!
  
  override func setUp() {
    super.setUp()
    router = NanoHTTPSegmentRouter()
  }
  
  override func tearDown() {
    router = nil
    super.tearDown()
  }
  
  func testNanoHTTPRouterSlashRoot() {
    router.register(nil, path: "/", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    XCTAssertNotNil(router.route("GET", path: "/"))
  }
  
  func testNanoHTTPRouterSimplePathSegments() {
    router.register(nil, path: "/a/b/c/d", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    XCTAssertNil(router.route("GET", path: "/"))
    XCTAssertNil(router.route("GET", path: "/a"))
    XCTAssertNil(router.route("GET", path: "/a/b"))
    XCTAssertNil(router.route("GET", path: "/a/b/c"))
    XCTAssertNotNil(router.route("GET", path: "/a/b/c/d"))
  }
  
  func testNanoHTTPRouterSinglePathSegmentWildcard() {
    router.register(nil, path: "/a/*/c/d", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    XCTAssertNil(router.route("GET", path: "/"))
    XCTAssertNil(router.route("GET", path: "/a"))
    XCTAssertNotNil(router.route("GET", path: "/a/foo/c/d"))
    XCTAssertNotNil(router.route("GET", path: "/a/b/c/d"))
    XCTAssertNil(router.route("GET", path: "/a/b"))
    XCTAssertNil(router.route("GET", path: "/a/b/foo/d"))
  }
  
  func testNanoHTTPRouterVariables() {
    router.register(nil, path: "/a/:arg1/:arg2/b/c/d/:arg3", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    XCTAssertNil(router.route("GET", path: "/"))
    XCTAssertNil(router.route("GET", path: "/a"))
    XCTAssertNil(router.route("GET", path: "/a/b/c/d"))
    XCTAssertEqual(router.route("GET", path: "/a/value1/value2/b/c/d/value3")?.0["arg1"], "value1")
    XCTAssertEqual(router.route("GET", path: "/a/value1/value2/b/c/d/value3")?.0["arg2"], "value2")
    XCTAssertEqual(router.route("GET", path: "/a/value1/value2/b/c/d/value3")?.0["arg3"], "value3")
  }
  
  func testNanoHTTPRouterMultiplePathSegmentWildcards() {
    router.register(nil, path: "/a/**/e/f/g", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    XCTAssertNil(router.route("GET", path: "/"))
    XCTAssertNil(router.route("GET", path: "/a"))
    XCTAssertNotNil(router.route("GET", path: "/a/b/c/d/e/f/g"))
    XCTAssertNotNil(router.route("GET", path: "/a/e/f/g"))
  }
  
  func testNanoHTTPRouterMultiplePathSegmentWildcardTail() {
    router.register(nil, path: "/a/b/**", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    XCTAssertNil(router.route("GET", path: "/"))
    XCTAssertNil(router.route("GET", path: "/a"))
    XCTAssertNotNil(router.route("GET", path: "/a/b/c/d/e/f/g"))
    XCTAssertNil(router.route("GET", path: "/a/e/f/g"))
  }
  
  func testNanoHTTPRouterEmptyTail() {
    router.register(nil, path: "/a/b/", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    router.register(nil, path: "/a/b/:var", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    XCTAssertNil(router.route("GET", path: "/"))
    XCTAssertNil(router.route("GET", path: "/a"))
    XCTAssertNotNil(router.route("GET", path: "/a/b/"))
    XCTAssertNil(router.route("GET", path: "/a/e/f/g"))
    XCTAssertEqual(router.route("GET", path: "/a/b/value1")?.0["var"], "value1")
    XCTAssertEqual(router.route("GET", path: "/a/b/")?.0["var"], nil)
  }
  
  func testNanoHTTPRouterPercentEncodedPathSegments() {
    router.register(nil, path: "/a/<>/^", handler: { _ in
      return .ok(.htmlBody("OK"))
    })
    XCTAssertNil(router.route("GET", path: "/"))
    XCTAssertNil(router.route("GET", path: "/a"))
    XCTAssertNotNil(router.route("GET", path: "/a/%3C%3E/%5E"))
  }
  
  func testNanoHTTPRouterHandlesOverlappingPaths() throws {
    let request = NanoHTTPRequest(method: "", path: "")
    let staticRouteExpectation = expectation(description: "Static Route")
    var foundStaticRoute = false
    router.register("GET", path: "a/b") { _ in
      foundStaticRoute = true
      staticRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let variableRouteExpectation = expectation(description: "Variable Route")
    var foundVariableRoute = false
    router.register("GET", path: "a/:id/c") { _ in
      foundVariableRoute = true
      variableRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let staticRouteResult = router.route("GET", path: "a/b")
    let staticRouterHandler = staticRouteResult?.1
    XCTAssertNotNil(staticRouteResult)
    _ = try staticRouterHandler?(request)
    let variableRouteResult = router.route("GET", path: "a/b/c")
    let variableRouterHandler = variableRouteResult?.1
    XCTAssertNotNil(variableRouteResult)
    _ = try variableRouterHandler?(request)
    waitForExpectations(timeout: 10, handler: nil)
    XCTAssertTrue(foundStaticRoute)
    XCTAssertTrue(foundVariableRoute)
  }
  
  func testNanoHTTPRouterHandlesOverlappingPathsInDynamicRoutes() throws {
    let request = NanoHTTPRequest(method: "", path: "")
    let firstVariableRouteExpectation = expectation(description: "First Variable Route")
    var foundFirstVariableRoute = false
    router.register("GET", path: "a/:id") { _ in
      foundFirstVariableRoute = true
      firstVariableRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let secondVariableRouteExpectation = expectation(description: "Second Variable Route")
    var foundSecondVariableRoute = false
    router.register("GET", path: "a/:id/c") { _ in
      foundSecondVariableRoute = true
      secondVariableRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let firstRouteResult = router.route("GET", path: "a/b")
    let firstRouterHandler = firstRouteResult?.1
    XCTAssertNotNil(firstRouteResult)
    _ = try firstRouterHandler?(request)
    let secondRouteResult = router.route("GET", path: "a/b/c")
    let secondRouterHandler = secondRouteResult?.1
    XCTAssertNotNil(secondRouteResult)
    _ = try secondRouterHandler?(request)
    waitForExpectations(timeout: 10, handler: nil)
    XCTAssertTrue(foundFirstVariableRoute)
    XCTAssertTrue(foundSecondVariableRoute)
  }
  
  func testNanoHTTPRouterShouldHandleOverlappingRoutesInTrail() throws {
    let request = NanoHTTPRequest(method: "", path: "")
    let firstVariableRouteExpectation = expectation(description: "First Variable Route")
    var foundFirstVariableRoute = false
    router.register("GET", path: "/a/:id") { _ in
      foundFirstVariableRoute = true
      firstVariableRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let secondVariableRouteExpectation = expectation(description: "Second Variable Route")
    var foundSecondVariableRoute = false
    router.register("GET", path: "/a") { _ in
      foundSecondVariableRoute = true
      secondVariableRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let thirdVariableRouteExpectation = expectation(description: "Third Variable Route")
    var foundThirdVariableRoute = false
    router.register("GET", path: "/a/:id/b") { _ in
      foundThirdVariableRoute = true
      thirdVariableRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let firstRouteResult = router.route("GET", path: "/a")
    let firstRouterHandler = firstRouteResult?.1
    XCTAssertNotNil(firstRouteResult)
    _ = try firstRouterHandler?(request)
    let secondRouteResult = router.route("GET", path: "/a/b")
    let secondRouterHandler = secondRouteResult?.1
    XCTAssertNotNil(secondRouteResult)
    _ = try secondRouterHandler?(request)
    let thirdRouteResult = router.route("GET", path: "/a/b/b")
    let thirdRouterHandler = thirdRouteResult?.1
    XCTAssertNotNil(thirdRouteResult)
    _ = try thirdRouterHandler?(request)
    waitForExpectations(timeout: 10, handler: nil)
    XCTAssertTrue(foundFirstVariableRoute)
    XCTAssertTrue(foundSecondVariableRoute)
    XCTAssertTrue(foundThirdVariableRoute)
  }
  
  func testNanoHTTPRouterHandlesOverlappingPathsInDynamicRoutesInTheMiddle() throws {
    let request = NanoHTTPRequest(method: "", path: "")
    let firstVariableRouteExpectation = expectation(description: "First Variable Route")
    var foundFirstVariableRoute = false
    router.register("GET", path: "/a/b/c/d/e") { _ in
      foundFirstVariableRoute = true
      firstVariableRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let secondVariableRouteExpectation = expectation(description: "Second Variable Route")
    var foundSecondVariableRoute = false
    router.register("GET", path: "/a/:id/f/g") { _ in
      foundSecondVariableRoute = true
      secondVariableRouteExpectation.fulfill()
      return NanoHTTPResponse.accepted()
    }
    let firstRouteResult = router.route("GET", path: "/a/b/c/d/e")
    let firstRouterHandler = firstRouteResult?.1
    XCTAssertNotNil(firstRouteResult)
    _ = try firstRouterHandler?(request)
    let secondRouteResult = router.route("GET", path: "/a/b/f/g")
    let secondRouterHandler = secondRouteResult?.1
    XCTAssertNotNil(secondRouteResult)
    _ = try secondRouterHandler?(request)
    waitForExpectations(timeout: 10, handler: nil)
    XCTAssertTrue(foundFirstVariableRoute)
    XCTAssertTrue(foundSecondVariableRoute)
  }

  // MARK: Raw values of variables

  /// The decoded and the raw values of the variables of the route for `path`, or `nil`.
  private func values(_ path: String,
                      method: String = "GET") -> (params: [String: String], rawParams: [String: String])? {
    return router.routeWithRawParams(method, path: path).map { ($0.params, $0.rawParams) }
  }

  func testAVariableHasItsRawSegmentNextToTheDecodedValue() {
    router.register(nil, path: "/p/:name", handler: { _ in .ok(.text("p")) })
    let cases: [(path: String, decoded: String, raw: String)] = [
      ("/p/caf%C3%A9", "café", "caf%C3%A9"),
      ("/p/a%2Fb", "a/b", "a%2Fb"),
      ("/p/a%20b%2Bc", "a b+c", "a%20b%2Bc"),
      ("/p/%252e%252e", "%2e%2e", "%252e%252e"),
      ("/p/a+b", "a+b", "a+b"),
      ("/p/a%2Fb?x=1", "a/b", "a%2Fb"),
      ("/p/plain", "plain", "plain"),
      ("/p/%61%62", "ab", "%61%62"),
      ("//p///a%2Fb//", "a/b", "a%2Fb")
    ]
    for (path, decoded, raw) in cases {
      let found = values(path)
      XCTAssertEqual(found?.params, ["name": decoded], path)
      XCTAssertEqual(found?.rawParams, ["name": raw], path)
    }
  }

  func testAPathVariableHasItsRawSegmentsJoinedWithSlashes() {
    router.register(nil, path: "/q/::path", handler: { _ in .ok(.text("q")) })
    let cases: [(path: String, decoded: String, raw: String)] = [
      ("/q/caf%C3%A9/x%20y", "café/x y", "caf%C3%A9/x%20y"),
      ("/q/a%2Fb/c", "a/b/c", "a%2Fb/c"),
      ("/q/a/b/c", "a/b/c", "a/b/c"),
      ("/q/%252e%252e/z", "%2e%2e/z", "%252e%252e/z"),
      ("/q/a+b/c%2Bd", "a+b/c+d", "a+b/c%2Bd"),
      ("/q/a%2Fb/c?x=1", "a/b/c", "a%2Fb/c"),
      ("/q//a///b%20c/", "a/b c", "a/b%20c"),
      ("/q", "", ""),
      ("/q/", "", ""),
      ("/q?x=1", "", "")
    ]
    for (path, decoded, raw) in cases {
      let found = values(path)
      XCTAssertEqual(found?.params, ["path": decoded], path)
      XCTAssertEqual(found?.rawParams, ["path": raw], path)
    }
  }

  func testAnEncodedSlashIsToldFromASeparatorByTheRawValue() {
    router.register(nil, path: "/q/::path", handler: { _ in .ok(.text("q")) })
    XCTAssertEqual(values("/q/a%2Fb/c")?.params, values("/q/a/b/c")?.params)
    XCTAssertNotEqual(values("/q/a%2Fb/c")?.rawParams, values("/q/a/b/c")?.rawParams)
  }

  /// The search for `/files/::path/edit` takes more segments for the path variable than the
  /// first attempt does; both values are taken from the segments that the search ends with.
  func testARawPathVariableFollowedByOtherSegmentsIsTakenWhereTheSearchBacktracks() {
    router.register(nil, path: "/files/::path/edit", handler: { _ in .ok(.text("edit")) })
    XCTAssertEqual(values("/files/a%2Fb/c/edit")?.params, ["path": "a/b/c"])
    XCTAssertEqual(values("/files/a%2Fb/c/edit")?.rawParams, ["path": "a%2Fb/c"])
    // `edit` is also a segment of the value
    XCTAssertEqual(values("/files/a%2Fb/edit/c%20d/edit")?.params, ["path": "a/b/edit/c d"])
    XCTAssertEqual(values("/files/a%2Fb/edit/c%20d/edit")?.rawParams, ["path": "a%2Fb/edit/c%20d"])
    XCTAssertEqual(values("/files/edit")?.params, ["path": ""])
    XCTAssertEqual(values("/files/edit")?.rawParams, ["path": ""])
    XCTAssertNil(values("/files/a%2Fb/c"))
  }

  /// A fixed segment is compared decoded; when its branch fails, the variable gets the segment
  /// as it was sent.
  func testARawVariableIsTakenWhereAFixedSegmentFailed() {
    router.register(nil, path: "/a/b c/e", handler: { _ in .ok(.text("fixed")) })
    router.register(nil, path: "/a/:v/d", handler: { _ in .ok(.text("variable")) })
    XCTAssertEqual(values("/a/b%20c/e")?.params, [:])
    XCTAssertEqual(values("/a/b%20c/e")?.rawParams, [:])
    XCTAssertEqual(values("/a/b%20c/d")?.params, ["v": "b c"])
    XCTAssertEqual(values("/a/b%20c/d")?.rawParams, ["v": "b%20c"])
  }

  func testARouteWithTwoVariables() {
    router.register(nil, path: "/u/:id/p/::rest", handler: { _ in .ok(.text("u")) })
    let found = values("/u/a%2Fb/p/c%20d/e%2Ff")
    XCTAssertEqual(found?.params, ["id": "a/b", "rest": "c d/e/f"])
    XCTAssertEqual(found?.rawParams, ["id": "a%2Fb", "rest": "c%20d/e%2Ff"])
    let empty = values("/u/%C3%A9/p")
    XCTAssertEqual(empty?.params, ["id": "é", "rest": ""])
    XCTAssertEqual(empty?.rawParams, ["id": "%C3%A9", "rest": ""])
    // only one of the segments has an escape: the others are their own raw values
    let mixed = values("/u/plain/p/x/y%20z")
    XCTAssertEqual(mixed?.params, ["id": "plain", "rest": "x/y z"])
    XCTAssertEqual(mixed?.rawParams, ["id": "plain", "rest": "x/y%20z"])
    // no escape at all: the raw values are the decoded ones
    let plain = values("/u/7/p/x//y/")
    XCTAssertEqual(plain?.params, ["id": "7", "rest": "x/y"])
    XCTAssertEqual(plain?.rawParams, ["id": "7", "rest": "x/y"])
  }

  func testAnonymousVariablesHaveNoValueAndNoRawValue() {
    router.register(nil, path: "/a/*/c/**", handler: { _ in .ok(.text("a")) })
    router.register(nil, path: "/m/*/:x/**", handler: { _ in .ok(.text("m")) })
    XCTAssertEqual(values("/a/x%20y/c/d%2Fe/f")?.params, [:])
    XCTAssertEqual(values("/a/x%20y/c/d%2Fe/f")?.rawParams, [:])
    XCTAssertEqual(values("/m/s%20t/u%20v/w%2Fx")?.params, ["x": "u v"])
    XCTAssertEqual(values("/m/s%20t/u%20v/w%2Fx")?.rawParams, ["x": "u%20v"])
  }

  func testRawValuesHaveTheNamesOfTheDecodedValues() {
    router.register(nil, path: "/a/:x/*/::y/**/:z", handler: { _ in .ok(.text("a")) })
    guard let found = values("/a/1%20/2/3%2F/4/5/6%20") else {
      return XCTFail("no route")
    }
    XCTAssertEqual(Set(found.params.keys), ["x", "y", "z"])
    XCTAssertEqual(Set(found.rawParams.keys), Set(found.params.keys))
    XCTAssertEqual(found.rawParams["x"], "1%20")
    XCTAssertEqual(found.rawParams["z"], "6%20")
  }

  func testRouteAndRouteWithRawParamsFindTheSameHandlerAndParams() throws {
    router.register(nil, path: "/p/:name", handler: { _ in .ok(.text("p")) })
    router.register(nil, path: "/q/::path", handler: { _ in .ok(.text("q")) })
    for path in ["/p/a%2Fb", "/q/a%2Fb/c", "/q", "/p", "/p/%zz", "/nothing"] {
      let plain = router.route("GET", path: path)
      let raw = router.routeWithRawParams("GET", path: path)
      XCTAssertEqual(plain == nil, raw == nil, path)
      XCTAssertEqual(plain?.0, raw?.params, path)
      if let plain, let raw {
        XCTAssertEqual(try plain.1(NanoHTTPRequest(method: "GET", path: path)).capturedBody(),
                       try raw.handler(NanoHTTPRequest(method: "GET", path: path)).capturedBody(), path)
      }
    }
  }
}
