//
//  NanoFiles.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `Files` of framework `Swifter` by Damian Kołakowski.
//
//  Copyright © 2014-2016 Damian Kołakowski. All rights reserved.
//  Copyright © 2024 Matthias Zenger. All rights reserved.
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
import UniformTypeIdentifiers

/// Maps the percent-decoded, client-supplied path `relativePath` to a file system path
/// below `directory`. Returns `nil` if the request must be refused because the path could
/// lead out of `directory`:
///
/// - a path segment is `..` (segments that are empty or `.` are ignored, so an
///   absolute-looking path such as `/etc/passwd` just names `<directory>/etc/passwd`),
/// - the path contains a NUL character (it would end the C string early: `a.txt\0.png` opens
///   `a.txt`), or
/// - the path exists, but, after following symbolic links, lies outside of `directory`.
///   This last check is skipped if `followSymlinks` is `true`; the other two are always
///   applied.
///
/// A path that does not exist is returned as is; opening it fails and the caller answers 404.
/// There remains a small window between this check and opening the file in which someone with
/// write access to the shared directory could replace a path by a link.
private func locate(_ relativePath: String, in directory: String, followSymlinks: Bool) -> String? {
  guard !relativePath.contains("\0") else {
    return nil
  }
  var components = [String]()
  for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
    if component == ".." {
      return nil
    } else if component != "." {
      components.append(String(component))
    }
  }
  let candidate = components.isEmpty
                    ? directory
                    : directory + "/" + components.joined(separator: "/")
  guard !followSymlinks, let root = realPath(directory), let resolved = realPath(candidate) else {
    return candidate
  }
  let prefix = root.hasSuffix("/") ? root : root + "/"
  return resolved == root || resolved.hasPrefix(prefix) ? candidate : nil
}

/// The canonical absolute path of `path`: symbolic links are resolved, `.` and `..` removed.
/// `nil` if the path does not exist.
private func realPath(_ path: String) -> String? {
  guard let resolved = realpath(path, nil) else {
    return nil
  }
  defer {
    free(resolved)
  }
  return String(cString: resolved)
}

/// What a path in the file system is.
private enum FileKind {
  case missing
  case directory
  case file
}

/// What `path` is, after symbolic links have been followed.
private func kind(of path: String) -> FileKind {
  var info = stat()
  guard stat(path, &info) == 0 else {
    return .missing
  }
  return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .file
}

/// The part of a file that a `Range` header asks for.
enum NanoFileRange: Equatable {
  
  /// There is no usable range: the whole file is sent.
  case ignore
  
  /// The range does not overlap the file (`416`).
  case unsatisfiable
  
  /// The bytes from `first` to `last`, both included.
  case bytes(first: Int64, last: Int64)
  
  /// Reads the value of a `Range` header (RFC 9110 14.1.2) for a file of `size` bytes.
  /// Only a single range of bytes is served: a header with several ranges, with another
  /// unit or with a syntax that is not understood is ignored, which the protocol allows
  /// (the whole file is sent).
  static func parse(_ header: String, size: Int64) -> NanoFileRange {
    let parts = header.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "bytes" else {
      return .ignore
    }
    let specification = parts[1].trimmingCharacters(in: .whitespaces)
    guard !specification.contains(",") else {
      return .ignore
    }
    let bounds = specification.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                              .map { $0.trimmingCharacters(in: .whitespaces) }
    guard bounds.count == 2, bounds.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
      return .ignore
    }
    if bounds[0].isEmpty { // the last bytes: -500
      guard !bounds[1].isEmpty, let length = Int64(bounds[1]) else {
        return .ignore
      }
      guard length > 0, size > 0 else {
        return .unsatisfiable
      }
      return .bytes(first: max(0, size - length), last: size - 1)
    }
    guard let first = Int64(bounds[0]) else {
      return .ignore
    }
    var last = size - 1
    if !bounds[1].isEmpty {
      guard let requested = Int64(bounds[1]), requested >= first else {
        return .ignore
      }
      last = min(requested, last)
    }
    return first >= size ? .unsatisfiable : .bytes(first: first, last: last)
  }
}

