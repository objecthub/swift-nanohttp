//
//  PingServer.swift
//  NanoHTTPTests
//
//  Created by Matthias Zenger on 22/07/2024.
//  Based on `PingServer` of framework `Swifter` by Brian Gerstle and Damian Kołakowski.
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

import Foundation
#if os(Linux)
import FoundationNetworking
#endif
@testable import NanoHTTP

// Server
extension NanoHTTPServer {
  class func pingServer() -> NanoHTTPServer {
    let server = NanoHTTPServer()
    server.get["/ping"] = { _ in
      return .ok(.text("pong!"))
    }
    return server
  }
}

let defaultLocalhost = URL(string: "http://localhost:8080")!

// Client
extension URLSession {
  func pingTask(
    hostURL: URL = defaultLocalhost,
    completionHandler handler: @escaping (Data?, URLResponse?, Error?) -> Void
  ) -> URLSessionDataTask {
    return self.dataTask(with: hostURL.appendingPathComponent("/ping"), completionHandler: handler)
  }
  
  func retryPing(
    hostURL: URL = defaultLocalhost,
    timeout: Double = 2.0
  ) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    self.signalIfPongReceived(semaphore, hostURL: hostURL)
    let timeoutDate = NSDate().addingTimeInterval(timeout)
    var timedOut = false
    while semaphore.wait(timeout: DispatchTime.now()) != DispatchTimeoutResult.timedOut {
      if NSDate().laterDate(timeoutDate as Date) != timeoutDate as Date {
        timedOut = true
        break
      }
      let mode = RunLoop.Mode.common
      _ = RunLoop.current.run(
        mode: mode,
        before: NSDate.distantFuture
      )
    }
    
    return timedOut
  }
  
  func signalIfPongReceived(_ semaphore: DispatchSemaphore, hostURL: URL) {
    pingTask(hostURL: hostURL) { _, response, _ in
      if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
        semaphore.signal()
      } else {
        self.signalIfPongReceived(semaphore, hostURL: hostURL)
      }
    }.resume()
  }
}
