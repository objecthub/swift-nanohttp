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
  
  func testShouldHandleTheRequestInDifferentTimeIntervals() {
    
    let path = "/a/:b/c"
    let queue = DispatchQueue(label: "com.swifter.threading")
    let hostURL: URL
    
    server.get[path] = { .ok(.htmlBody("You asked for " + $0.path)) }
    
    do {
      
      #if os(Linux)
      try server.start(9081)
      hostURL = URL(string: "http://localhost:9081")!
      #else
      try server.start()
      hostURL = defaultLocalhost
      #endif
      
      let requestExpectation = expectation(description: "Request should finish.")
      requestExpectation.expectedFulfillmentCount = 3
      
      (1...3).forEach { index in
        queue.asyncAfter(deadline: .now() + .seconds(index)) {
          let task = URLSession.shared.executeAsyncTask(hostURL: hostURL, path: path) { (_, response, _ ) in
            requestExpectation.fulfill()
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            XCTAssertNotNil(statusCode)
            XCTAssertEqual(statusCode, 200, "\(hostURL)")
          }
          
          task.resume()
        }
      }
      
    } catch let error {
      XCTFail("\(error)")
    }
    
    waitForExpectations(timeout: 10, handler: nil)
  }
  
  func testShouldHandleTheSameRequestConcurrently() {
    
    let path = "/a/:b/c"
    server.get[path] = { .ok(.htmlBody("You asked for " + $0.path)) }
    
    var requestExpectation: XCTestExpectation? = expectation(description: "Should handle the request concurrently")
    
    do {
      
      try server.start()
      let downloadGroup = DispatchGroup()
      
      DispatchQueue.concurrentPerform(iterations: 3) { _ in
        downloadGroup.enter()
        
        let task = URLSession.shared.executeAsyncTask(path: path) { (_, response, _ ) in
          
          let statusCode = (response as? HTTPURLResponse)?.statusCode
          XCTAssertNotNil(statusCode)
          XCTAssertEqual(statusCode, 200)
          requestExpectation?.fulfill()
          requestExpectation = nil
          downloadGroup.leave()
        }
        
        task.resume()
      }
      
    } catch let error {
      XCTFail("\(error)")
    }
    
    waitForExpectations(timeout: 15, handler: nil)
  }
}


extension URLSession {
  func executeAsyncTask(
    hostURL: URL = defaultLocalhost,
    path: String,
    completionHandler handler: @escaping (Data?, URLResponse?, Error?) -> Void
  ) -> URLSessionDataTask {
    return self.dataTask(with: hostURL.appendingPathComponent(path), completionHandler: handler)
  }
}

