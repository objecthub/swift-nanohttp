//
//  FileServingTests.swift
//  NanoHTTPTests
//
//  2.0 (H10): files are sent with a length (so that the connection can go on), `ETag` and `Last-Modified` (and
//  answered with `304` to conditional requests), and in parts (`Range`, `206`, `416`); a directory is not an
//  empty file.
//

import XCTest
@testable import NanoHTTP

private let bothModes: [NanoHTTPServer.Configuration.Threading] = [.perConnection, .singleThread]

/// The date of the modification of the files: Sun, 06 Nov 1994 08:49:37 GMT.
private let modification = Date(timeIntervalSince1970: 784_111_777)
private let modificationText = "Sun, 06 Nov 1994 08:49:37 GMT"

final class ByteRangeTests: XCTestCase {

  func testRanges() {
    XCTAssertEqual(NanoFileRange.parse("bytes=0-3", size: 10), .bytes(first: 0, last: 3))
    XCTAssertEqual(NanoFileRange.parse("bytes=4-", size: 10), .bytes(first: 4, last: 9))
    XCTAssertEqual(NanoFileRange.parse("bytes=-3", size: 10), .bytes(first: 7, last: 9))
    XCTAssertEqual(NanoFileRange.parse("bytes=2-100", size: 10), .bytes(first: 2, last: 9), "the end is the end of the file")
    XCTAssertEqual(NanoFileRange.parse("bytes=-100", size: 10), .bytes(first: 0, last: 9), "a suffix that is longer than the file")
    XCTAssertEqual(NanoFileRange.parse("bytes=9-9", size: 10), .bytes(first: 9, last: 9))
    XCTAssertEqual(NanoFileRange.parse("bytes=0-0", size: 1), .bytes(first: 0, last: 0))
    XCTAssertEqual(NanoFileRange.parse("  Bytes = 1-2 ", size: 10), .bytes(first: 1, last: 2), "spaces and the case of the unit")
  }

  func testRangesThatDoNotOverlapTheFile() {
    XCTAssertEqual(NanoFileRange.parse("bytes=10-", size: 10), .unsatisfiable)
    XCTAssertEqual(NanoFileRange.parse("bytes=50-60", size: 10), .unsatisfiable)
    XCTAssertEqual(NanoFileRange.parse("bytes=-0", size: 10), .unsatisfiable)
    XCTAssertEqual(NanoFileRange.parse("bytes=0-", size: 0), .unsatisfiable, "nothing of an empty file can be asked for")
    XCTAssertEqual(NanoFileRange.parse("bytes=-5", size: 0), .unsatisfiable)
  }

  func testRangesThatAreIgnored() {
    for header in ["", "bytes", "bytes=", "bytes=-", "bytes=abc", "bytes=1-x", "bytes=5-2", "bytes=0-1,3-4", "items=0-1",
                   "bytes=0-1-2", "bytes==0-1", "bytes=-1-", "bytes=99999999999999999999-", "bytes=0--1", "bytes=+1-2"] {
      XCTAssertEqual(NanoFileRange.parse(header, size: 10), .ignore, "'\(header)'")
    }
  }

  func testEntityTagsAreComparedWeakly() {
    let tag = "\"abc-1\""
    XCTAssertTrue(entityTagMatches("\"abc-1\"", tag))
    XCTAssertTrue(entityTagMatches("W/\"abc-1\"", tag))
    XCTAssertTrue(entityTagMatches("\"other\", \"abc-1\"", tag))
    XCTAssertTrue(entityTagMatches("\"other\",W/\"abc-1\" , \"x\"", tag))
    XCTAssertTrue(entityTagMatches("*", tag))
    XCTAssertFalse(entityTagMatches("\"abc-2\"", tag))
    XCTAssertFalse(entityTagMatches("abc-1", tag), "a tag without quotes is no tag")
    XCTAssertFalse(entityTagMatches("", tag))
    XCTAssertFalse(entityTagMatches("\"abc-1", tag))
  }
}

