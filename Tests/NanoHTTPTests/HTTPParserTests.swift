//
//  HTTPParserTests.swift
//  NanoHTTPTests
//
//  Created by Matthias Zenger on 22/07/2024.
//  Based on `SwifterTestsHttpParser` of framework `Swifter` by Damian Kołakowski.
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
@testable import NanoHTTP

class SwifterTestsHttpParser: XCTestCase {
  
  /// A specialized Socket which creates a linked socket pair with a pipe, and
  /// immediately writes in fixed data. This enables tests to static fixture
  /// data into the regular Socket flow.
  class TestSocket: NanoSocket {
    init(_ content: String) {
        /// Create an array to hold the read and write sockets that pipe creates
      var fds = [Int32](repeating: 0, count: 2)
      fds.withUnsafeMutableBufferPointer { ptr in
        let received = pipe(ptr.baseAddress!)
        guard received >= 0 else { fatalError("Pipe error!") }
      }
      
        // Extract the read and write handles into friendly variables
      let fdRead = fds[0]
      let fdWrite = fds[1]
      
        // Set non-blocking I/O on both sockets. This is required!
      _ = fcntl(fdWrite, F_SETFL, O_NONBLOCK)
      _ = fcntl(fdRead, F_SETFL, O_NONBLOCK)
      
        // Push the content bytes into the write socket.
      content.withCString { stringPointer in
          // Count will be either >=0 to indicate bytes written, or -1
          // if the bytes will be written later (non-blocking).
        let count = write(fdWrite, stringPointer, content.lengthOfBytes(using: .utf8) + 1)
        guard count != -1 || errno == EAGAIN else { fatalError("Write error!") }
      }
      
        // Close the write socket immediately. The OS will add an EOF byte
        // and the read socket will remain open.
#if os(Linux)
      Glibc.close(fdWrite)
#else
      Darwin.close(fdWrite) // the super instance will close fdRead in deinit!
#endif
      
      super.init(socketFileDescriptor: fdRead)
    }
  }
  
