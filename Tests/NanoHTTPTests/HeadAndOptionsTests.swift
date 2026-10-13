//
//  HeadAndOptionsTests.swift
//  NanoHTTPTests
//
//  2.0 (H7): a HEAD request is answered like the GET request for the same resource, without the body; a
//  request with a method that a path does not have gets `405` and the methods that it has; `OPTIONS` lists them.
//

import XCTest
@testable import NanoHTTP

private let bothModes: [NanoHTTPServer.Configuration.Threading] = [.perConnection, .singleThread]

final class RouterAllowedMethodsTests: XCTestCase {

  private func router() -> NanoHTTPSegmentRouter {
    let router = NanoHTTPSegmentRouter()
    let handler: NanoHTTPRequestHandler = { _ in .ok(.text("x")) }
    router.register("GET", path: "/items", handler: handler)
    router.register("POST", path: "/items", handler: handler)
    router.register("DELETE", path: "/things/:id", handler: handler)
    router.register("PUT", path: "/things/:id", handler: handler)
    router.register("PATCH", path: "/files/::path", handler: handler)
    router.register("HEAD", path: "/headonly", handler: handler)
    router.register(nil, path: "/everything", handler: handler)
    return router
  }

  func testTheMethodsOfAPathInTheUsualOrder() {
    XCTAssertEqual(router().allowedMethods(path: "/items"), ["GET", "HEAD", "POST", "OPTIONS"])
    XCTAssertEqual(router().allowedMethods(path: "/things/7"), ["PUT", "DELETE", "OPTIONS"])
    XCTAssertEqual(router().allowedMethods(path: "/files/a/b"), ["PATCH", "OPTIONS"])
    XCTAssertEqual(router().allowedMethods(path: "/headonly"), ["HEAD", "OPTIONS"])
  }

  func testAPathWithoutRoutesHasNoMethods() {
    XCTAssertEqual(router().allowedMethods(path: "/nothing"), [])
    XCTAssertEqual(router().allowedMethods(path: "/things/7/extra"), [])
  }

  func testThePathIsMatchedAsTheRouterMatchesIt() {
    XCTAssertEqual(router().allowedMethods(path: "/it%65ms"), ["GET", "HEAD", "POST", "OPTIONS"])
    XCTAssertEqual(router().allowedMethods(path: "/things/%zz"), [])
    XCTAssertEqual(router().allowedMethods(path: "/items?x=1"), ["GET", "HEAD", "POST", "OPTIONS"])
  }