final class FileServingTests: XCTestCase {
  private var root = ""
  private let ten = "0123456789"

  override func setUpWithError() throws {
    self.root = NSTemporaryDirectory() + "NanoHTTPFiles-" + UUID().uuidString
    let manager = FileManager.default
    try manager.createDirectory(atPath: self.root + "/site/docs", withIntermediateDirectories: true)
    try manager.createDirectory(atPath: self.root + "/site/empty", withIntermediateDirectories: true)
    try manager.createDirectory(atPath: self.root + "/site/sub dir", withIntermediateDirectories: true)
    try self.ten.write(toFile: self.root + "/site/ten.txt", atomically: true, encoding: .utf8)
    try "".write(toFile: self.root + "/site/zero.txt", atomically: true, encoding: .utf8)
    try "<h1>docs</h1>".write(toFile: self.root + "/site/docs/index.html", atomically: true, encoding: .utf8)
    try "<h1>root</h1>".write(toFile: self.root + "/site/index.html", atomically: true, encoding: .utf8)
    try "inside".write(toFile: self.root + "/site/sub dir/é file.txt", atomically: true, encoding: .utf8)
    // a megabyte in which every byte tells where it is
    let big = (0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 / 7 &+ $0) }
    try Data(big).write(to: URL(fileURLWithPath: self.root + "/site/big.bin"))
    for name in ["ten.txt", "zero.txt", "big.bin", "docs/index.html", "index.html"] {
      try manager.setAttributes([.modificationDate: modification], ofItemAtPath: self.root + "/site/" + name)
    }
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: self.root)
  }

  private var bigBytes: [UInt8] {
    return (0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 / 7 &+ $0) }
  }

  private func serve(_ threading: NanoHTTPServer.Configuration.Threading = .perConnection,
                     _ body: (NanoHTTPServer, Int) throws -> Void) throws {
    try withTestServer(configure: { server in
      server.configuration.threading = threading
      server["/site/::path"] = NanoFiles.share(directory: self.root + "/site")
      server["/browse/::path"] = NanoFiles.browse(directory: self.root + "/site")
      server["/single"] = NanoFiles.share(file: self.root + "/site/ten.txt")
    }, body)
  }

  private func get(_ client: RawClient, _ path: String, _ headers: [String] = [], method: String = "GET") -> RawResponse? {
    client.send(RawClient.requestText(method, path, headers: headers))
    return client.readResponse(head: method == "HEAD")
  }

  // MARK: Headers

  func testAFileHasItsLengthAndItsValidators() throws {
    for path in ["/site/ten.txt", "/single", "/browse/ten.txt"] {
      try serve { _, port in
        let response = try RawClient.get(path, port: port)
        XCTAssertEqual(response.status, 200, path)
        XCTAssertEqual(response.bodyString, self.ten, path)
        XCTAssertEqual(response.header("content-length"), "10", path)
        XCTAssertEqual(response.header("content-type"), "text/plain", path)
        XCTAssertEqual(response.header("last-modified"), modificationText, path)
        XCTAssertEqual(response.header("accept-ranges"), "bytes", path)
        let tag = response.header("etag") ?? ""
        XCTAssertTrue(tag.hasPrefix("\"") && tag.hasSuffix("\"") && tag.count > 2, "\(path): \(tag)")
      }
    }
  }

  func testTheEntityTagIsTheSameForTheSameFileAndChangesWithIt() throws {
    try serve { _, port in
      let first = try RawClient.get("/site/ten.txt", port: port).header("etag")
      XCTAssertEqual(try RawClient.get("/site/ten.txt", port: port).header("etag"), first)
      XCTAssertNotEqual(try RawClient.get("/site/big.bin", port: port).header("etag"), first)
      try "a different content".write(toFile: self.root + "/site/ten.txt", atomically: true, encoding: .utf8)
      XCTAssertNotEqual(try RawClient.get("/site/ten.txt", port: port).header("etag"), first)
    }
  }

  func testAFileThatChangedWithoutChangingItsSizeHasANewTag() throws {
    try serve { _, port in
      let first = try RawClient.get("/site/ten.txt", port: port).header("etag")
      try "abcdefghij".write(toFile: self.root + "/site/ten.txt", atomically: true, encoding: .utf8) // also 10 bytes
      XCTAssertNotEqual(try RawClient.get("/site/ten.txt", port: port).header("etag"), first)
    }
  }

  // MARK: Conditional requests

  func testAnUnchangedFileIsAnswerWith304() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        let tag = get(client, "/site/ten.txt")?.header("etag") ?? ""
        let response = get(client, "/site/ten.txt", ["If-None-Match: \(tag)"])
        XCTAssertEqual(response?.status, 304, "\(threading)")
        XCTAssertEqual(response?.body.count, 0)
        XCTAssertEqual(response?.header("etag"), tag, "a 304 repeats the validators")
        XCTAssertEqual(response?.header("last-modified"), modificationText)
        XCTAssertNil(response?.header("content-length"))
        XCTAssertEqual(get(client, "/site/ten.txt")?.bodyString, self.ten, "\(threading): the connection is in step")
      }
    }
  }

  func testTheEntityTagsOfIfNoneMatchAreComparedWeaklyAndAsAList() throws {
    try serve { _, port in
      let tag = try RawClient.get("/site/ten.txt", port: port).header("etag") ?? ""
      let client = try RawClient(port: port)
      for header in ["If-None-Match: W/\(tag)", "If-None-Match: \"other\", \(tag)", "If-None-Match: *"] {
        XCTAssertEqual(get(client, "/site/ten.txt", [header])?.status, 304, header)
      }
      XCTAssertEqual(get(client, "/site/ten.txt", ["If-None-Match: \"other\""])?.status, 200)
    }
  }

  func testAnUnchangedDateIsAnswerWith304() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      XCTAssertEqual(get(client, "/site/ten.txt", ["If-Modified-Since: \(modificationText)"])?.status, 304)
      XCTAssertEqual(get(client, "/site/ten.txt", ["If-Modified-Since: Mon, 07 Nov 1994 08:49:37 GMT"])?.status, 304)
      XCTAssertEqual(get(client, "/site/ten.txt", ["If-Modified-Since: Sat, 05 Nov 1994 08:49:37 GMT"])?.status, 200)
      XCTAssertEqual(get(client, "/site/ten.txt", ["If-Modified-Since: yesterday"])?.status, 200, "a date that is none is ignored")
    }
  }

  func testTheTagDecidesBeforeTheDate() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      let response = get(client, "/site/ten.txt", ["If-None-Match: \"other\"", "If-Modified-Since: \(modificationText)"])
      XCTAssertEqual(response?.status, 200, "the tag does not match: the date is not looked at")
    }
  }

  func testConditionalHeadRequests() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      let tag = get(client, "/site/ten.txt", method: "HEAD")?.header("etag") ?? ""
      XCTAssertEqual(get(client, "/site/ten.txt", method: "HEAD")?.header("content-length"), "10")
      XCTAssertEqual(get(client, "/site/ten.txt", ["If-None-Match: \(tag)"], method: "HEAD")?.status, 304)
      XCTAssertEqual(get(client, "/site/ten.txt")?.bodyString, self.ten, "no bytes of a body were sent for HEAD")
    }
  }

  // MARK: Ranges

  func testARangeIsAnsweredWith206() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        let response = get(client, "/site/ten.txt", ["Range: bytes=2-5"])
        XCTAssertEqual(response?.status, 206, "\(threading)")
        XCTAssertEqual(response?.statusLine, "HTTP/1.1 206 Partial Content")
        XCTAssertEqual(response?.bodyString, "2345")
        XCTAssertEqual(response?.header("content-range"), "bytes 2-5/10")
        XCTAssertEqual(response?.header("content-length"), "4")
        XCTAssertEqual(response?.header("accept-ranges"), "bytes")
        XCTAssertNotNil(response?.header("etag"))
        XCTAssertEqual(get(client, "/site/ten.txt")?.bodyString, self.ten, "\(threading): the connection is in step")
      }
    }
  }

  func testTheFormsOfARange() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      let cases: [(String, String, String)] = [("bytes=4-", "456789", "bytes 4-9/10"),
                                               ("bytes=-3", "789", "bytes 7-9/10"),
                                               ("bytes=2-100", "23456789", "bytes 2-9/10"),
                                               ("bytes=9-9", "9", "bytes 9-9/10"),
                                               ("bytes=0-0", "0", "bytes 0-0/10"),
                                               ("bytes=-100", self.ten, "bytes 0-9/10")]
      for (range, body, contentRange) in cases {
        let response = get(client, "/site/ten.txt", ["Range: \(range)"])
        XCTAssertEqual(response?.status, 206, range)
        XCTAssertEqual(response?.bodyString, body, range)
        XCTAssertEqual(response?.header("content-range"), contentRange, range)
      }
    }
  }

  func testARangeOfALargeFile() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port, timeout: 5)
        let big = self.bigBytes
        let response = get(client, "/site/big.bin", ["Range: bytes=500000-700000"])
        XCTAssertEqual(response?.status, 206, "\(threading)")
        XCTAssertEqual(response?.body, Array(big[500_000...700_000]), "\(threading)")
        XCTAssertEqual(response?.header("content-range"), "bytes 500000-700000/1048576")
        let last = get(client, "/site/big.bin", ["Range: bytes=-1000"])
        XCTAssertEqual(last?.body, Array(big[(big.count - 1000)...]))
        let whole = get(client, "/site/big.bin")
        XCTAssertEqual(whole?.body, big, "\(threading): the whole file, on the same connection")
      }
    }
  }

  func testARangeThatDoesNotOverlapTheFileIs416() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port)
        for range in ["bytes=10-", "bytes=50-60", "bytes=-0"] {
          let response = get(client, "/site/ten.txt", ["Range: \(range)"])
          XCTAssertEqual(response?.status, 416, "\(threading): \(range)")
          XCTAssertEqual(response?.header("content-range"), "bytes */10", range)
          XCTAssertEqual(response?.body.count, 0)
        }
        XCTAssertEqual(get(client, "/site/zero.txt", ["Range: bytes=0-"])?.status, 416)
        XCTAssertEqual(get(client, "/site/ten.txt")?.bodyString, self.ten, "\(threading): the connection is in step")
      }
    }
  }

  func testARangeThatIsNotUnderstoodGivesTheWholeFile() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      for range in ["bytes=0-1,3-4", "bytes=abc", "bytes=5-2", "items=0-1"] {
        let response = get(client, "/site/ten.txt", ["Range: \(range)"])
        XCTAssertEqual(response?.status, 200, range)
        XCTAssertEqual(response?.bodyString, self.ten, range)
        XCTAssertNil(response?.header("content-range"), range)
      }
    }
  }

  func testIfRangeDecidesWhetherTheRangeIsHonored() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      let tag = get(client, "/site/ten.txt")?.header("etag") ?? ""
      XCTAssertEqual(get(client, "/site/ten.txt", ["Range: bytes=0-1", "If-Range: \(tag)"])?.status, 206)
      XCTAssertEqual(get(client, "/site/ten.txt", ["Range: bytes=0-1", "If-Range: \"other\""])?.status, 200)
      XCTAssertEqual(get(client, "/site/ten.txt", ["Range: bytes=0-1", "If-Range: W/\(tag)"])?.status, 200,
                     "a weak tag is not good enough for a range")
      XCTAssertEqual(get(client, "/site/ten.txt", ["Range: bytes=0-1", "If-Range: \(modificationText)"])?.status, 206)
      let changed = get(client, "/site/ten.txt", ["Range: bytes=0-1", "If-Range: Sat, 05 Nov 1994 08:49:37 GMT"])
      XCTAssertEqual(changed?.status, 200, "the file is not the one that the client has")
      XCTAssertEqual(changed?.bodyString, self.ten)
    }
  }

  func testARangeOfAHeadRequest() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      let response = get(client, "/site/ten.txt", ["Range: bytes=2-5"], method: "HEAD")
      XCTAssertEqual(response?.status, 206)
      XCTAssertEqual(response?.header("content-length"), "4")
      XCTAssertEqual(get(client, "/site/ten.txt")?.bodyString, self.ten)
    }
  }

  func testAnythingGoesOnTheSameConnection() throws {
    for threading in bothModes {
      try serve(threading) { _, port in
        let client = try RawClient(port: port, timeout: 5)
        let tag = get(client, "/site/ten.txt")?.header("etag") ?? ""
        XCTAssertEqual(get(client, "/site/ten.txt", ["If-None-Match: \(tag)"])?.status, 304)
        XCTAssertEqual(get(client, "/site/ten.txt", ["Range: bytes=1-2"])?.bodyString, "12")
        XCTAssertEqual(get(client, "/site/ten.txt", ["Range: bytes=99-"])?.status, 416)
        XCTAssertEqual(get(client, "/site/missing.txt")?.status, 404)
        XCTAssertEqual(get(client, "/site/big.bin")?.body.count, 1024 * 1024)
        XCTAssertEqual(get(client, "/site/ten.txt", method: "HEAD")?.status, 200)
        XCTAssertEqual(get(client, "/site/ten.txt")?.bodyString, self.ten, "\(threading)")
      }
    }
  }

  // MARK: Directories

  func testADirectoryWithoutASlashIsRedirected() throws {
    try serve { _, port in
      let response = try RawClient.get("/site/docs", port: port)
      XCTAssertEqual(response.status, 301)
      XCTAssertEqual(response.header("location"), "/site/docs/")
      let withQuery = try RawClient.get("/site/docs?x=1&y=a%20b", port: port)
      XCTAssertEqual(withQuery.header("location"), "/site/docs/?x=1&y=a%20b")
      let encoded = try RawClient.get("/site/sub%20dir", port: port)
      XCTAssertEqual(encoded.header("location"), "/site/sub%20dir/", "the location stays encoded")
    }
  }

  func testADirectoryServesItsIndexFile() throws {
    try serve { _, port in
      let docs = try RawClient.get("/site/docs/", port: port)
      XCTAssertEqual(docs.status, 200)
      XCTAssertEqual(docs.bodyString, "<h1>docs</h1>")
      XCTAssertEqual(docs.header("content-type"), "text/html")
      let root = try RawClient.get("/site/", port: port)
      XCTAssertEqual(root.bodyString, "<h1>root</h1>")
      XCTAssertEqual(try RawClient.get("/site", port: port).status, 301, "the root of the route is a directory too")
    }
  }

  func testADirectoryWithoutAnIndexFileIsNotAnEmptyFile() throws {
    try serve { _, port in
      XCTAssertEqual(try RawClient.get("/site/empty/", port: port).status, 404)
      XCTAssertEqual(try RawClient.get("/site/empty", port: port).status, 301)
      XCTAssertEqual(try RawClient.get("/site/sub%20dir/", port: port).status, 404)
    }
  }

  func testFilesWithSpecialNamesAreServed() throws {
    try serve { _, port in
      XCTAssertEqual(try RawClient.get("/site/sub%20dir/%C3%A9%20file.txt", port: port).bodyString, "inside")
    }
  }

  func testTheListingOfBrowseHasNoDotEntries() throws {
    try serve { _, port in
      let listing = try RawClient.get("/browse/", port: port).bodyString
      XCTAssertTrue(listing.contains(">ten.txt<"), listing)
      XCTAssertFalse(listing.contains(">.<"), listing)
      XCTAssertFalse(listing.contains(">..<"), listing)
    }
  }

  func testBrowseSendsFilesWithRangesAndTags() throws {
    try serve { _, port in
      let client = try RawClient(port: port)
      XCTAssertEqual(get(client, "/browse/ten.txt", ["Range: bytes=1-3"])?.bodyString, "123")
      let tag = get(client, "/browse/ten.txt")?.header("etag") ?? ""
      XCTAssertEqual(get(client, "/browse/ten.txt", ["If-None-Match: \(tag)"])?.status, 304)
    }
  }

  func testTheMissingFileStaysA404() throws {
    try serve { _, port in
      XCTAssertEqual(try RawClient.get("/site/none.txt", port: port).status, 404)
      XCTAssertEqual(try RawClient.get("/browse/none.txt", port: port).status, 404)
    }
  }
}