  func testParser() {
    var parser = NanoHTTPParser(socket: TestSocket(""))
    do {
      _ = try parser.readHttpRequest()
      XCTAssert(false, "Parser should throw an error if socket is empty.")
    } catch { }
    parser = NanoHTTPParser(socket: TestSocket("12345678"))
    do {
      _ = try parser.readHttpRequest()
      XCTAssert(false, "Parser should throw an error if status line has single token.")
    } catch { }
    parser = NanoHTTPParser(socket: TestSocket("GET HTTP/1.0"))
    do {
      _ = try parser.readHttpRequest()
      XCTAssert(false, "Parser should throw an error if status line has not enough tokens.")
    } catch { }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0"))
    do {
      _ = try parser.readHttpRequest()
      XCTAssert(false, "Parser should throw an error if there is no next line symbol.")
    } catch { }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0"))
    do {
      _ = try parser.readHttpRequest()
      XCTAssert(false, "Parser should throw an error if there is no next line symbol.")
    } catch { }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\r"))
    do {
      _ = try parser.readHttpRequest()
      XCTAssert(false, "Parser should throw an error if there is no next line symbol.")
    } catch { }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\n"))
    do {
      _ = try parser.readHttpRequest()
      XCTAssert(false, "Parser should throw an error if there is no 'Content-Length' header.")
    } catch { }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\r\nContent-Length: 0\r\n\r\n"))
    do {
      _ = try parser.readHttpRequest()
    } catch {
      XCTAssert(false, "Parser should not throw any errors if there is a valid 'Content-Length' header.")
    }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\nContent-Length: 0\r\n\n"))
    do {
      _ = try parser.readHttpRequest()
    } catch {
      XCTAssert(false, "Parser should not throw any errors if there is a valid 'Content-Length' header.")
    }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\r\nContent-Length: -1\r\n\r\n"))
    do {
      _ = try parser.readHttpRequest()
    } catch let error {
      let error = error as? NanoHTTPParserError
      XCTAssertNotNil(error)
      XCTAssertEqual(error!, NanoHTTPParserError.negativeContentLength)
    }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\nContent-Length: 5\n\n12345"))
    do {
      _ = try parser.readHttpRequest()
    } catch {
      XCTAssert(false, "Parser should not throw any errors if there is a valid 'Content-Length' header.")
    }
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\nContent-Length: 10\r\n\n"))
    do {
      _ = try parser.readHttpRequest()
      XCTAssert(false, "Parser should throw an error if request' body is too short.")
    } catch { }
    
    do { // test payload less than 1 read segmant
      let contentLength = NanoSocket.kBufferLength - 128
      let bodyString = [String](repeating: "A", count: contentLength).joined(separator: "")
      let payload = "GET / HTTP/1.0\nContent-Length: \(contentLength)\n\n".appending(bodyString)
      parser = NanoHTTPParser(socket: TestSocket(payload))
      let request = try parser.readHttpRequest()
      XCTAssert(bodyString.lengthOfBytes(using: .utf8) == contentLength, "Has correct request size")
      let unicodeBytes = bodyString.utf8.map { return $0 }
      XCTAssert(request.body == unicodeBytes, "Request body must be correct")
    } catch { }
    
    do { // test payload equal to 1 read segmant
      let contentLength = NanoSocket.kBufferLength
      let bodyString = [String](repeating: "B", count: contentLength).joined(separator: "")
      let payload = "GET / HTTP/1.0\nContent-Length: \(contentLength)\n\n".appending(bodyString)
      parser = NanoHTTPParser(socket: TestSocket(payload))
      let request = try parser.readHttpRequest()
      XCTAssert(bodyString.lengthOfBytes(using: .utf8) == contentLength, "Has correct request size")
      let unicodeBytes = bodyString.utf8.map { return $0 }
      XCTAssert(request.body == unicodeBytes, "Request body must be correct")
    } catch { }
    
    do { // test very large multi-segment payload
      let contentLength = NanoSocket.kBufferLength * 4
      let bodyString = [String](repeating: "C", count: contentLength).joined(separator: "")
      let payload = "GET / HTTP/1.0\nContent-Length: \(contentLength)\n\n".appending(bodyString)
      parser = NanoHTTPParser(socket: TestSocket(payload))
      let request = try parser.readHttpRequest()
      XCTAssert(bodyString.lengthOfBytes(using: .utf8) == contentLength, "Has correct request size")
      let unicodeBytes = bodyString.utf8.map { return $0 }
      XCTAssert(request.body == unicodeBytes, "Request body must be correct")
    } catch { }
    
    parser = NanoHTTPParser(socket: TestSocket("GET /open?link=https://www.youtube.com/watch?v=D2cUBG4PnOA HTTP/1.0\nContent-Length: 10\n\n1234567890"))
    var resp = try? parser.readHttpRequest()
    
    XCTAssertEqual(resp?.queryParams.filter({ $0.0 == "link"}).first?.1, "https://www.youtube.com/watch?v=D2cUBG4PnOA")
    XCTAssertEqual(resp?.method, "GET", "Parser should extract HTTP method name from the status line.")
    XCTAssertEqual(resp?.path, "/open", "Parser should extract HTTP path value from the status line.")
    XCTAssertEqual(resp?.header("content-length"), "10", "Parser should extract Content-Length header value.")
    
    parser = NanoHTTPParser(socket: TestSocket("POST / HTTP/1.0\nContent-Length: 10\n\n1234567890"))
    resp = try? parser.readHttpRequest()
    XCTAssertEqual(resp?.method, "POST", "Parser should extract HTTP method name from the status line.")
    
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\nHeader1: 1:1:34\nHeader2: 12345\nContent-Length: 0\n\n"))
    resp = try? parser.readHttpRequest()
    XCTAssertEqual(resp?.header("header1"), "1:1:34", "Parser should properly extract header name and value in case the value has ':' character.")
    
    parser = NanoHTTPParser(socket: TestSocket("GET / HTTP/1.0\nHeader1: 1\nHeader2: 2\nContent-Length: 0\n\n"))
    resp = try? parser.readHttpRequest()
    XCTAssertEqual(resp?.header("header1"), "1", "Parser should extract multiple headers from the request.")
    XCTAssertEqual(resp?.header("header2"), "2", "Parser should extract multiple headers from the request.")
    
    parser = NanoHTTPParser(socket: TestSocket("GET /some/path?subscript_query[]=1&subscript_query[]=2 HTTP/1.0\nContent-Length: 10\n\n1234567890"))
    resp = try? parser.readHttpRequest()
    let queryPairs = resp?.queryParams ?? []
    XCTAssertEqual(queryPairs.count, 2)
    XCTAssertEqual(queryPairs.first?.0, "subscript_query[]")
    XCTAssertEqual(queryPairs.first?.1, "1")
    XCTAssertEqual(queryPairs.last?.0, "subscript_query[]")
    XCTAssertEqual(queryPairs.last?.1, "2")
    XCTAssertEqual(resp?.method, "GET", "Parser should extract HTTP method name from the status line.")
    XCTAssertEqual(resp?.path, "/some/path", "Parser should extract HTTP path value from the status line.")
    XCTAssertEqual(resp?.header("content-length"), "10", "Parser should extract Content-Length header value.")
  }
}
