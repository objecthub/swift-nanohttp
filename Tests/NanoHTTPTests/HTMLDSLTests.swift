//
//  HTMLDSLTests.swift
//  NanoHTTPTests
//
//  Tests for the NanoHTML module: pages are built from values (`Html { Body { H1("x") } }`), text and
//  attribute values are escaped, void elements have no end tag, attributes come out in the order they
//  were set, and nothing is shared between pages. Covers findings N1, N2, N3 and S5 of the assessment
//  plan, which the closure-based builder of 1.x could not fix.
//

import XCTest
@testable import NanoHTTP
@testable import NanoHTML

private let bothModes: [NanoHTTPServer.Configuration.Threading] = [.perConnection, .singleThread]

final class HTMLElementTests: XCTestCase {

  func testNestedElementsAndText() {
    let html = Html {
      Body {
        H1("Title")
        Div { P("one"); P("two") }
      }
    }.rendered()
    XCTAssertEqual(html, "<!DOCTYPE html><html><body><h1>Title</h1><div><p>one</p><p>two</p></div></body></html>")
  }

  func testOnlyTheHtmlElementWritesTheDocumentType() {
    XCTAssertTrue(Html().rendered().hasPrefix("<!DOCTYPE html><html>"))
    XCTAssertEqual(Div { P("x") }.rendered(), "<div><p>x</p></div>")
    XCTAssertEqual(Fragment { P("a"); P("b") }.rendered(), "<p>a</p><p>b</p>")
  }

  func testAttributesAreWrittenInTheOrderInWhichTheyWereSet() {
    let input = Input().type("text").name("n").placeholder("p").value("v")
    for _ in 0..<20 {
      XCTAssertEqual(input.rendered(), "<input type=\"text\" name=\"n\" placeholder=\"p\" value=\"v\">")
    }
    XCTAssertEqual(Input().value("v").name("n").rendered(), "<input value=\"v\" name=\"n\">")
  }

  func testAttributesBelongToTheirElementOnly() {
    let html = Div {
      A("link").href("/x")
      P("plain")
    }.class("outer").rendered()
    XCTAssertEqual(html, "<div class=\"outer\"><a href=\"/x\">link</a><p>plain</p></div>")
  }

  func testSettingAnAttributeAgainReplacesIt() {
    XCTAssertEqual(A("x").href("/one").href("/two").rendered(), "<a href=\"/two\">x</a>")
    XCTAssertEqual(A("x").href("/one").title("t").href("/two").rendered(), "<a title=\"t\" href=\"/two\">x</a>",
                   "a replaced attribute moves to the end")
  }

  func testClassNamesAreAdded() {
    XCTAssertEqual(Div().class("a").class("b c").rendered(), "<div class=\"a b c\"></div>")
    XCTAssertEqual(Div().class(nil).class("").rendered(), "<div></div>")
  }

  func testNilLeavesAnAttributeOut() {
    let title: String? = nil
    XCTAssertEqual(A("x").href("/").title(title).rendered(), "<a href=\"/\">x</a>")
    XCTAssertEqual(A("x").title("t").title(nil).rendered(), "<a>x</a>", "nil removes an earlier value")
  }

  func testAttributesWithoutAValue() {
    XCTAssertEqual(Input().name("e").autofocus().rendered(), "<input name=\"e\" autofocus>")
    XCTAssertEqual(Input().disabled(false).rendered(), "<input>")
    XCTAssertEqual(Input().disabled(true).disabled(false).rendered(), "<input>")
    XCTAssertEqual(Button("b").attribute("hidden").rendered(), "<button hidden>b</button>")
  }

  func testNumbersAsAttributeValues() {
    XCTAssertEqual(Img().src("a.png").width(300).height(200).rendered(), "<img src=\"a.png\" width=\"300\" height=\"200\">")
    XCTAssertEqual(Td("x").colspan(2).width("50%").rendered(), "<td colspan=\"2\" width=\"50%\">x</td>")
  }

  func testDataAriaAndEventAttributes() {
    let html = Button("x").data("id", "7").aria("label", "Close").on("click", "go()").rendered()
    XCTAssertEqual(html, "<button data-id=\"7\" aria-label=\"Close\" onclick=\"go()\">x</button>")
  }

  func testAttributeNamesThatAreNotValidAreIgnored() {
    let html = Div().attribute("a b", "1").attribute("x\"onload", "2").attribute("", "3").attribute("data-ok", "4")
                    .attribute("1st", "5").rendered()
    XCTAssertEqual(html, "<div data-ok=\"4\"></div>")
  }