// MARK: - NanoFile and NanoFiles

final class NanoFileTests: XCTestCase {

  private var directory = ""

  override func setUpWithError() throws {
    self.directory = NSTemporaryDirectory() + "NanoFileTests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: self.directory)
  }

  private func readAll(_ file: NanoFile) throws -> String {
    var block = [UInt8](repeating: 0, count: 64)
    let count = try file.read(&block)
    return String(decoding: block[0..<count], as: UTF8.self)
  }

  func testReadsAnExistingFile() throws {
    let path = self.directory + "/a.txt"
    try "hello".write(toFile: path, atomically: true, encoding: .utf8)
    let file = try NanoFile(path: path)
    XCTAssertEqual(try self.readAll(file), "hello")
    XCTAssertTrue(file.seek(1))
    XCTAssertEqual(try self.readAll(file), "ello")
  }

  func testAMissingFileThrowsTheSystemError() {
    XCTAssertThrowsError(try NanoFile(path: self.directory + "/none.txt")) { error in
      guard case NanoFileError.error(let code) = error else {
        return XCTFail("\(error)")
      }
      XCTAssertEqual(code, ENOENT)
    }
  }

  func testCreateEmptiesAnExistingFileAndUpdateKeepsIt() throws {
    let path = self.directory + "/b.txt"
    try "old content".write(toFile: path, atomically: true, encoding: .utf8)
    let updated = try NanoFile(path: path, mode: .update)
    XCTAssertEqual(try self.readAll(updated), "old content", "update does not empty the file")
    updated.close()
    let created = try NanoFile(path: path, mode: .create)
    try created.write(Array("new".utf8))
    created.close()
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "new")
    let fresh = try NanoFile(path: self.directory + "/c.txt", mode: .create)
    fresh.close()
    XCTAssertTrue(FileManager.default.fileExists(atPath: self.directory + "/c.txt"), "create makes a missing file")
  }

  func testFilesThatAreOpenedByPathAreWrittenToTheConnectionByTheBodyWriter() throws {
    let path = self.directory + "/d.txt"
    try "0123456789".write(toFile: path, atomically: true, encoding: .utf8)
    let writer = CapturingWriter()
    try writer.write(try NanoFile(path: path))
    XCTAssertEqual(writer.text, "0123456789")
    let part = CapturingWriter()
    try part.write(try NanoFile(path: path), offset: 3, length: 4)
    XCTAssertEqual(part.text, "3456")
  }
}

final class NanoFilesTests: XCTestCase {

  func testMimeTypeOfAPath() {
    XCTAssertEqual(NanoFiles.mimeType(forPath: "/var/www/index.html"), "text/html")
    XCTAssertEqual(NanoFiles.mimeType(forPath: "no-extension"), "application/octet-stream")
  }

  func testDirectoryEntriesDoNotHaveDotAndDotDot() throws {
    let fixture = try FileFixture()
    defer { fixture.remove() }
    let entries = NanoFiles.entries(ofDirectory: fixture.publicDir)
    XCTAssertTrue(entries.contains("hello.txt"))
    XCTAssertTrue(entries.contains("sub"))
    XCTAssertFalse(entries.contains("."))
    XCTAssertFalse(entries.contains(".."))
    XCTAssertEqual(NanoFiles.entries(ofDirectory: fixture.root + "/missing"), [])
  }
}
