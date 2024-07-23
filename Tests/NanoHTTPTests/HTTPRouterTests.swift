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

class SwifterTestsNanoHTTPRouter: XCTestCase {
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
    XCTAssertNil(router.route("GET", path: "/a/e/f/g"))
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
  
  func testNanoHTTPRouterHandlesOverlappingPaths() {
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
    _ = staticRouterHandler?(request)
    let variableRouteResult = router.route("GET", path: "a/b/c")
    let variableRouterHandler = variableRouteResult?.1
    XCTAssertNotNil(variableRouteResult)
    _ = variableRouterHandler?(request)
    waitForExpectations(timeout: 10, handler: nil)
    XCTAssertTrue(foundStaticRoute)
    XCTAssertTrue(foundVariableRoute)
  }
  
  func testNanoHTTPRouterHandlesOverlappingPathsInDynamicRoutes() {
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
    _ = firstRouterHandler?(request)
    let secondRouteResult = router.route("GET", path: "a/b/c")
    let secondRouterHandler = secondRouteResult?.1
    XCTAssertNotNil(secondRouteResult)
    _ = secondRouterHandler?(request)
    waitForExpectations(timeout: 10, handler: nil)
    XCTAssertTrue(foundFirstVariableRoute)
    XCTAssertTrue(foundSecondVariableRoute)
  }
  
  func testNanoHTTPRouterShouldHandleOverlappingRoutesInTrail() {
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
    _ = firstRouterHandler?(request)
    let secondRouteResult = router.route("GET", path: "/a/b")
    let secondRouterHandler = secondRouteResult?.1
    XCTAssertNotNil(secondRouteResult)
    _ = secondRouterHandler?(request)
    let thirdRouteResult = router.route("GET", path: "/a/b/b")
    let thirdRouterHandler = thirdRouteResult?.1
    XCTAssertNotNil(thirdRouteResult)
    _ = thirdRouterHandler?(request)
    waitForExpectations(timeout: 10, handler: nil)
    XCTAssertTrue(foundFirstVariableRoute)
    XCTAssertTrue(foundSecondVariableRoute)
    XCTAssertTrue(foundThirdVariableRoute)
  }
  
  func testNanoHTTPRouterHandlesOverlappingPathsInDynamicRoutesInTheMiddle() {
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
    _ = firstRouterHandler?(request)
    let secondRouteResult = router.route("GET", path: "/a/b/f/g")
    let secondRouterHandler = secondRouteResult?.1
    XCTAssertNotNil(secondRouteResult)
    _ = secondRouterHandler?(request)
    waitForExpectations(timeout: 10, handler: nil)
    XCTAssertTrue(foundFirstVariableRoute)
    XCTAssertTrue(foundSecondVariableRoute)
  }
}