  func testVoidElementsHaveNoEndTag() {
    XCTAssertEqual(Br().rendered(), "<br>")
    let voids: [HTMLNode] = [Area(), Base(), Br(), Col(), Embed(), Hr(), Img(), Input(), Link(), Meta(), Source(), Track(), Wbr()]
    for node in voids {
      let html = node.rendered()
      XCTAssertFalse(html.contains("</"), html)
    }
    XCTAssertEqual(Fragment { P("a"); Br(); P("b") }.rendered(), "<p>a</p><br><p>b</p>")
  }

  func testOtherEmptyElementsKeepTheirEndTag() {
    XCTAssertEqual(Script().src("a.js").rendered(), "<script src=\"a.js\"></script>")
    XCTAssertEqual(Div().rendered(), "<div></div>")
    XCTAssertEqual(A().href("/").rendered(), "<a href=\"/\"></a>")
    XCTAssertEqual(Textarea().name("t").rendered(), "<textarea name=\"t\"></textarea>")
  }

  func testTheTypesThatCollideWithFoundationHaveOtherNames() {
    XCTAssertEqual(DataValue("5").value("5").rendered(), "<data value=\"5\">5</data>")
    XCTAssertEqual(ProgressBar().value("3").max("10").rendered(), "<progress value=\"3\" max=\"10\"></progress>")
  }

  func testCustomElements() {
    XCTAssertEqual(CustomElement("my-widget", text: "hi").data("x", "1").rendered(), "<my-widget data-x=\"1\">hi</my-widget>")
    XCTAssertEqual(CustomElement("my-card") { P("inside") }.rendered(), "<my-card><p>inside</p></my-card>")
    XCTAssertEqual(CustomElement("my-icon", isVoid: true).name("x").rendered(), "<my-icon name=\"x\">")
    XCTAssertEqual(CustomElement("x:y.z").rendered(), "<x:y.z></x:y.z>")
  }

  func testACustomElementWithAnInvalidNameIsItsContentOnly() {
    XCTAssertEqual(CustomElement("a><script") { P("inside") }.rendered(), "<p>inside</p>")
    XCTAssertEqual(CustomElement("") { "text" }.rendered(), "text")
    XCTAssertEqual(CustomElement("1abc", text: "x").rendered(), "x")
  }
}

// MARK: - The block syntax

final class HTMLBuilderTests: XCTestCase {

  func testForLoops() {
    let html = Ul {
      for name in ["a", "b", "c"] {
        Li(name)
      }
    }.rendered()
    XCTAssertEqual(html, "<ul><li>a</li><li>b</li><li>c</li></ul>")
  }

  func testLoopsOverPairsAndFilters() {
    let rows: [(String, Int)] = [("x", 1), ("y", 2), ("z", 3)]
    let html = Table {
      for (name, value) in rows where value != 2 {
        Tr { Td(name); Td("\(value)") }
      }
    }.rendered()
    XCTAssertEqual(html, "<table><tr><td>x</td><td>1</td></tr><tr><td>z</td><td>3</td></tr></table>")
  }

  func testConditions() {
    func page(_ admin: Bool, _ note: String?) -> String {
      return Div {
        if admin {
          B("admin")
        } else {
          I("guest")
        }
        if let note = note {
          P(note)
        }
        if admin && note != nil {
          Hr()
        }
      }.rendered()
    }
    XCTAssertEqual(page(true, "n"), "<div><b>admin</b><p>n</p><hr></div>")
    XCTAssertEqual(page(false, nil), "<div><i>guest</i></div>")
    XCTAssertEqual(page(true, nil), "<div><b>admin</b></div>")
  }

  func testSwitch() {
    func page(_ number: Int) -> String {
      return P {
        switch number {
          case 0: "zero"
          case 1: B("one")
          default: "many"
        }
      }.rendered()
    }
    XCTAssertEqual(page(0), "<p>zero</p>")
    XCTAssertEqual(page(1), "<p><b>one</b></p>")
    XCTAssertEqual(page(7), "<p>many</p>")
  }

  func testTextAndElementsMix() {
    let html = P { "Mixed: "; A("here").href("/h"); " and <more>." }.rendered()
    XCTAssertEqual(html, "<p>Mixed: <a href=\"/h\">here</a> and &lt;more&gt;.</p>")
  }

  func testFunctionsThatReturnNodes() {
    @HTMLBuilder func rows(_ names: [String]) -> HTMLNode {
      for name in names {
        Tr { Td(name) }
      }
    }
    func card(_ title: String) -> HTMLNode {
      return Div { H2(title) }.class("card")
    }
    let html = Table { rows(["a", "b"]) }.rendered() + card("T").rendered()
    XCTAssertEqual(html, "<table><tr><td>a</td></tr><tr><td>b</td></tr></table><div class=\"card\"><h2>T</h2></div>")
  }

