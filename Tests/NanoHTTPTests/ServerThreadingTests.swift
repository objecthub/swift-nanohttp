//
//  ServerThreadingTests.swift
//  NanoHTTPTests
//
//  Created by Matthias Zenger on 22/07/2024.
//  Based on `ServerThreadingTests` of framework `Swifter` by Victor Sigler and Damian Kołakowski.
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

final class ServerThreadingTests: XCTestCase {
  var server: NanoHTTPServer!
  
  override func setUp() {
    super.setUp()
    server = NanoHTTPServer()
  }
  
  override func tearDown() {
    if server.operating {
      server.stop()
    }
    server = nil
    super.tearDown()
  }
  
  private func startServer() throws -> URL {
    try server.start(0)
    return URL(string: "http://127.0.0.1:\(try server.port())")!
  }
  
  func testShouldHandleTheRequestInDifferentTimeIntervals() throws {
    let path = "/a/b/c"
    let queue = DispatchQueue(label: "com.nanohttp.threading")
    server.get["/a/:b/c"] = { .ok(.htmlBody("You asked for " + $0.path)) }
    let hostURL = try startServer()
    let requestExpectation = expectation(description: "Request should finish.")
    requestExpectation.expectedFulfillmentCount = 3
    (1...3).forEach { index in
      queue.asyncAfter(deadline: .now() + .seconds(index)) {
        let task = URLSession.shared.executeAsyncTask(hostURL: hostURL, path: path) { (_, response, _ ) in
          let statusCode = (response as? HTTPURLResponse)?.statusCode
          XCTAssertEqual(statusCode, 200, "\(hostURL)")
          requestExpectation.fulfill()
        }
        task.resume()
      }
    }
    waitForExpectations(timeout: 10, handler: nil)
  }
  
  /// All requests are in flight at the same time and the test waits for *all* of them. (It used
  /// to finish when the first one answered; `tearDown` then stopped the server and the remaining
  /// requests failed after the test had ended, which made the suite flaky and attributed the
  /// failure to an unrelated test.)
  func testShouldHandleTheSameRequestConcurrently() throws {
    let count = 20
    server.get["/a/:b/c"] = { .ok(.htmlBody("You asked for " + $0.path)) }
    let hostURL = try startServer()
    let requestExpectation = expectation(description: "Should handle the requests concurrently")
    requestExpectation.expectedFulfillmentCount = count
    DispatchQueue.concurrentPerform(iterations: count) { _ in
      let task = URLSession.shared.executeAsyncTask(hostURL: hostURL, path: "/a/b/c") { (_, response, _ ) in
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(statusCode, 200)
        requestExpectation.fulfill()
      }
      task.resume()
    }
    waitForExpectations(timeout: 15, handler: nil)
  }
}


extension URLSession {
  func executeAsyncTask(
    hostURL: URL,
    path: String,
    completionHandler handler: @escaping (Data?, URLResponse?, Error?) -> Void
  ) -> URLSessionDataTask {
    return self.dataTask(with: hostURL.appendingPathComponent(path), completionHandler: handler)
  }
}
