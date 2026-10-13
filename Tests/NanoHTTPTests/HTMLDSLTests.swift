//
//  HTMLDSLTests.swift
//  NanoHTTPTests
//
//  Tests for the NanoHTML builder (`htmlHandler { html { body { ... } } }`), covering findings
//  N1 and N3 of the assessment plan. Escaping (S5) is in SecurityTests.swift.
//

import XCTest
@testable import NanoHTTP

final class HTMLDSLTests: XCTestCase {

  private func render(_ scope: @escaping NanoHTMLClosure) -> String {
    return htmlHandler(scope)(NanoHTTPRequest(method: "GET", path: "/")).capturedBody()
  }

  func testResponseIsAnHTMLDocument() {
    let response = htmlHandler { body { p { inner = "x" } } }(NanoHTTPRequest(method: "GET", path: "/"))
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.allHeaders()["Content-Type"], "text/html")
    XCTAssertTrue(response.capturedBody().hasPrefix("<!DOCTYPE html>"))
  }

  func testNestedElementsAndInnerText() {
    let html = render {
      html {
        body {
          h1 { inner = "Title" }
          div { p { inner = "one" }; p { inner = "two" } }
        }
      }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><html><body><h1>Title</h1><div><p>one</p><p>two</p></div></body></html>")
  }

  func testAttributesAreRenderedOnTheirOwnElementOnly() {
    let html = render {
      div {
        a { href = "/x"; inner = "link" }
        p { inner = "plain" } // must not inherit href from the sibling
      }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><div><a href=\"/x\">link</a><p>plain</p></div>")
  }

  func testAttributesDoNotLeakIntoNestedOrFollowingElements() {
    let html = render {
      div {
        classs = "outer"
        span { inner = "inside" }
      }
      p { inner = "after" }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><div class=\"outer\"><span>inside</span></div><p>after</p>")
  }

  func testSequenceHelpers() {
    let html = render {
      ul(["a", "b", "c"]) { item in
        li { inner = item }
      }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><ul><li>a</li><li>b</li><li>c</li></ul>")
  }

  func testCustomAttributesViaElement() {
    let html = render {
      element("section", ["data-id": "7", "hidden": nil]) { inner = "s" }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><section data-id=\"7\">s</section>")
  }

  func testVoidElementsHaveNoClosingTag() {
    let html = render {
      p { inner = "a" }
      br {}
    }
    expectKnownIssue("N3", "void elements are emitted with an end tag (</br>), which browsers treat as another <br>") {
      XCTAssertFalse(html.contains("</br>"), html)
    }
  }

  /// Output must not depend on dictionary iteration order.
  func testAttributeOrderIsDeterministic() {
    let outputs = Set((0..<20).map { _ in renderInputWithManyAttributes() })
    expectKnownIssue("N3", "attributes are emitted in Dictionary order, which differs between runs", strict: false) {
      XCTAssertEqual(outputs.count, 1, "got \(outputs.count) different renderings")
    }
  }

  /// Every handler invocation uses module-wide attribute variables and a shared buffer
  /// dictionary, so concurrent requests corrupt each other (and a concurrent write to the
  /// Dictionary can crash the process). Opt in with NANOHTTP_CRASH_TESTS=1.
  func testConcurrentRenderingDoesNotMixUpRequests() throws {
    try requireCrashTests("N1", "NanoHTML keeps its state in unsynchronized module-level variables")
    let lock = NSLock()
    var mismatches = 0
    DispatchQueue.concurrentPerform(iterations: 4000) { index in
      let html = render {
        div { a { href = "/u/\(index)"; inner = "link-\(index)" } }
      }
      if html != "<!DOCTYPE html><div><a href=\"/u/\(index)\">link-\(index)</a></div>" {
        lock.lock(); mismatches += 1; lock.unlock()
      }
    }
    XCTAssertEqual(mismatches, 0, "\(mismatches) of 4000 concurrent renderings were corrupted")
  }
}

/// Rendered from file scope on purpose. Inside an `XCTestCase` (an `NSObject`), the DSL's bare
/// `name` and `value` resolve to `XCTestCase.name` / `NSObject.value(forKey:)` and do not even
/// compile (finding N2: the DSL's ~150 module-level variables clash with member names of any
/// enclosing type, e.g. a SwiftUI `View` with a `title`, or an `NSObject` subclass).
private func renderInputWithManyAttributes() -> String {
  return htmlHandler {
    input { type = "text"; name = "n"; placeholder = "p"; value = "v" }
  }(NanoHTTPRequest(method: "GET", path: "/")).capturedBody()
}