  func testEmptyBlocks() {
    XCTAssertEqual(Div {}.rendered(), "<div></div>")
    XCTAssertEqual(Div { if false { P("x") } }.rendered(), "<div></div>")
    XCTAssertEqual(Fragment([]).rendered(), "")
  }

  func testTheSameValueCanBeUsedTwice() {
    let item = Li("x").class("item")
    let html = Ul { item; item.class("second") }.rendered()
    XCTAssertEqual(html, "<ul><li class=\"item\">x</li><li class=\"item second\">x</li></ul>")
  }
}

// MARK: - S5: escaping

final class HTMLEscapingTests: XCTestCase {

  func testTextCannotInjectMarkup() {
    let hostile = "<script>alert(\"x\")</script> & 'friends'"
    let html = P(hostile).rendered()
    XCTAssertFalse(html.contains("<script>"), html)
    XCTAssertEqual(html, "<p>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;friends&#39;</p>")
    XCTAssertEqual(Div { hostile }.rendered(), "<div>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;friends&#39;</div>")
  }

  func testAttributeValuesCannotBreakOutOfTheAttribute() {
    let html = A("link").href("x\" onclick=\"evil()").rendered()
    XCTAssertFalse(html.contains("\" onclick=\""), html)
    XCTAssertEqual(html, "<a href=\"x&quot; onclick=&quot;evil()\">link</a>")
    XCTAssertEqual(Div().data("x", "1\" onmouseover=\"evil()").rendered(), "<div data-x=\"1&quot; onmouseover=&quot;evil()\"></div>")
    XCTAssertEqual(Div().attribute("title", "'><script>").rendered(), "<div title=\"&#39;&gt;&lt;script&gt;\"></div>")
  }

  func testAllSpecialCharactersAreEscapedInAttributes() {
    XCTAssertEqual(A("x").href("/search?q=a&b=c#top").title("it's <fine>").rendered(),
                   "<a href=\"/search?q=a&amp;b=c#top\" title=\"it&#39;s &lt;fine&gt;\">x</a>")
  }

  func testOrdinaryTextIsUnchanged() {
    XCTAssertEqual(P("plain text 123 äöü €").rendered(), "<p>plain text 123 äöü €</p>")
  }

  func testTheTextOfEveryElementIsEscaped() {
    let hostile = "<img src=x onerror=alert(1)>"
    let nodes: [HTMLNode] = [H1(hostile), Td(hostile), Li(hostile), Button(hostile), Title(hostile), Textarea(hostile),
                             Option(hostile), Label(hostile), CustomElement("x-y", text: hostile)]
    for node in nodes {
      let html = node.rendered()
      XCTAssertFalse(html.contains("<img"), html)
    }
  }

  func testRawInsertsHTMLAsItIs() {
    XCTAssertEqual(P { "a "; Raw("<b>bold</b> &copy;") }.rendered(), "<p>a <b>bold</b> &copy;</p>")
  }

  func testTheContentOfScriptsAndStylesIsCode() {
    XCTAssertEqual(Script("if (a < b && c) { x(\"<p>\") }").rendered(), "<script>if (a < b && c) { x(\"<p>\") }</script>")
    XCTAssertEqual(Style("a > b { color: red }").rendered(), "<style>a > b { color: red }</style>")
  }

  func testTheEndTagOfAScriptCannotBeWrittenByItsContent() {
    let html = Script("var s = \"</script><script>evil()</script>\"; var t = '</SCRIPT >'").rendered()
    XCTAssertEqual(html, "<script>var s = \"<\\/script><script>evil()<\\/script>\"; var t = '<\\/SCRIPT >'</script>")
    XCTAssertEqual(html.components(separatedBy: "</script").count, 2, "only the end tag of the element is left")
    XCTAssertEqual(Style("a{} </style><b>").rendered(), "<style>a{} <\\/style><b></style>")
  }
}

// MARK: - Pages as responses

final class HTMLResponseTests: XCTestCase {

  private func get(_ handler: NanoHTTPRequestHandler, _ path: String = "/") throws -> NanoHTTPResponse {
    return try handler(NanoHTTPRequest(method: "GET", path: path))
  }

