//
//  MiddlewareTests.swift
//  NanoHTTPTests
//
//  2.0: middleware wraps the handling of requests: `(request, next)`. It can change the request, change
//  the response, catch errors, or answer without calling `next`. It still runs before routing.
//

import XCTest
@testable import NanoHTTP

private final class Events {
  private let lock = NSLock()
  private var list = [String]()

  func add(_ event: String) {
    self.lock.lock()
    self.list.append(event)
    self.lock.unlock()
  }

  var all: [String] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.list
  }
}

final class MiddlewareTests: XCTestCase {

  private func serve(threading: NanoHTTPServer.Configuration.Threading = .perConnection,
                     configure: (NanoHTTPServer) -> Void,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.get["/ok"] = { _ in .ok(.text("fine")) }
      configure(server)
    }, body)
  }

  func testMiddlewareWrapsTheHandlerTheFirstOneOutermost() throws {
    let events = Events()
    try serve(configure: { server in
      server.get["/ok"] = { _ in events.add("handler"); return .ok(.text("fine")) }
      for name in ["A", "B", "C"] {
        server.middleware.append { request, next in
          events.add("\(name) in")
          let response = try next(request)
          events.add("\(name) out")
          return response
        }
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/ok", port: port).bodyString, "fine")
      XCTAssertEqual(events.all, ["A in", "B in", "C in", "handler", "C out", "B out", "A out"])
    }
  }

  func testMiddlewareCanAnswerWithoutCallingNext() throws {
    let handled = Events()
    try serve(configure: { server in
      server.get["/secret"] = { _ in handled.add("secret"); return .ok(.text("secret")) }
      server.middleware.append { request, next in
        guard request.header("x-token") == "ok" else {
          return .unauthorized(.text("denied"))
        }
        return try next(request)
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/secret", port: port).status, 401)
      XCTAssertEqual(handled.all, [])
      XCTAssertEqual(try RawClient.get("/secret", port: port, headers: ["X-Token: ok", "Connection: close"]).bodyString,
                     "secret")
      XCTAssertEqual(handled.all, ["secret"])
    }
  }

  func testMiddlewareCanChangeTheResponse() throws {
    try serve(configure: { server in
      server.middleware.append { request, next in
        var response = try next(request)
        response.headers["X-Served-By"] = "nano"
        return response
      }
    }) { _, port in
      let response = try RawClient.get("/ok", port: port)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.header("x-served-by"), "nano")
    }
  }

  func testMiddlewareSeesRequestsWithoutRoute() throws {
    try serve(configure: { server in
      server.middleware.append { request, next in
        var response = try next(request)
        response.headers["X-Status"] = String(response.statusCode)
        return response
      }
    }) { _, port in
      let response = try RawClient.get("/nothing", port: port)
      XCTAssertEqual(response.status, 404)
      XCTAssertEqual(response.header("x-status"), "404")
    }
    try serve(configure: { server in
      server.notFoundHandler = { _ in .notFound(.text("custom")) }
      server.middleware.append { request, next in
        var response = try next(request)
        response.headers["X-Status"] = String(response.statusCode)
        return response
      }
    }) { _, port in
      let response = try RawClient.get("/nothing", port: port)
      XCTAssertEqual(response.bodyString, "custom")
      XCTAssertEqual(response.header("x-status"), "404")
    }
  }

  func testMiddlewareCanChangeTheRequestBeforeItIsRouted() throws {
    try serve(configure: { server in
      server.get["/new/page"] = { _ in .ok(.text("new page")) }
      server.middleware.append { request, next in
        if request.path.hasPrefix("/old/") {
          request.path = "/new/" + request.path.dropFirst(5)
        }
        return try next(request)
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/old/page", port: port).bodyString, "new page")
    }
  }

  func testMiddlewareCanPassInformationToTheHandler() throws {
    try serve(configure: { server in
      server.get["/whoami"] = { request in .ok(.text((request.custom["user"] as? String) ?? "nobody")) }
      server.middleware.append { request, next in
        request.custom["user"] = request.header("x-user") ?? "guest"
        return try next(request)
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/whoami", port: port).bodyString, "guest")
      XCTAssertEqual(try RawClient.get("/whoami", port: port, headers: ["X-User: ada", "Connection: close"]).bodyString, "ada")
    }
  }

  func testRouteVariablesAreKnownOnceTheRequestHasBeenRouted() throws {
    let seen = Events()
    try serve(configure: { server in
      server.get["/items/:id"] = { request in .ok(.text(request.params["id"] ?? "?")) }
      server.middleware.append { request, next in
        seen.add("before: \(request.params["id"] ?? "-")")
        let response = try next(request)
        seen.add("after: \(request.params["id"] ?? "-")")
        return response
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/items/42", port: port).bodyString, "42")
      XCTAssertEqual(seen.all, ["before: -", "after: 42"])
    }
  }

  func testRawRouteVariablesAreKnownOnceTheRequestHasBeenRouted() throws {
    let seen = Events()
    try serve(configure: { server in
      server.get["/items/:id/::rest"] = { request in
        .ok(.text("\(request.params["id"] ?? "?")|\(request.rawParams["id"] ?? "?")"))
      }
      server.middleware.append { request, next in
        seen.add("before: \(request.rawParams.count)")
        let response = try next(request)
        seen.add("after: \(request.params["id"] ?? "-") \(request.rawParams["id"] ?? "-") " +
                 "\(request.params["rest"] ?? "-") \(request.rawParams["rest"] ?? "-")")
        return response
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/items/a%2Fb/c%20d/e%2Ff", port: port).bodyString, "a/b|a%2Fb")
      XCTAssertEqual(seen.all, ["before: 0", "after: a/b a%2Fb c d/e/f c%20d/e%2Ff"])
    }
  }

  func testRawRouteVariablesWithSeveralMiddlewareAndOneThread() throws {
    for threading in [NanoHTTPServer.Configuration.Threading.perConnection, .singleThread] {
      let seen = Events()
      try serve(threading: threading, configure: { server in
        server.get["/items/:id"] = { request in .ok(.text(request.rawParams["id"] ?? "?")) }
        for index in 0..<3 {
          server.middleware.append { request, next in
            let response = try next(request)
            seen.add("\(index): \(request.rawParams["id"] ?? "-")")
            return response
          }
        }
      }) { _, port in
        XCTAssertEqual(try RawClient.get("/items/caf%C3%A9", port: port).bodyString, "caf%C3%A9")
        XCTAssertEqual(seen.all, ["2: caf%C3%A9", "1: caf%C3%A9", "0: caf%C3%A9"], "\(threading)")
      }
    }
  }

  /// The request is routed after the middleware, from the path that it has then.
  func testRawRouteVariablesFollowAPathThatMiddlewareRewrote() throws {
    try serve(configure: { server in
      server.get["/items/:id"] = { request in
        .ok(.text("\(request.params["id"] ?? "?")|\(request.rawParams["id"] ?? "?")"))
      }
      server.middleware.append { request, next in
        if request.rawPath.hasPrefix("/old/") {
          request.rawPath = "/items/" + request.rawPath.dropFirst(5)
        }
        return try next(request)
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/old/x%2Fy", port: port).bodyString, "x/y|x%2Fy")
    }
  }

  /// A middleware that calls `next` again for another path does not see the variables of the first.
  func testRawRouteVariablesAreReplacedWhenMiddlewareRoutesAgain() throws {
    let seen = Events()
    try serve(configure: { server in
      server.get["/items/:id"] = { _ in .ok(.text("item")) }
      server.middleware.append { request, next in
        _ = try next(request)
        seen.add("first: \(request.params["id"] ?? "-") \(request.rawParams["id"] ?? "-")")
        request.rawPath = "/nothing/here"
        let response = try next(request)
        seen.add("second: \(request.params.count) \(request.rawParams.count)")
        return response
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/items/a%2Fb", port: port).status, 404)
      XCTAssertEqual(seen.all, ["first: a/b a%2Fb", "second: 0 0"])
    }
  }

  func testRawRouteVariablesOfRequestsWithoutAMatchingRouteAreEmpty() throws {
    let seen = Events()
    try serve(configure: { server in
      server.get["/items/:id"] = { _ in .ok(.text("item")) }
      server.notFoundHandler = { request in .notFound(.text("\(request.rawParams.count)")) }
      server.middleware.append { request, next in
        let response = try next(request)
        seen.add("\(request.method) \(request.rawPath): \(request.rawParams.count)")
        return response
      }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/other/a%2Fb", port: port).bodyString, "0")
      XCTAssertEqual(try RawClient.request("POST", "/items/a%2Fb", port: port).status, 405)
      XCTAssertEqual(seen.all, ["GET /other/a%2Fb: 0", "POST /items/a%2Fb: 0"])
    }
  }

  // MARK: Errors

  func testMiddlewareCanCatchTheErrorsOfTheHandler() throws {
    try serve(configure: { server in
      server.get["/bad"] = { _ in throw NanoHTTPError.badRequest("no good") }
      server.middleware.append { request, next in
        do {
          return try next(request)
        } catch let error as NanoHTTPError {
          return NanoHTTPResponse(statusCode: error.status, body: .json(["error": error.message ?? ""]))
        }
      }
    }) { _, port in
      let response = try RawClient.get("/bad", port: port)
      XCTAssertEqual(response.status, 400)
      XCTAssertEqual(response.header("content-type"), "application/json")
      XCTAssertTrue(response.bodyString.contains("no good"))
      XCTAssertEqual(try RawClient.get("/ok", port: port).bodyString, "fine")
    }
  }

  func testMiddlewareCanThrow() throws {
    try serve(configure: { server in
      server.middleware.append { request, next in
        if request.header("x-blocked") != nil {
          throw NanoHTTPError.forbidden("blocked")
        }
        return try next(request)
      }
    }) { _, port in
      let blocked = try RawClient.get("/ok", port: port, headers: ["X-Blocked: yes", "Connection: close"])
      XCTAssertEqual(blocked.status, 403)
      XCTAssertEqual(blocked.bodyString, "blocked")
      XCTAssertEqual(try RawClient.get("/ok", port: port).status, 200)
    }
  }

  func testAnErrorOfTheHandlerThatNoMiddlewareCatchesStillGetsAnswered() throws {
    try serve(configure: { server in
      server.get["/bad"] = { _ in throw NanoHTTPError.conflict("c") }
      server.middleware.append { request, next in try next(request) }
      server.middleware.append { request, next in try next(request) }
    }) { _, port in
      XCTAssertEqual(try RawClient.get("/bad", port: port).status, 409)
    }
  }

  // MARK: Connections

  func testMiddlewareRunsForEveryRequestOfAKeepAliveConnection() throws {
    let events = Events()
    try serve(configure: { server in
      server.middleware.append { request, next in events.add(request.path); return try next(request) }
    }) { _, port in
      let client = try RawClient(port: port)
      for index in 0..<3 {
        client.send(RawClient.requestText("GET", "/ok?\(index)", headers: ["Connection: keep-alive"]))
        XCTAssertEqual(client.readResponse()?.status, 200)
      }
      XCTAssertEqual(events.all, ["/ok", "/ok", "/ok"])
    }
  }

  func testAServerWithoutMiddlewareRoutesAsBefore() throws {
    try serve(configure: { _ in }) { server, port in
      XCTAssertTrue(server.middleware.isEmpty)
      XCTAssertEqual(try RawClient.get("/ok", port: port).bodyString, "fine")
      XCTAssertEqual(try RawClient.get("/nothing", port: port).status, 404)
    }
  }

  func testMiddlewareOnAServerWithOneThread() throws {
    let events = Events()
    var depth = 0 // shared by all middleware and handlers, without a lock
    try serve(threading: .singleThread, configure: { server in
      server.get["/work"] = { _ in
        depth += 1
        usleep(5_000)
        events.add("handler \(depth)")
        return .ok(.text("done"))
      }
      server.middleware.append { request, next in
        defer { depth -= 1 }
        return try next(request)
      }
    }) { server, port in
      DispatchQueue.concurrentPerform(iterations: 12) { _ in
        _ = try? RawClient.get("/work", port: port)
      }
      XCTAssertEqual(events.all.count, 12)
      XCTAssertEqual(Set(events.all), ["handler 1"], "two requests were handled at the same time")
    }
  }

  /// The pattern of a request log: the method, the path, the status and how long it took.
  func testMiddlewareCanLogRequests() throws {
    let log = Events()
    try serve(configure: { server in
      server.get["/bad"] = { _ in throw NanoHTTPError.badRequest() }
      server.middleware.append { request, next in
        let start = Date()
        let status: Int
        do {
          status = try next(request).statusCode
        } catch let error as NanoHTTPError {
          log.add("\(request.method) \(request.path) \(error.status)")
          throw error
        }
        log.add("\(request.method) \(request.path) \(status) \(Date().timeIntervalSince(start) >= 0)")
        return try next(request)
      }
    }) { _, port in
      _ = try RawClient.get("/ok", port: port)
      _ = try RawClient.get("/bad", port: port)
      XCTAssertTrue(log.all.contains("GET /ok 200 true"), "\(log.all)")
      XCTAssertTrue(log.all.contains("GET /bad 400"), "\(log.all)")
    }
  }
}
