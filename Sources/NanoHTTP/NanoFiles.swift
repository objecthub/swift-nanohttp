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

/// Maps the percent-decoded, client-supplied path `relativePath` to a file system path below
/// `directory`. Returns `nil` if the request must be refused because the path could lead out of
/// `directory`:
///
/// - a path segment is `..` (segments that are empty or `.` are ignored, so an absolute-looking
///   path such as `/etc/passwd` just names `<directory>/etc/passwd`),
/// - the path contains a NUL character (it would end the C string early: `a.txt\0.png` opens
///   `a.txt`), or
/// - the path exists, but, after following symbolic links, lies outside of `directory`. This last
///   check is skipped if `followSymlinks` is `true`; the other two are always applied.
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
                    : directory + String.pathSeparator + components.joined(separator: String.pathSeparator)
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

extension String.File {
  /// The size in bytes of the file that is open, as `fstat` reports it. Unlike
  /// `FileManager.attributesOfItem(atPath:)`, which describes a symbolic link itself (the length
  /// of its target path), this is the size of the file the link leads to.
  fileprivate var size: UInt64? {
    var info = stat()
    guard fstat(fileno(self.pointer), &info) == 0, info.st_size >= 0 else {
      return nil
    }
    return UInt64(info.st_size)
  }
}

/// The response that sends `file`: its MIME type (from `name`, if it has an extension that is known),
/// its size as `Content-Length`, and the content. The file is closed when it has been sent or, if
/// the response is dropped, when the response is released.
private func response(for file: String.File, named name: String) -> NanoHTTPResponse {
  var headers: [String: String] = [:]
  if let size = file.size {
    headers["Content-Length"] = String(size)
  }
  return .custom(200, headers: headers, contentType: name.mimeType()) { writer in
    try? writer.write(file)
    file.close()
  }
}

/// Returns a handler that serves one file.
///
/// The response carries the MIME type derived from the extension of `path` and the size of the
/// file as `Content-Length`. If the file cannot be opened, the response is `404 Not Found`.
///
/// - Parameter path: The file to serve.
public func share(file path: String) -> NanoHTTPRequestHandler {
  return { _ in
    if let file = try? path.openForReading() {
      return response(for: file, named: path)
    }
    return .notFound()
  }
}

/// Returns a handler that serves the files of a directory.
///
/// Register the handler for a route that ends in a path variable, for example
/// `server["/public/::path"] = share(directory: "/var/www")`. The value of that variable selects
/// the file below `path`. A request for the root of the route (empty value) serves the first
/// existing file of `defaults`.
///
/// Requests containing `..` segments or NUL characters are always answered with
/// `403 Forbidden`. Symbolic links that stay inside the directory are always followed. By default,
/// requests for paths that lead out of the directory through a symbolic link are refused with
/// `403 Forbidden` as well; set `followSymlinks` to serve them. Missing files give
/// `404 Not Found`.
///
/// - Parameters:
///   - path: The directory to serve.
///   - defaults: File names that are served for the root of the route.
///   - followSymlinks: If `true`, symbolic links are followed even if their target lies outside
///       of `path`. Only enable this if everyone who can create files in `path` is trusted.
public func share(directory path: String,
                  defaults: [String] = ["index.html", "default.html"],
                  followSymlinks: Bool = false) -> NanoHTTPRequestHandler {
  return { request in
    guard let (_, value) = request.params.first,
          let fileRelativePath = value.removingPercentEncoding else {
      return NanoHTTPResponse.internalServerError("Internal Server Error")
    }
    guard let filePath = locate(fileRelativePath, in: path, followSymlinks: followSymlinks) else {
      return .forbidden("Forbidden")
    }
    if fileRelativePath.isEmpty {
      for d in defaults {
        if let defaultPath = locate(d, in: path, followSymlinks: followSymlinks),
           let file = try? defaultPath.openForReading() {
          return response(for: file, named: d)
        }
      }
    }
    if let file = try? filePath.openForReading() {
      return response(for: file, named: fileRelativePath)
    }
    return .notFound("Unknown file/directory")
  }
}

/// Returns a handler that lists the directories and serves the files below a directory.
///
/// Register the handler for a route that ends in a path variable, for example
/// `server["/files/::path"] = browse(directory: "/var/www")`. The value of that variable selects
/// the file or directory below `dir`. Directories are answered with an HTML list of links.
///
/// Like `share(directory:defaults:followSymlinks:)`, the handler does not reach beyond `dir`:
/// requests containing `..` segments or NUL characters are always answered with `403 Forbidden`,
/// and so are paths that lead out of the directory through a symbolic link, unless
/// `followSymlinks` is set. Symbolic links that stay inside the directory are always followed.
///
/// - Parameters:
///   - dir: The directory to browse.
///   - followSymlinks: If `true`, symbolic links are followed even if their target lies outside
///       of `dir`. Only enable this if everyone who can create files in `dir` is trusted.
public func browse(directory dir: String, followSymlinks: Bool = false) -> NanoHTTPRequestHandler {
  return { request in
    guard let (_, value) = request.params.first,
          let path = value.removingPercentEncoding else {
      return NanoHTTPResponse.internalServerError("Internal Server Error")
    }
    var base = request.path
    if base.last != "/" {
      base.append("/")
    }
    guard let filePath = locate(path, in: dir, followSymlinks: followSymlinks) else {
      return .forbidden("Forbidden")
    }
    do {
      guard try filePath.exists() else {
        return .notFound("Unknown file/directory")
      }
      if try filePath.directory() {
        var files = try filePath.files()
        files.sort(by: {$0.lowercased() < $1.lowercased()})
        var res = ""
        for f in files {
          let path = base + (f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f)
          res += "<li><a href=\"\(path.htmlEscaped)\">\(f.htmlEscaped)</a></li>"
        }
        return .ok(.htmlBody("<ul style=\"list-style: none;\">\(res)</ul>"))
      } else {
        guard let file = try? filePath.openForReading() else {
          return .notFound("Unable to open file")
        }
        return response(for: file, named: path)
      }
    } catch {
      return NanoHTTPResponse.internalServerError("Internal Server Error")
    }
  }
}
