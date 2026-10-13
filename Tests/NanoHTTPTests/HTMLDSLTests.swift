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

  private func render(_ scope: @escaping NanoHTMLClosure) throws -> String {
    return try htmlHandler(scope)(NanoHTTPRequest(method: "GET", path: "/")).capturedBody()
  }

  func testResponseIsAnHTMLDocument() throws {
    let response = try htmlHandler { body { p { inner = "x" } } }(NanoHTTPRequest(method: "GET", path: "/"))
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.allHeaders()["Content-Type"], "text/html; charset=utf-8")
    XCTAssertTrue(response.capturedBody().hasPrefix("<!DOCTYPE html>"))
  }

  func testNestedElementsAndInnerText() throws {
    let html = try render {
      html {
        body {
          h1 { inner = "Title" }
          div { p { inner = "one" }; p { inner = "two" } }
        }
      }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><html><body><h1>Title</h1><div><p>one</p><p>two</p></div></body></html>")
  }

  func testAttributesAreRenderedOnTheirOwnElementOnly() throws {
    let html = try render {
      div {
        a { href = "/x"; inner = "link" }
        p { inner = "plain" } // must not inherit href from the sibling
      }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><div><a href=\"/x\">link</a><p>plain</p></div>")
  }

  func testAttributesDoNotLeakIntoNestedOrFollowingElements() throws {
    let html = try render {
      div {
        classs = "outer"
        span { inner = "inside" }
      }
      p { inner = "after" }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><div class=\"outer\"><span>inside</span></div><p>after</p>")
  }

  func testSequenceHelpers() throws {
    let html = try render {
      ul(["a", "b", "c"]) { item in
        li { inner = item }
      }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><ul><li>a</li><li>b</li><li>c</li></ul>")
  }

  func testCustomAttributesViaElement() throws {
    let html = try render {
      element("section", ["data-id": "7", "hidden": nil]) { inner = "s" }
    }
    XCTAssertEqual(html, "<!DOCTYPE html><section data-id=\"7\">s</section>")
  }

  func testVoidElementsHaveNoClosingTag() throws {
    let html = try render {
      p { inner = "a" }
      br {}
    }
    expectKnownIssue("N3", "void elements are emitted with an end tag (</br>), which browsers treat as another <br>") {
      XCTAssertFalse(html.contains("</br>"), html)
    }
  }

  /// Output must not depend on dictionary iteration order.
  func testAttributeOrderIsDeterministic() throws {
    let outputs = Set(try (0..<20).map { _ in try renderInputWithManyAttributes() })
    expectKnownIssue("N3", "attributes are emitted in Dictionary order, which differs between runs", strict: false) {
      XCTAssertEqual(outputs.count, 1, "got \(outputs.count) different renderings")
    }
  }

  /// The builder keeps its state in module-wide variables. Rendering is serialized, so concurrent
  /// requests no longer corrupt each other. (Before, this aborted the process in every run.)
  func testConcurrentRenderingDoesNotMixUpRequests() {
    let lock = NSLock()
    var mismatches = 0
    DispatchQueue.concurrentPerform(iterations: 4000) { index in
      let html = (try? render {
        div { a { href = "/u/\(index)"; inner = "link-\(index)" } }
      }) ?? ""
      if html != "<!DOCTYPE html><div><a href=\"/u/\(index)\">link-\(index)</a></div>" {
        lock.lock(); mismatches += 1; lock.unlock()
      }
    }
    XCTAssertEqual(mismatches, 0, "\(mismatches) of 4000 concurrent renderings were corrupted")
  }

  func testConcurrentRequestsToAServerGetTheirOwnPage() throws {
    try withTestServer(configure: { server in
      server.get["/page/:n"] = { request in
        let number = request.params["n"] ?? "?"
        return try htmlHandler {
          div {
            h1 { inner = "page \(number)" }
            a { href = "/page/\(number)"; classs = "c\(number)"; inner = "link \(number)" }
          }
        }(request)
      }
    }) { _, port in
      let lock = NSLock()
      var failures = [String]()
      DispatchQueue.concurrentPerform(iterations: 200) { index in
        let expected = "<h1>page \(index)</h1><a href=\"/page/\(index)\" class=\"c\(index)\">link \(index)</a>"
        let alternative = "<h1>page \(index)</h1><a class=\"c\(index)\" href=\"/page/\(index)\">link \(index)</a>"
        let body = (try? RawClient.get("/page/\(index)", port: port).bodyString) ?? "<no response>"
        if !body.contains(expected) && !body.contains(alternative) { // attribute order is not defined
          lock.lock(); failures.append("\(index): \(body)"); lock.unlock()
        }
      }
      XCTAssertEqual(failures.count, 0, failures.prefix(2).joined(separator: "\n"))
    }
  }

  func testNestedRenderingOnTheSameThreadDoesNotDeadlock() {
    let outer = htmlHandler {
      div {
        _ = try? htmlHandler { p { inner = "nested" } }(NanoHTTPRequest(method: "GET", path: "/"))
        inner = "outer"
      }
    }
    // The lock is recursive: this must return. (What the nested call does to the outer document
    // is not specified.)
    XCTAssertEqual(try outer(NanoHTTPRequest(method: "GET", path: "/")).statusCode, 200)
  }
}

/// Rendered from file scope on purpose. Inside an `XCTestCase` (an `NSObject`), the DSL's bare
/// `name` and `value` resolve to `XCTestCase.name` / `NSObject.value(forKey:)` and do not even
/// compile (finding N2: the DSL's ~150 module-level variables clash with member names of any
/// enclosing type, e.g. a SwiftUI `View` with a `title`, or an `NSObject` subclass).
private func renderInputWithManyAttributes() throws -> String {
  return try htmlHandler {
    input { type = "text"; name = "n"; placeholder = "p"; value = "v" }
  }(NanoHTTPRequest(method: "GET", path: "/")).capturedBody()
}
