//
//  StringExtensionsTests.swift
//  NanoHTTPTests
//
//  Created by Matthias Zenger on 22/07/2024.
//  Based on `SwifterTestsStringExtensions` of framework `Swifter` by Damian Kołakowski.
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

class SwifterTestsStringExtensions: XCTestCase {
  
  func testSHA1() {
    XCTAssertEqual("".sha1(), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    XCTAssertEqual("test".sha1(), "a94a8fe5ccb19ba61c4c0873d391e987982fbbd3")
    
      // Values copied from OpenSSL:
      // https://github.com/openssl/openssl/blob/master/test/sha1test.c
    
    XCTAssertEqual("abc".sha1(), "a9993e364706816aba3e25717850c26c9cd0d89d")
    XCTAssertEqual("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".sha1(),
                   "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    
    XCTAssertEqual(
      ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" +
       "a9993e364706816aba3e25717850c26c9cd0d89d" +
       "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" +
       "a9993e364706816aba3e25717850c26c9cd0d89d" +
       "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" +
       "a9993e364706816aba3e25717850c26c9cd0d89d" +
       "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" +
       "a9993e364706816aba3e25717850c26c9cd0d89d" +
       "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" +
       "a9993e364706816aba3e25717850c26c9cd0d89d" +
       "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" +
       "a9993e364706816aba3e25717850c26c9cd0d89d" +
       "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").sha1(),
      "a377b0c42d685fdc396e29a9eda7101d900947ca")
  }
  
  func testBASE64() {
    XCTAssertEqual(String.toBase64([UInt8]("".utf8)), "")
    // Values copied from OpenSSL:
    // https://github.com/openssl/openssl/blob/995197ab84901df1cdf83509c4ce3511ea7f5ec0/test/evptests.txt
    XCTAssertEqual(String.toBase64([UInt8]("h".utf8)), "aA==")
    XCTAssertEqual(String.toBase64([UInt8]("hello".utf8)), "aGVsbG8=")
    XCTAssertEqual(String.toBase64([UInt8]("hello world!".utf8)), "aGVsbG8gd29ybGQh")
    XCTAssertEqual(String.toBase64([UInt8]("OpenSSLOpenSSL\n".utf8)), "T3BlblNTTE9wZW5TU0wK")
    XCTAssertEqual(String.toBase64([UInt8]("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx".utf8)),
                   "eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eA==")
    XCTAssertEqual(String.toBase64([UInt8]("h".utf8)), "aA==")
  }
  
  func testMiscUnquote() {
    XCTAssertEqual("".unquote(), "")
    XCTAssertEqual("\"".unquote(), "\"")
    XCTAssertEqual("\"\"".unquote(), "")
    
    XCTAssertEqual("1234".unquote(), "1234")
    XCTAssertEqual("1234\"".unquote(), "1234\"")
    XCTAssertEqual("\"1234".unquote(), "\"1234")
    XCTAssertEqual("\"1234\"".unquote(), "1234")
    XCTAssertEqual("\"1234\"".unquote(), "1234")
    
    XCTAssertEqual("\"\"\"".unquote(), "\"")
    XCTAssertEqual("\"\" \"\"".unquote(), "\" \"")
  }
  
  func testMiscTrim() {
    XCTAssertEqual("".trimmingCharacters(in: .whitespacesAndNewlines), "")
    XCTAssertEqual(" ".trimmingCharacters(in: .whitespacesAndNewlines), "")
    XCTAssertEqual("      ".trimmingCharacters(in: .whitespacesAndNewlines), "")
    XCTAssertEqual("1 test     ".trimmingCharacters(in: .whitespacesAndNewlines), "1 test")
    XCTAssertEqual("      test          ".trimmingCharacters(in: .whitespacesAndNewlines), "test")
    XCTAssertEqual("   \t\n\rtest          ".trimmingCharacters(in: .whitespacesAndNewlines), "test")
    XCTAssertEqual("   \t\n\rtest  n   \n\t asd    ".trimmingCharacters(in: .whitespacesAndNewlines), "test  n   \n\t asd")
  }
  
  func testMiscReplace() {
    XCTAssertEqual("".replacingOccurrences(of: "+", with: "-"), "")
    XCTAssertEqual("test".replacingOccurrences(of: "+", with: "-"), "test")
    XCTAssertEqual("+++".replacingOccurrences(of: "+", with: "-"), "---")
    XCTAssertEqual("t&e&s&t12%3%".replacingOccurrences(of: "&", with: "+").replacingOccurrences(of: "%", with: "+"), "t+e+s+t12+3+")
    XCTAssertEqual("test 1234 #$%^&*( test   ".replacingOccurrences(of: " ", with: "_"), "test_1234_#$%^&*(_test___")
  }
  
  func testMiscRemovePercentEncoding() {
    XCTAssertEqual("".removingPercentEncoding!, "")
    XCTAssertEqual("%20".removingPercentEncoding!, " ")
    XCTAssertEqual("%22".removingPercentEncoding!, "\"")
    XCTAssertEqual("%25".removingPercentEncoding!, "%")
    XCTAssertEqual("%2d".removingPercentEncoding!, "-")
    XCTAssertEqual("%2e".removingPercentEncoding!, ".")
    XCTAssertEqual("%3C".removingPercentEncoding!, "<")
    XCTAssertEqual("%3E".removingPercentEncoding!, ">")
    XCTAssertEqual("%5C".removingPercentEncoding!, "\\")
    XCTAssertEqual("%5E".removingPercentEncoding!, "^")
    XCTAssertEqual("%5F".removingPercentEncoding!, "_")
    XCTAssertEqual("%60".removingPercentEncoding!, "`")
    XCTAssertEqual("%7B".removingPercentEncoding!, "{")
    XCTAssertEqual("%7C".removingPercentEncoding!, "|")
    XCTAssertEqual("%7D".removingPercentEncoding!, "}")
    XCTAssertEqual("%7E".removingPercentEncoding!, "~")
    XCTAssertEqual("%7e".removingPercentEncoding!, "~")
  }
}
