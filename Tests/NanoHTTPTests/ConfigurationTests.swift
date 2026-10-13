//
//  ConfigurationTests.swift
//  NanoHTTPTests
//
//  2.0: a server is configured with `NanoHTTPServerIO.Configuration`. It listens at the loopback
//  address unless told otherwise (S4 made a bad address an error; the default used to be "all
//  interfaces").
//

import XCTest
import Darwin
@testable import NanoHTTP

/// Does a TCP connection to `host` (an address in text form) at `port` succeed?
private func canConnect(to host: String, port: Int) -> Bool {
  var hints = addrinfo()
  hints.ai_socktype = SOCK_STREAM
  hints.ai_flags = AI_NUMERICHOST
  var result: UnsafeMutablePointer<addrinfo>?
  guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
    return false
  }
  defer {
    freeaddrinfo(result)
  }
  let descriptor = socket(info.pointee.ai_family, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    return false
  }
  defer {
    Darwin.close(descriptor)
  }
  return Darwin.connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
}

// MARK: - Where the server listens

final class ListenAddressTests: XCTestCase {

  private func start(_ address: NanoHTTPServerIO.NanoListenAddress) throws -> NanoHTTPServer {
    let server = NanoHTTPServer()
    server.configuration.listenAddress = address
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    try server.start(0)
    return server
  }

  private var lanAddress: String? {
    return NetworkInterface.localIP(ipv4: true).flatMap { $0.hasPrefix("127.") ? nil : $0 }
  }

  func testTheDefaultIsLoopback() throws {
    XCTAssertEqual(NanoHTTPServer.Configuration().listenAddress, .loopback)
    let server = NanoHTTPServer()
    XCTAssertEqual(server.configuration.listenAddress, .loopback)
    try server.start(0)
    defer { server.stop() }
    XCTAssertTrue(try server.isIPv4())
    XCTAssertEqual(try RawClient.get("/ping", port: try server.port()).status, 404)
  }

  /// A server that has not been configured cannot be reached through the address of a network
  /// interface: it used to listen on all of them.
  func testDefaultServerIsNotReachableFromTheNetworkInterface() throws {
    guard let lanAddress else {
      throw XCTSkip("no network interface with an IPv4 address")
    }
    let server = NanoHTTPServer()
    try server.start(0)
    defer { server.stop() }
    let port = try server.port()
    XCTAssertTrue(canConnect(to: "127.0.0.1", port: port))
    XCTAssertFalse(canConnect(to: lanAddress, port: port), "reachable at \(lanAddress)")
  }

