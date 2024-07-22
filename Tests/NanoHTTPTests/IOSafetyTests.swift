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
  var server: NanoHTTPServer!
  var urlSession: URLSession!
  
  override func setUp() {
    super.setUp()
    server = NanoHTTPServer.pingServer()
    urlSession = URLSession(configuration: .default)
  }
  
  override func tearDown() {
    if server.operating {
      server.stop()
    }
    urlSession = nil
    server = nil
    super.tearDown()
  }
  
  func testStopWithActiveConnections() {
    (0...100).forEach { cpt in
      server = NanoHTTPServer.pingServer()
      do {
        try server.start()
        XCTAssertFalse(urlSession.retryPing())
        (0...100).forEach { _ in
          DispatchQueue.global(qos: DispatchQoS.default.qosClass).sync {
            urlSession.pingTask { _, _, _ in }.resume()
          }
        }
        server.stop()
      } catch let error {
        XCTFail("\(cpt): \(error)")
      }
    }
  }
}
