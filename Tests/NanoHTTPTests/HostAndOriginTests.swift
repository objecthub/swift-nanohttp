//
//  HostAndOriginTests.swift
//  NanoHTTPTests
//
//  4.2 (S6): a server can refuse requests by their `Host` (DNS rebinding) and `Origin` (requests that pages of
//  other sites make a browser send, WebSocket hijacking). Both are off by default, and are switched on in the
//  configuration (`hostPolicy`, `originPolicy`) or with middleware.
//

import XCTest
@testable import NanoHTTP

private let bothModes: [NanoHTTPServer.Configuration.Threading] = [.perConnection, .singleThread]

/// A request with exactly the headers that are given (`RawClient.requestText` always adds a `Host`).
private func raw(_ method: String,
                 _ path: String = "/ping",
                 host: String? = "localhost",
                 version: String = "HTTP/1.1",
                 headers: [String] = [],
                 body: [UInt8]? = nil,
                 close: Bool = true) -> [UInt8] {
  var text = "\(method) \(path) \(version)\r\n"
  if let host {
    text += "Host: \(host)\r\n"
  }
  for header in headers {
    text += header + "\r\n"
  }
  if close {
    text += "Connection: close\r\n"
  }
  if let body {
    text += "Content-Length: \(body.count)\r\n"
  }
  return Array((text + "\r\n").utf8) + (body ?? [])
}

/// The status of the answer to one request on a connection of its own.
private func answer(_ port: Int,
                    _ method: String = "GET",
                    host: String? = "localhost",
                    version: String = "HTTP/1.1",
                    headers: [String] = []) throws -> RawResponse? {
  let client = try RawClient(port: port)
  defer { client.close() }
  client.send(raw(method, host: host, version: version, headers: headers))
  return client.readResponse()
}

// MARK: - Parsing

final class HostAndOriginParsingTests: XCTestCase {

  private func authority(_ text: String) -> NanoRequestPolicy.Authority? {
    return NanoRequestPolicy.authority(text)
  }

  func testAuthorities() {
    XCTAssertEqual(self.authority("localhost"), NanoRequestPolicy.Authority(host: "localhost", port: nil))
    XCTAssertEqual(self.authority("LocalHost:8080"), NanoRequestPolicy.Authority(host: "localhost", port: 8080))
    XCTAssertEqual(self.authority(" example.com:80 "), NanoRequestPolicy.Authority(host: "example.com", port: 80))
    XCTAssertEqual(self.authority("127.0.0.1:0"), NanoRequestPolicy.Authority(host: "127.0.0.1", port: 0))
    XCTAssertEqual(self.authority("[::1]"), NanoRequestPolicy.Authority(host: "[::1]", port: nil))
    XCTAssertEqual(self.authority("[FE80::1]:9"), NanoRequestPolicy.Authority(host: "[fe80::1]", port: 9))
    XCTAssertEqual(self.authority("a:65535"), NanoRequestPolicy.Authority(host: "a", port: 65535))
  }

  func testTextThatIsNoAuthorityIsRejected() {
    for text in ["", " ", "a:", ":80", "a:b", "a:b:c", "a:65536", "a:-1", "a:+1", "a:8o", "[::1", "[]", "[::1]x", "[::1]:",
                 "a b", "user@host", "host/path", "host?x", "host#x", "a%2e", "a\\b", "a[b]", "a\u{7F}", "é.example"] {
      XCTAssertNil(self.authority(text), "\"\(text)\" is no authority")
    }
  }

  func testOrigins() {
    let local = NanoRequestPolicy.origin("http://localhost:3000")
    XCTAssertEqual(local?.scheme, "http")
    XCTAssertEqual(local?.authority.host, "localhost")
    XCTAssertEqual(local?.effectivePort, 3000)
    XCTAssertEqual(NanoRequestPolicy.origin("https://App.Example")?.effectivePort, 443)
    XCTAssertEqual(NanoRequestPolicy.origin("HTTP://a.b")?.effectivePort, 80)
    XCTAssertEqual(NanoRequestPolicy.origin("wss://a.b")?.effectivePort, 443)
    XCTAssertNil(NanoRequestPolicy.origin("chrome-extension://abcdef")?.effectivePort, "no default port for other schemes")
  }