  func testTheResponseIsAnHTMLDocument() throws {
    let response = try self.get(htmlHandler { _ in Html { Body { P("x") } } })
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.allHeaders()["Content-Type"], "text/html; charset=utf-8")
    XCTAssertEqual(response.capturedBody(), "<!DOCTYPE html><html><body><p>x</p></body></html>")
  }

  func testTheBlockReceivesTheRequest() throws {
    let handler = htmlHandler { request in
      Html { Body { P("You asked for \(request.path) <\(request.method)>") } }
    }
    let body = try self.get(handler, "/some/path").capturedBody()
    XCTAssertTrue(body.contains("You asked for /some/path &lt;GET&gt;"), body)
  }

  func testAFragmentIsAnswerWithoutDocumentType() throws {
    let body = try self.get(htmlHandler { _ in Ul { Li("a") } }).capturedBody()
    XCTAssertEqual(body, "<ul><li>a</li></ul>")
  }

  func testAResponseFromANodeHasAStatusAndHeaders() {
    let response = NanoHTTPResponse.html(Html { Body { P("gone") } }, status: 404, headers: ["X-Reason": "test"])
    XCTAssertEqual(response.statusCode, 404)
    XCTAssertEqual(response.allHeaders()["X-Reason"], "test")
    XCTAssertEqual(response.allHeaders()["Content-Type"], "text/html; charset=utf-8")
  }

  func testThrowingFromThePageIsAnsweredLikeAnyHandlerError() throws {
    try withTestServer(configure: { server in
      server.get["/page"] = htmlHandler { request in
        guard request.query("ok") != nil else {
          throw NanoHTTPError.badRequest("no ok")
        }
        return P("fine")
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/page", port: port).status, 400)
      XCTAssertEqual(try RawClient.get("/page?ok=1", port: port).bodyString, "<p>fine</p>")
    }
  }

  func testPagesAreServedWithALengthInBothThreadingModes() throws {
    for threading in bothModes {
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.get["/page/:n"] = htmlHandler { request in
          Html { Body { H1("page \(request.params["n"] ?? "?")") } }
        }
      }) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("GET", "/page/7", headers: ["Connection: keep-alive"]))
        let response = client.readResponse()
        XCTAssertEqual(response?.status, 200, "\(threading)")
        XCTAssertEqual(response?.bodyString, "<!DOCTYPE html><html><body><h1>page 7</h1></body></html>", "\(threading)")
        XCTAssertEqual(response?.header("content-length"), "\(response?.bodyString.utf8.count ?? -1)", "\(threading)")
        client.send(RawClient.requestText("GET", "/page/8", headers: ["Connection: close"]))
        XCTAssertTrue(client.readResponse()?.bodyString.contains("page 8") ?? false, "the connection was kept: \(threading)")
      }
    }
  }

  /// Pages are values and share nothing: building them on many threads at once cannot mix them up.
  func testConcurrentlyBuiltPagesDoNotMixUp() {
    let lock = NSLock()
    var mismatches = 0
    DispatchQueue.concurrentPerform(iterations: 4000) { index in
      let html = Div { A("link-\(index)").href("/u/\(index)") }.rendered()
      if html != "<div><a href=\"/u/\(index)\">link-\(index)</a></div>" {
        lock.lock(); mismatches += 1; lock.unlock()
      }
    }
    XCTAssertEqual(mismatches, 0, "\(mismatches) of 4000 concurrent renderings were wrong")
  }

  func testConcurrentRequestsToAServerGetTheirOwnPage() throws {
    try withTestServer(configure: { server in
      server.get["/page/:n"] = htmlHandler { request in
        let number = request.params["n"] ?? "?"
        return Div {
          H1("page \(number)")
          A("link \(number)").href("/page/\(number)").class("c\(number)")
        }
      }
    }) { _, port in
      let lock = NSLock()
      var failures = [String]()
      DispatchQueue.concurrentPerform(iterations: 200) { index in
        let expected = "<div><h1>page \(index)</h1><a href=\"/page/\(index)\" class=\"c\(index)\">link \(index)</a></div>"
        let body = (try? RawClient.get("/page/\(index)", port: port).bodyString) ?? "<no response>"
        if body != expected {
          lock.lock(); failures.append("\(index): \(body)"); lock.unlock()
        }
      }
      XCTAssertEqual(failures.count, 0, failures.prefix(2).joined(separator: "\n"))
    }
  }
}

final class HTMLEscapedTests: XCTestCase {

  func testHTMLEscapedReplacesExactlyTheSpecialCharacters() {
    XCTAssertEqual("plain text 123 äöü €".htmlEscaped, "plain text 123 äöü €")
    XCTAssertEqual("&<>\"'".htmlEscaped, "&amp;&lt;&gt;&quot;&#39;")
    XCTAssertEqual("&amp;".htmlEscaped, "&amp;amp;") // not idempotent, by design
    XCTAssertEqual("".htmlEscaped, "")
    XCTAssertEqual("a\r\nb".htmlEscaped, "a\r\nb")
  }
}