  func testTheStarIsAllTheMethodsOfTheRouter() {
    XCTAssertEqual(router().allowedMethods(path: "*"), ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
    XCTAssertEqual(NanoHTTPSegmentRouter().allowedMethods(path: "*"), [])
  }

  func testUnusualMethodsComeAfterTheUsualOnes() {
    let router = NanoHTTPSegmentRouter()
    router.register("PROPFIND", path: "/dav", handler: { _ in .ok(.text("x")) })
    router.register("COPY", path: "/dav", handler: { _ in .ok(.text("x")) })
    router.register("GET", path: "/dav", handler: { _ in .ok(.text("x")) })
    XCTAssertEqual(router.allowedMethods(path: "/dav"), ["GET", "HEAD", "OPTIONS", "COPY", "PROPFIND"])
  }

  func testHeadIsAnsweredByTheHandlerOfGetUnlessThereIsOneForHead() {
    let router = NanoHTTPSegmentRouter()
    router.register("GET", path: "/a", handler: { _ in .ok(.text("get")) })
    router.register("HEAD", path: "/b", handler: { _ in .ok(.text("head")) })
    router.register("GET", path: "/b", handler: { _ in .ok(.text("get")) })
    router.register(nil, path: "/c", handler: { _ in .ok(.text("any")) })
    router.register("GET", path: "/c", handler: { _ in .ok(.text("get")) })
    func answer(_ path: String) throws -> String? {
      return try router.route("HEAD", path: path).map { try $0.1(NanoHTTPRequest(method: "HEAD", path: path)).capturedBody() }
    }
    XCTAssertEqual(try answer("/a"), "get")
    XCTAssertEqual(try answer("/b"), "head")
    XCTAssertEqual(try answer("/c"), "get", "the handler for GET is more specific than the one for every method")
    XCTAssertNil(try answer("/d"))
  }

  func testARouterWithoutTheCapabilityHasNoMethods() {
    final class Minimal: NanoHTTPRouter {
      func register(_ method: String?, path: String, handler: NanoHTTPRequestHandler?) {}
      func merge(_ router: NanoHTTPRouter, withPrefix prefix: String) throws {}
      func route(_ method: String, path: String) -> ([String: String], NanoHTTPRequestHandler)? { return nil }
      func routes() -> [String] { return [] }
    }
    XCTAssertEqual(Minimal().allowedMethods(path: "/x"), [])
  }
}

final class HeadRequestTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.get["/text"] = { request in .ok(headers: ["X-Method": request.method], .text("hello world")) }
      server.get["/json"] = { _ in .ok(.json(["a": 1])) }
      server["/any"] = { _ in .ok(.text("anything")) }
      server.head["/explicit"] = { _ in .ok(headers: ["X-Head": "yes"], .text("")) }
      server.get["/explicit"] = { _ in .ok(.text("get")) }
      server.get["/declared"] = { _ in .custom(200, headers: ["Content-Length": "6"]) { writer in try writer.write(Array("abcdef".utf8)) } }
      server.get["/stream"] = { _ in .custom(200) { writer in try writer.write(Array("streamed".utf8)) } }
      server.get["/missing-body"] = { _ in .notFound(.text("gone")) }
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }, body)
  }

  func testHeadIsAnsweredLikeGetWithoutABody() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("HEAD", "/text"))
        let head = client.readResponse(head: true)
        XCTAssertEqual(head?.status, 200, "\(threading)")
        XCTAssertEqual(head?.header("content-length"), "11", "\(threading): the length of the body that GET gets")
        XCTAssertEqual(head?.header("content-type"), "text/plain; charset=utf-8")
        XCTAssertEqual(head?.header("x-method"), "HEAD", "the handler sees the method of the request")
        // The connection is in step: the next response is not the body that must not be sent.
        client.send(RawClient.requestText("GET", "/ping"))
        XCTAssertEqual(client.readResponse()?.bodyString, "pong", "\(threading)")
      }
    }
  }

  func testHeadOfJSONAndOfAHandlerForEveryMethod() throws {
    try serve(.perConnection) { _, port in
      for (path, length) in [("/json", "7"), ("/any", "8")] {
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("HEAD", path, headers: ["Connection: close"]))
        XCTAssertEqual(client.readResponse(head: true)?.header("content-length"), length, path)
        XCTAssertEqual(client.readToEnd(timeout: 1).count, 0, path)
      }
    }
  }

  func testAHandlerForHeadWinsOverTheOneForGet() throws {
    try serve(.perConnection) { _, port in
      let response = try RawClient.request("HEAD", "/explicit", port: port)
      XCTAssertEqual(response.header("x-head"), "yes")
    }
  }

  func testHeadOfABodyThatAFunctionWrites() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("HEAD", "/declared"))
        XCTAssertEqual(client.readResponse(head: true)?.header("content-length"), "6", "\\(threading)")
        client.send(RawClient.requestText("HEAD", "/stream"))
        let stream = client.readResponse(head: true)
        XCTAssertNil(stream?.header("content-length"), "the length is not known")
        XCTAssertNil(stream?.header("transfer-encoding"), "there is no body in chunks")
        client.send(RawClient.requestText("GET", "/ping"))
        XCTAssertEqual(client.readResponse()?.bodyString, "pong", "\(threading): nothing of a body was sent")
      }
    }
  }

  func testHeadOfAnErrorHasNoBodyEither() throws {
    try serve(.perConnection) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("HEAD", "/missing-body", headers: ["Connection: close"]))
      XCTAssertEqual(client.readResponse(head: true)?.status, 404)
      XCTAssertEqual(client.readToEnd(timeout: 1).count, 0)
      let unknown = try RawClient.request("HEAD", "/no-such-path", port: port)
      XCTAssertEqual(unknown.status, 404)
    }
  }

  func testHeadOverAnHTTP10ConnectionThatIsKept() throws {
    try serve(.perConnection) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("HEAD", "/stream", version: "HTTP/1.0", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse(head: true)?.status, 200)
      client.send(RawClient.requestText("GET", "/ping", version: "HTTP/1.0", headers: ["Connection: keep-alive"]))
      XCTAssertEqual(client.readResponse()?.bodyString, "pong")
    }
  }
}