/// Whether the value of an `If-None-Match` header (a list of entity tags, or `*`)
/// contains `tag`. The tags are compared weakly: `W/"a"` and `"a"` are the same (RFC 9110
/// 8.8.3.2).
func entityTagMatches(_ header: String, _ tag: String) -> Bool {
  let wanted = tag.hasPrefix("W/") ? String(tag.dropFirst(2)) : tag
  for item in header.split(separator: ",") {
    var candidate = item.trimmingCharacters(in: .whitespaces)
    if candidate == "*" {
      return true
    }
    if candidate.hasPrefix("W/") {
      candidate = String(candidate.dropFirst(2))
    }
    if candidate.count >= 2 && candidate.hasPrefix("\"") && candidate.hasSuffix("\"") && candidate == wanted {
      return true
    }
  }
  return false
}

/// Whether the value of an `If-Range` header says that the client has the file as it is
/// now: it is its (strong) entity tag, or the date of its modification, exactly.
private func ifRangeMatches(_ header: String, tag: String, modification: Int64) -> Bool {
  let value = header.trimmingCharacters(in: .whitespaces)
  if value.hasPrefix("\"") {
    return value == tag
  }
  if value.hasPrefix("W/") {
    return false // weak tags are not good enough to put the parts of a file together
  }
  guard let date = NanoHTTPDate.date(from: value) else {
    return false
  }
  return Int64(date.timeIntervalSince1970) == modification
}

/// The response that sends `file`: its MIME type (from `name`, if it has an extension
/// that is known), its size as `Content-Length`, `ETag`, `Last-Modified`, and the
/// content, which is closed when it has been sent or, if the response is dropped (the
/// request was `HEAD`, or the client went away), when the response is released.
///
/// Conditional requests are answered with `304` (`If-None-Match`, else `If-Modified-Since`),
/// and a `Range` header that asks for one part of the file with `206` (`416` if the file
/// has nothing there); `If-Range` can turn a range into the whole file. A file whose
/// length changes while it is sent ends the connection.
private func response(for file: NanoFile,
                      named name: String,
                      request: NanoHTTPRequest) -> NanoHTTPResponse {
  guard let info = file.status(), (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
    return .notFound("Unable to open file")
  }
  let size = Int64(info.st_size)
  let modification = Int64(info.st_mtimespec.tv_sec)
  let tag = "\"" + [String(UInt64(info.st_ino), radix: 16),
                     String(UInt64(bitPattern: Int64(info.st_mtimespec.tv_sec)), radix: 16) + "." +
                       String(UInt64(info.st_mtimespec.tv_nsec), radix: 16),
                     String(size, radix: 16)].joined(separator: "-") + "\""
  var headers = ["ETag": tag,
                 "Last-Modified": NanoHTTPDate.string(for: Date(timeIntervalSince1970: Double(modification))),
                 "Accept-Ranges": "bytes"]
  // A conditional request: the tag, or if there is none the date.
  if let match = request.header("if-none-match") {
    if entityTagMatches(match, tag) {
      return NanoHTTPResponse(statusCode: 304, headers: headers)
    }
  } else if let since = request.header("if-modified-since"),
            let date = NanoHTTPDate.date(from: since),
            modification <= Int64(date.timeIntervalSince1970) {
    return NanoHTTPResponse(statusCode: 304, headers: headers)
  }
  // A range, unless `If-Range` says that the client has another version.
  var range = NanoFileRange.ignore
  if let wanted = request.header("range") {
    range = NanoFileRange.parse(wanted, size: size)
    if range != .ignore, let condition = request.header("if-range"),
       !ifRangeMatches(condition, tag: tag, modification: modification) {
      range = .ignore
    }
  }
  var status = 200
  var first: Int64 = 0
  var length = size
  switch range {
    case .ignore:
      break
    case .unsatisfiable:
      return NanoHTTPResponse(statusCode: 416, headers: ["Content-Range": "bytes */\(size)"])
    case .bytes(let start, let end):
      status = 206
      first = start
      length = end - start + 1
      headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
  }
  headers["Content-Length"] = String(length)
  return .custom(status, headers: headers, contentType: NanoFiles.mimeType(forPath: name)) { writer in
    if length > 0 {
      try writer.write(file, offset: first, length: length)
    }
    file.close()
  }
}