  func testTextThatIsNoOriginIsRejected() {
    for text in ["null", "", "http://", "http://a/path", "//a", "://a", "1http://a", "http://a:b", "http://user@a", "http:/a",
                 "localhost:3000"] {
      XCTAssertNil(NanoRequestPolicy.origin(text), "\"\(text)\" is no origin")
    }
  }
}

// MARK: - Host

final class HostPolicyTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading = .perConnection,
                     listenAddress: NanoHTTPServer.NanoListenAddress = .loopback,
                     policy: NanoHTTPServer.Configuration.HostPolicy,
                     logger: CapturingLogger = CapturingLogger(),
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.configuration.listenAddress = listenAddress
      server.configuration.hostPolicy = policy
      server.configuration.logger = logger
      server["/ping"] = { _ in .ok(.text("pong")) }
    }, body)
  }

  func testTheDefaultServesEveryHostAndOrigin() throws {
    XCTAssertEqual(NanoHTTPServer.Configuration().hostPolicy, .any)
    XCTAssertEqual(NanoHTTPServer.Configuration().originPolicy, .any)
    for threading in bothModes {
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server["/ping"] = { _ in .ok(.text("pong")) }
      }) { _, port in
        for host in ["evil.example", "evil.example:8080", "[::2]", "", "not a host", "a:b:c"] {
          let response = try answer(port, "POST", host: host, headers: ["Origin: http://evil.example"])
          XCTAssertEqual(response?.status, 200, "\(threading): Host \"\(host)\"")
        }
      }
    }
  }

  func testAutomaticServesTheNamesOfTheLoopbackAddress() throws {
    for threading in bothModes {
      try serve(threading, policy: .automatic) { _, port in
        for host in ["localhost", "LOCALHOST", "localhost:\(port)", "localhost:9999", "127.0.0.1", "127.0.0.1:\(port)", "[::1]",
                     "[::1]:\(port)"] {
          XCTAssertEqual(try answer(port, host: host)?.status, 200, "\(threading): Host \"\(host)\"")
        }
      }
    }
  }

  func testAutomaticRefusesOtherHosts() throws {
    for threading in bothModes {
      try serve(threading, policy: .automatic) { _, port in
        for host in ["evil.example", "evil.example:\(port)", "localhost.evil.example", "evil.localhost.example",
                     "127.0.0.1.evil.example", "127.0.0.2", "0.0.0.0", "[::2]", "localhost:abc", "", "a:b:c", "localhost/x"] {
          let response = try answer(port, host: host)
          XCTAssertEqual(response?.status, 403, "\(threading): Host \"\(host)\"")
          XCTAssertTrue(response?.bodyString.hasPrefix("Forbidden") ?? false, "\(String(describing: response?.bodyString))")
        }
      }
    }
  }

  func testARequestWithoutAHostIsServed() throws {
    try serve(policy: .automatic) { _, port in
      XCTAssertEqual(try answer(port, host: nil, version: "HTTP/1.0")?.status, 200)
    }
    try serve(policy: .hosts(["example.com"])) { _, port in
      XCTAssertEqual(try answer(port, host: nil, version: "HTTP/1.0")?.status, 200)
    }
  }

  func testAutomaticChecksNothingForAServerThatListensAtAllInterfaces() throws {
    for threading in bothModes {
      try serve(threading, listenAddress: .allInterfaces, policy: .automatic) { _, port in
        XCTAssertEqual(try answer(port, host: "evil.example")?.status, 200, "\(threading)")
        XCTAssertEqual(try answer(port, host: "192.168.1.20:\(port)")?.status, 200, "\(threading)")
      }
    }
  }

  func testAnAddressOfTheLoopbackRangeCountsAsLoopback() throws {
    try serve(listenAddress: .address("127.0.0.1"), policy: .automatic) { _, port in
      XCTAssertEqual(try answer(port, host: "localhost")?.status, 200)
      XCTAssertEqual(try answer(port, host: "evil.example")?.status, 403)
    }
  }

  func testHostsListsTheAllowedHosts() throws {
    for threading in bothModes {
      try serve(threading, policy: .hosts(["example.com", "App.Test:8080", "[::1]"])) { _, port in
        for host in ["example.com", "EXAMPLE.COM", "example.com:1234", "app.test:8080", "APP.TEST:8080", "[::1]", "[::1]:5"] {
          XCTAssertEqual(try answer(port, host: host)?.status, 200, "\(threading): Host \"\(host)\"")
        }
        for host in ["app.test", "app.test:9090", "evil.example", "example.com.evil.example", "sub.example.com", "localhost",
                     "[::2]"] {
          XCTAssertEqual(try answer(port, host: host)?.status, 403, "\(threading): Host \"\(host)\"")
        }
      }
    }
  }

  func testARefusalIsLoggedAsAWarningWithTheHost() throws {
    let logger = CapturingLogger()
    try serve(policy: .automatic, logger: logger) { _, port in
      XCTAssertEqual(try answer(port, host: "evil.example")?.status, 403)
    }
    let messages = logger.messages(containing: "Refused GET /ping", level: .warning)
    XCTAssertEqual(messages.count, 1, "\(logger.messages)")
    XCTAssertTrue(messages.first?.contains("\"evil.example\"") ?? false, "\(messages)")
  }

  func testTheConnectionStaysUsableAfterARefusal() throws {
    try serve(policy: .hosts(["example.com"])) { _, port in
      let client = try RawClient(port: port)
      client.send(raw("POST", host: "evil.example", body: Array("some body".utf8), close: false))
      XCTAssertEqual(client.readResponse()?.status, 403)
      client.send(raw("GET", host: "example.com", close: false))
      XCTAssertEqual(client.readResponse()?.status, 200, "the body of the refused request was read: the next one is understood")
    }
  }

  func testRefusedRequestsDoNotReachTheMiddlewareOrTheHandler() throws {
    let lock = NSLock()
    var seen = 0
    try withTestServer(configure: { server in
      server.configuration.hostPolicy = .automatic
      server.middleware.append { request, next in
        lock.lock(); seen += 1; lock.unlock()
        return try next(request)
      }
      server["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      XCTAssertEqual(try answer(port, host: "evil.example")?.status, 403)
      XCTAssertEqual(seen, 0)
      XCTAssertEqual(try answer(port, host: "localhost")?.status, 200)
      XCTAssertEqual(seen, 1)
    }
  }
}

// MARK: - Origin

final class OriginPolicyTests: XCTestCase {

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading = .perConnection,
                     policy: NanoHTTPServer.Configuration.OriginPolicy,
                     logger: CapturingLogger = CapturingLogger(),
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server.configuration.originPolicy = policy
      server.configuration.logger = logger
      server["/ping"] = { _ in .ok(.text("pong")) }
      server["/ws"] = NanoWebSocket.handler(text: { session, text in session.writeText(text) })
    }, body)
  }

  func testSameOriginServesThePagesOfTheServerItself() throws {
    for threading in bothModes {
      try serve(threading, policy: .sameOrigin) { _, port in
        let host = "127.0.0.1:\(port)"
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
          XCTAssertEqual(try answer(port, method, host: host, headers: ["Origin: http://\(host)"])?.status, 200,
                         "\(threading): \(method)")
        }
        XCTAssertEqual(try answer(port, "POST", host: "LocalHost:\(port)", headers: ["Origin: http://localhost:\(port)"])?.status, 200)
      }
    }
  }

  func testSameOriginRefusesRequestsOfOtherSites() throws {
    for threading in bothModes {
      try serve(threading, policy: .sameOrigin) { _, port in
        let host = "127.0.0.1:\(port)"
        let foreign = ["http://evil.example", "https://evil.example:\(port)", "http://127.0.0.1:\(port + 1)", "http://localhost:\(port)",
                       "http://127.0.0.1.evil.example:\(port)", "null", "file://", "chrome-extension://abcdef", "garbage"]
        for origin in foreign {
          for method in ["POST", "PUT", "PATCH", "DELETE"] {
            let response = try answer(port, method, host: host, headers: ["Origin: \(origin)"])
            XCTAssertEqual(response?.status, 403, "\(threading): \(method) from \(origin)")
          }
        }
      }
    }
  }

  func testRequestsWithoutAnOriginAreServed() throws {
    for threading in bothModes {
      try serve(threading, policy: .sameOrigin) { _, port in
        for method in ["POST", "PUT", "PATCH", "DELETE", "GET"] {
          XCTAssertEqual(try answer(port, method)?.status, 200, "\(threading): \(method)")
        }
      }
    }
  }

  func testRequestsThatDoNotChangeAnythingAreNotChecked() throws {
    try serve(policy: .sameOrigin) { _, port in
      for method in ["GET", "HEAD", "OPTIONS"] {
        let status = try answer(port, method, headers: ["Origin: http://evil.example"])?.status
        XCTAssertNotNil(status)
        XCTAssertNotEqual(status, 403, method)
      }
    }
  }

  func testAWebSocketHandshakeIsChecked() throws {
    for threading in bothModes {
      try serve(threading, policy: .sameOrigin) { _, port in
        let host = "127.0.0.1:\(port)"
        func handshake(origin: String?) throws -> Int? {
          var headers = ["Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Version: 13",
                         "Sec-WebSocket-Key: \(WS.key)"]
          if let origin {
            headers.append("Origin: \(origin)")
          }
          let client = try RawClient(port: port)
          defer { client.close() }
          client.send(raw("GET", "/ws", host: host, headers: headers, close: false))
          return client.readResponse(head: true)?.status
        }
        XCTAssertEqual(try handshake(origin: "http://evil.example"), 403, "\(threading): a page of another site")
        XCTAssertEqual(try handshake(origin: "null"), 403, "\(threading)")
        XCTAssertEqual(try handshake(origin: "http://\(host)"), 101, "\(threading): a page of the server")
        XCTAssertEqual(try handshake(origin: nil), 101, "\(threading): a client that is no browser")
      }
    }
  }

  func testListedOriginsAreServedBesideTheServerItself() throws {
    try serve(policy: .origins(["http://localhost:3000", "https://App.Example"])) { _, port in
      for origin in ["http://localhost:3000", "HTTP://LOCALHOST:3000", "https://app.example", "https://app.example:443",
                     "http://127.0.0.1:\(port)"] {
        XCTAssertEqual(try answer(port, "POST", host: "127.0.0.1:\(port)", headers: ["Origin: \(origin)"])?.status, 200, origin)
      }
      for origin in ["http://localhost:3001", "http://localhost", "https://localhost:3000", "http://app.example", "http://evil.example", "null"] {
        XCTAssertEqual(try answer(port, "POST", host: "127.0.0.1:\(port)", headers: ["Origin: \(origin)"])?.status, 403, origin)
      }
    }
  }

  func testAHostWithoutAPortIsTheDefaultPortOfThePage() throws {
    try serve(policy: .sameOrigin) { _, port in
      // A server behind something that terminates TLS sees `Host: app.example`, from pages at https://app.example.
      XCTAssertEqual(try answer(port, "POST", host: "app.example", headers: ["Origin: https://app.example"])?.status, 200)
      XCTAssertEqual(try answer(port, "POST", host: "app.example", headers: ["Origin: http://app.example"])?.status, 200)
      XCTAssertEqual(try answer(port, "POST", host: "app.example:8080", headers: ["Origin: https://app.example"])?.status, 403)
      XCTAssertEqual(try answer(port, "POST", host: nil, version: "HTTP/1.0", headers: ["Origin: https://app.example"])?.status, 403)
    }
  }

  func testARefusalIsLoggedAsAWarningWithTheOrigin() throws {
    let logger = CapturingLogger()
    try serve(policy: .sameOrigin, logger: logger) { _, port in
      XCTAssertEqual(try answer(port, "POST", headers: ["Origin: http://evil.example"])?.status, 403)
    }
    let messages = logger.messages(containing: "Refused POST /ping", level: .warning)
    XCTAssertEqual(messages.count, 1, "\(logger.messages)")
    XCTAssertTrue(messages.first?.contains("\"http://evil.example\"") ?? false, "\(messages)")
  }

  func testBothPoliciesApplyTogether() throws {
    try withTestServer(configure: { server in
      server.configuration.hostPolicy = .automatic
      server.configuration.originPolicy = .sameOrigin
      server["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      let host = "localhost:\(port)"
      XCTAssertEqual(try answer(port, "POST", host: host, headers: ["Origin: http://\(host)"])?.status, 200)
      XCTAssertEqual(try answer(port, "POST", host: host, headers: ["Origin: http://evil.example"])?.status, 403)
      XCTAssertEqual(try answer(port, "POST", host: "evil.example", headers: ["Origin: http://evil.example"])?.status, 403)
      XCTAssertEqual(try answer(port, "GET", host: "evil.example")?.status, 403, "rebinding: the page is at the host of the attacker")
    }
  }
}

// MARK: - The middleware

final class AllowlistMiddlewareTests: XCTestCase {

  func testHostAllowlistRefusesOtherHosts() throws {
    try withTestServer(configure: { server in
      server.middleware.append(NanoMiddleware.hostAllowlist(["localhost", "app.test:8080"]))
      server["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      XCTAssertEqual(try answer(port, host: "LOCALHOST:\(port)")?.status, 200)
      XCTAssertEqual(try answer(port, host: "app.test:8080")?.status, 200)
      XCTAssertEqual(try answer(port, host: nil, version: "HTTP/1.0")?.status, 200)
      XCTAssertEqual(try answer(port, host: "app.test:9")?.status, 403)
      XCTAssertEqual(try answer(port, host: "evil.example")?.status, 403)
    }
  }

  func testOriginAllowlistRefusesOtherSites() throws {
    for threading in bothModes {
      try withTestServer(configure: { server in
        server.configuration.threading = threading
        server.middleware.append(NanoMiddleware.originAllowlist(["https://app.example"]))
        server["/ping"] = { _ in .ok(.text("pong")) }
      }) { _, port in
        XCTAssertEqual(try answer(port, "POST", host: "localhost:\(port)", headers: ["Origin: http://localhost:\(port)"])?.status, 200)
        XCTAssertEqual(try answer(port, "POST", headers: ["Origin: https://app.example"])?.status, 200, "\(threading)")
        XCTAssertEqual(try answer(port, "POST", headers: ["Origin: https://evil.example"])?.status, 403, "\(threading)")
        XCTAssertEqual(try answer(port, "POST")?.status, 200, "no Origin")
        XCTAssertNotEqual(try answer(port, "GET", headers: ["Origin: https://evil.example"])?.status, 403, "a read")
      }
    }
  }

  func testTheMiddlewareRunsInTheOrderOfTheChain() throws {
    let logger = CapturingLogger()
    try withTestServer(configure: { server in
      server.middleware.append { request, next in
        let response = try next(request)
        logger.info("\(request.method) \(request.rawPath) -> \(response.statusCode)")
        return response
      }
      server.middleware.append(NanoMiddleware.hostAllowlist(["localhost"]))
      server["/ping"] = { _ in .ok(.text("pong")) }
    }) { _, port in
      // The error of the allowlist is turned into the response by the server, outside of the chain: an outer
      // middleware sees it as an error, not as a response.
      XCTAssertEqual(try answer(port, host: "evil.example")?.status, 403)
      XCTAssertEqual(try answer(port, host: "localhost")?.status, 200)
    }
    XCTAssertEqual(logger.messages, ["GET /ping -> 200"])
  }
}