final class MethodNotAllowedTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.get["/items"] = { _ in .ok(.text("items")) }
      server.post["/items"] = { _ in .ok(.text("created")) }
      server.delete["/things/:id"] = { _ in .ok(.text("deleted")) }
      server.post["/only-post"] = { _ in .ok(.text("posted")) }
      server.get["/ping"] = { _ in .ok(.text("pong")) }
    }, body)
  }

  func testAMethodThatThePathDoesNotHaveGets405AndTheMethodsThatItHas() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let put = try RawClient.request("PUT", "/items", port: port)
        XCTAssertEqual(put.status, 405, "\(threading)")
        XCTAssertEqual(put.header("allow"), "GET, HEAD, POST, OPTIONS", "\(threading)")
        let get = try RawClient.get("/things/42", port: port)
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.header("allow"), "DELETE, OPTIONS")
        let head = try RawClient.request("HEAD", "/only-post", port: port)
        XCTAssertEqual(head.status, 405)
        XCTAssertEqual(head.header("allow"), "POST, OPTIONS")
      }
    }
  }

  func testAPathWithoutRoutesStillGets404() throws {
    try serve(.perConnection) { _, port in
      let response = try RawClient.request("PUT", "/nothing-here", port: port)
      XCTAssertEqual(response.status, 404)
      XCTAssertNil(response.header("allow"))
    }
  }

  func testMethodNotAllowedTakesPrecedenceOverTheNotFoundHandler() throws {
    try withTestServer(configure: { server in
      server.get["/items"] = { _ in .ok(.text("items")) }
      server.notFoundHandler = { _ in .ok(.text("fallback page")) }
    }) { _, port in
      XCTAssertEqual(try RawClient.request("POST", "/items", port: port).status, 405)
      XCTAssertEqual(try RawClient.get("/elsewhere", port: port).bodyString, "fallback page")
    }
  }

  func testMiddlewareSeesTheMethodNotAllowedResponse() throws {
    try withTestServer(configure: { server in
      server.get["/items"] = { _ in .ok(.text("items")) }
      server.middleware.append { request, next in
        var response = try next(request)
        response.headers["X-Seen"] = String(response.statusCode)
        return response
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.request("POST", "/items", port: port).header("x-seen"), "405")
    }
  }

  func testTheConnectionStaysUsableAfter405() throws {
    try serve(.perConnection) { _, port in
      let client = try RawClient(port: port)
      client.send(RawClient.requestText("PUT", "/items", body: Array("x".utf8)))
      XCTAssertEqual(client.readResponse()?.status, 405)
      client.send(RawClient.requestText("GET", "/ping"))
      XCTAssertEqual(client.readResponse()?.bodyString, "pong")
    }
  }
}

final class OptionsRequestTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.get["/items"] = { _ in .ok(.text("items")) }
      server.post["/items"] = { _ in .ok(.text("created")) }
      server.options["/custom"] = { _ in .ok(headers: ["Allow": "GET", "X-Custom": "1"], .text("custom options")) }
      server.get["/custom"] = { _ in .ok(.text("custom")) }
    }, body)
  }

  func testOptionsListsTheMethodsOfThePath() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        client.send(RawClient.requestText("OPTIONS", "/items"))
        let response = client.readResponse()
        XCTAssertEqual(response?.status, 204, "\(threading)")
        XCTAssertEqual(response?.header("allow"), "GET, HEAD, POST, OPTIONS", "\(threading)")
        XCTAssertNil(response?.header("content-length"))
        client.send(RawClient.requestText("GET", "/items"))
        XCTAssertEqual(client.readResponse()?.bodyString, "items", "\(threading): the connection is in step")
      }
    }
  }

  func testOptionsStarListsTheMethodsOfTheServer() throws {
    try serve(.perConnection) { _, port in
      let client = try RawClient(port: port)
      client.send("OPTIONS * HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      let response = client.readResponse()
      XCTAssertEqual(response?.status, 204)
      XCTAssertEqual(response?.header("allow"), "GET, HEAD, POST, OPTIONS")
    }
  }

  func testAHandlerForOptionsWins() throws {
    try serve(.perConnection) { _, port in
      let response = try RawClient.request("OPTIONS", "/custom", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.header("x-custom"), "1")
      XCTAssertEqual(response.bodyString, "custom options")
    }
  }

  func testOptionsOfAPathWithoutRoutesIs404() throws {
    try serve(.perConnection) { _, port in
      XCTAssertEqual(try RawClient.request("OPTIONS", "/nothing", port: port).status, 404)
    }
  }
}