  func testAllInterfacesIsReachableFromEverywhere() throws {
    let server = try start(.allInterfaces)
    defer { server.stop() }
    let port = try server.port()
    XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)  // IPv4 on the dual-stack socket
    XCTAssertTrue(canConnect(to: "127.0.0.1", port: port))
    XCTAssertTrue(canConnect(to: "::1", port: port))
    if let lanAddress {
      XCTAssertTrue(canConnect(to: lanAddress, port: port), "not reachable at \(lanAddress)")
    }
  }

  func testAnIPv4AddressBindsThatAddressOnly() throws {
    let server = try start(.address("127.0.0.1"))
    defer { server.stop() }
    let port = try server.port()
    XCTAssertTrue(try server.isIPv4())
    XCTAssertEqual(try RawClient.get("/ping", port: port).status, 200)
    XCTAssertFalse(canConnect(to: "::1", port: port))
  }

  func testTheIPv4WildcardAddressIsAllIPv4Interfaces() throws {
    guard let lanAddress else {
      throw XCTSkip("no network interface with an IPv4 address")
    }
    let server = try start(.address("0.0.0.0"))
    defer { server.stop() }
    XCTAssertTrue(canConnect(to: lanAddress, port: try server.port()))
  }

  func testAnIPv6AddressBindsAnIPv6Socket() throws {
    let server = try start(.address("::1"))
    defer { server.stop() }
    let port = try server.port()
    XCTAssertTrue(canConnect(to: "::1", port: port))
    XCTAssertFalse(canConnect(to: "127.0.0.1", port: port))
  }

  func testInvalidAddressesThrowInsteadOfBindingEverywhere() {
    for address in ["127.0.0.1x", "", "localhost", "256.0.0.1", "::1x", " 127.0.0.1", "0.0.0.0/0", "*"] {
      let server = NanoHTTPServer()
      server.configuration.listenAddress = .address(address)
      XCTAssertThrowsError(try server.start(0), "\"\(address)\"") { error in
        guard case NanoSocketError.bindFailed(let message) = error else {
          return XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(message.contains("invalid listen address"), message)
      }
      XCTAssertEqual(server.state, .stopped)
    }
  }

  func testAnAddressThatCannotBeBoundThrowsToo() {
    // Well-formed, but not an address of this machine: bind fails.
    for address in ["203.0.113.7", "2001:db8::1"] {
      let server = NanoHTTPServer()
      server.configuration.listenAddress = .address(address)
      XCTAssertThrowsError(try server.start(0), address) { error in
        guard case NanoSocketError.bindFailed = error else {
          return XCTFail("unexpected error \(error)")
        }
      }
      XCTAssertEqual(server.state, .stopped)
    }
  }

  func testRejectedAddressDoesNotLeakTheListeningSocket() {
    let before = openFileDescriptorCount()
    for _ in 0..<20 {
      let server = NanoHTTPServer()
      server.configuration.listenAddress = .address("not an address")
      XCTAssertThrowsError(try server.start(0))
      server.configuration.listenAddress = .address("203.0.113.7")
      XCTAssertThrowsError(try server.start(0))
    }
    // The count is that of the whole process: sockets of earlier tests are still being closed by their threads.
    XCTAssertTrue(eventually(timeout: 3) { openFileDescriptorCount() - before < 5 },
                  "\(openFileDescriptorCount() - before) descriptors more than before: 40 would be a leak")
  }
}

// MARK: - The configuration object

final class ServerConfigurationTests: XCTestCase {

  func testDefaults() {
    let configuration = NanoHTTPServer.Configuration()
    XCTAssertEqual(configuration.listenAddress, .loopback)
    XCTAssertEqual(configuration.limits, NanoHTTPParser.Limits())
    XCTAssertEqual(configuration.acceptQoS, .userInitiated)
    XCTAssertEqual(configuration.connectionQoS, .userInitiated)
  }

  func testAServerIsCreatedWithAConfiguration() throws {
    var configuration = NanoHTTPServer.Configuration()
    configuration.limits.maxLineLength = 100
    let server = NanoHTTPServer(configuration: configuration)
    XCTAssertEqual(server.configuration.limits.maxLineLength, 100)
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    try server.start(0)
    defer { server.stop() }
    let client = try RawClient(port: try server.port())
    client.send("GET /" + String(repeating: "a", count: 200) + " HTTP/1.1\r\n\r\n")
    XCTAssertEqual(client.readResponse()?.status, 414)
  }

  func testAChangeAppliesWhenTheServerIsStartedAgain() throws {
    let server = NanoHTTPServer()
    server.get["/ping"] = { _ in .ok(.text("pong")) }
    try server.start(0)
    defer { server.stop() }
    // A running server keeps the configuration it was started with ...
    server.configuration.limits.maxLineLength = 50
    let long = "GET /" + String(repeating: "a", count: 100) + " HTTP/1.1\r\n\r\n"
    let before = try RawClient(port: try server.port())
    before.send(long)
    XCTAssertEqual(before.readResponse()?.status, 404)
    // ... and uses the new one the next time.
    server.stop()
    try server.start(0)
    let after = try RawClient(port: try server.port())
    after.send(long)
    XCTAssertEqual(after.readResponse()?.status, 414)
  }

  func testTheSubclassKeepsTheConfigurationInitializer() throws {
    final class Special: NanoHTTPServer {}
    var configuration = NanoHTTPServer.Configuration()
    configuration.listenAddress = .address("127.0.0.1")
    let server = Special(configuration: configuration)
    XCTAssertEqual(server.configuration.listenAddress, .address("127.0.0.1"))
  }
}