/// The functions that serve files: single files, directories and listings of directories.
///
/// ```swift
/// let server = NanoHTTPServer()
/// server["/logo"] = NanoFiles.share(file: "/var/www/logo.png")
/// server["/static/::path"] = NanoFiles.share(directory: "/var/www")
/// ```
public enum NanoFiles {
  
  /// The MIME type for the file extension of a path or file name (`"a.png"` gives
  /// `image/png`); `application/octet-stream` if the extension is not known.
  public static func mimeType(forPath path: String) -> String {
    if let mimeType = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType {
      return mimeType
    } else {
      return "application/octet-stream"
    }
  }
  
  /// The names of the entries of the directory at `path`, without `.` and `..`, in no
  /// particular order. Empty if the directory cannot be read.
  static func entries(ofDirectory path: String) -> [String] {
    guard let dir = path.withCString({ opendir($0) }) else {
      return []
    }
    defer {
      closedir(dir)
    }
    var results = [String]()
    while let ent = readdir(dir) {
      var name = ent.pointee.d_name
      let fileName = withUnsafePointer(to: &name) { (ptr) -> String? in
        #if os(Linux)
        return String(validatingUTF8:
                        ptr.withMemoryRebound(to: CChar.self,
                                              capacity: Int(ent.pointee.d_reclen)) { ptrc in
                          return [CChar](UnsafeBufferPointer(start: ptrc, count: 256))
                        })
        #else
        var buffer = ptr.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_reclen)) { ptrc in
          return [CChar](UnsafeBufferPointer(start: ptrc, count: Int(ent.pointee.d_namlen)))
        }
        buffer.append(0)
        return String(validatingUTF8: buffer)
        #endif
      }
      if let fileName = fileName, fileName != ".", fileName != ".." {
        results.append(fileName)
      }
    }
    return results
  }
  
  /// Returns a handler that serves one file.
  ///
  /// The response carries the MIME type derived from the extension of `path`, the size of
  /// the file as `Content-Length`, and `ETag` and `Last-Modified`, which clients use to
  /// ask whether their copy is still good (`304 Not Modified`). The file can be requested
  /// in parts (`Range`). If the file cannot be opened, the response is `404 Not Found`.
  ///
  /// - Parameter path: The file to serve.
  public static func share(file path: String) -> NanoHTTPRequestHandler {
    return { request in
      if kind(of: path) == .file, let file = try? NanoFile(path: path) {
        return response(for: file, named: path, request: request)
      }
      return .notFound()
    }
  }

  /// Returns a handler that serves the files of a directory.
  ///
  /// Register the handler for a route that ends in a path variable, for example
  /// `server["/public/::path"] = NanoFiles.share(directory: "/var/www")`. The value of
  /// that variable selects the file below `path`. A request for a directory is redirected
  /// to the same address with a `/` at the end (so that links in the files of the
  /// directory work), and then answers with the first existing file of `defaults` in it,
  /// or `404 Not Found`. Files are sent as by ``NanoFiles/share(file:)``: with `ETag` and
  /// `Last-Modified`, and in parts.
  ///
  /// Requests containing `..` segments or NUL characters are always answered with
  /// `403 Forbidden`. Symbolic links that stay inside the directory are always followed.
  /// By default, requests for paths that lead out of the directory through a symbolic
  /// link are refused with `403 Forbidden` as well; set `followSymlinks` to serve them.
  /// Missing files give `404 Not Found`.
  ///
  /// - Parameters:
  ///   - path: The directory to serve.
  ///   - defaults: File names that are served for a directory.
  ///   - followSymlinks: If `true`, symbolic links are followed even if their target lies
  ///       outside of `path`. Only enable this if everyone who can create files in `path`
  ///       is trusted.
  public static func share(directory path: String,
                           defaults: [String] = ["index.html", "default.html"],
                           followSymlinks: Bool = false) -> NanoHTTPRequestHandler {
    return { request in
      guard let (_, relativePath) = request.params.first else { // decoded by the router, once
        return NanoHTTPResponse.internalServerError("Internal Server Error")
      }
      guard let filePath = locate(relativePath, in: path, followSymlinks: followSymlinks) else {
        return .forbidden("Forbidden")
      }
      switch kind(of: filePath) {
        case .missing:
          return .notFound("Unknown file/directory")
        case .directory:
          guard request.rawPath.hasSuffix("/") else {
            return .movedPermanently(request.rawPath + "/" + (request.rawQuery.map { "?" + $0 } ?? ""))
          }
          for name in defaults {
            if let defaultPath = locate(relativePath + "/" + name, in: path, followSymlinks: followSymlinks),
               kind(of: defaultPath) == .file,
               let file = try? NanoFile(path: defaultPath) {
              return response(for: file, named: name, request: request)
            }
          }
          return .notFound("Unknown file/directory")
        case .file:
          if let file = try? NanoFile(path: filePath) {
            return response(for: file, named: relativePath, request: request)
          }
          return .notFound("Unknown file/directory")
      }
    }
  }

  /// Returns a handler that lists the directories and serves the files below a directory.
  ///
  /// Register the handler for a route that ends in a path variable, for example
  /// `server["/files/::path"] = NanoFiles.browse(directory: "/var/www")`. The value of
  /// that variable selects the file or directory below `dir`. Directories are answered
  /// with an HTML list of links; files are sent as by ``NanoFiles/share(file:)``.
  ///
  /// Like `NanoFiles.share(directory:defaults:followSymlinks:)`, the handler does not
  /// reach beyond `dir`: requests containing `..` segments or NUL characters are always
  /// answered with `403 Forbidden`, and so are paths that lead out of the directory
  /// through a symbolic link, unless `followSymlinks` is set. Symbolic links that stay
  /// inside the directory are always followed.
  ///
  /// - Parameters:
  ///   - dir: The directory to browse.
  ///   - followSymlinks: If `true`, symbolic links are followed even if their target lies
  ///       outside of `dir`. Only enable this if everyone who can create files in `dir`
  ///       is trusted.
  public static func browse(directory dir: String, followSymlinks: Bool = false) -> NanoHTTPRequestHandler {
    return { request in
      guard let (_, path) = request.params.first else { // decoded by the router, once
        return NanoHTTPResponse.internalServerError("Internal Server Error")
      }
      var base = request.rawPath // the links are percent-encoded: so is what they start with
      if base.last != "/" {
        base.append("/")
      }
      guard let filePath = locate(path, in: dir, followSymlinks: followSymlinks) else {
        return .forbidden("Forbidden")
      }
      switch kind(of: filePath) {
        case .missing:
          return .notFound("Unknown file/directory")
        case .directory:
          var files = NanoFiles.entries(ofDirectory: filePath)
          files.sort(by: { $0.lowercased() < $1.lowercased() })
          var res = ""
          for f in files {
            let link = base + (f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f)
            res += "<li><a href=\"\(link.htmlEscaped)\">\(f.htmlEscaped)</a></li>"
          }
          return .ok(.htmlBody("<ul style=\"list-style: none;\">\(res)</ul>"))
        case .file:
          guard let file = try? NanoFile(path: filePath) else {
            return .notFound("Unable to open file")
          }
          return response(for: file, named: path, request: request)
      }
    }
  }
}
