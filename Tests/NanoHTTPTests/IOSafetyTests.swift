//
//  IOSafetyTests.swift
//  NanoHTTPTests
//
//  Created by Matthias Zenger on 22/07/2024.
//  Based on `IOSafetyTests` of framework `Swifter` by Brian Gerstle and Damian Kołakowski.
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
#if os(Linux)
import FoundationNetworking
#endif
@testable import NanoHTTP

class IOSafetyTests: XCTestCase {
  var urlSession: URLSession? = nil
  
  override func setUp() {
    super.setUp()
    self.urlSession = URLSession(configuration: .default)
  }
  
  override func tearDown() {
    self.urlSession = nil
    super.tearDown()
  }
  
  /// Starting and stopping servers while requests are in flight must not crash or hang. Every
  /// server binds its own ephemeral port; a failure to bind is a test failure (it used to be
  /// silently ignored, which let the test pass without testing anything).
  func testStopWithActiveConnections() throws {
    for iteration in 0...100 {
      let server = NanoHTTPServer.pingServer()
      try server.start(0, forceIPv4: true)
      let hostURL = URL(string: "http://127.0.0.1:\(try server.port())")!
      XCTAssertFalse(urlSession?.retryPing(hostURL: hostURL) ?? true, "iteration \(iteration)")
      (0...100).forEach { _ in
        DispatchQueue.global(qos: DispatchQoS.default.qosClass).sync {
          urlSession?.pingTask(hostURL: hostURL) { _, _, _ in }.resume()
        }
      }
      server.stop()
    }
  }
}
