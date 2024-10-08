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

public func share(file path: String) -> NanoHTTPRequestHandler {
  return { _ in
    if let file = try? path.openForReading() {
      let mimeType = path.mimeType()
      var responseHeader: [String: String] = [:]
      if let attr = try? FileManager.default.attributesOfItem(atPath: path),
         let fileSize = attr[FileAttributeKey.size] as? UInt64 {
        responseHeader["Content-Length"] = String(fileSize)
      }
      return .custom(200, headers: responseHeader, contentType: mimeType) { writer in
        try? writer.write(file)
        file.close()
      }
    }
    return .notFound()
  }
}

public func share(directory path: String,
                  defaults: [String] = ["index.html", "default.html"]) -> NanoHTTPRequestHandler {
  return { request in
    guard let (_, value) = request.params.first,
          let fileRelativePath = value.removingPercentEncoding else {
      return NanoHTTPResponse.internalServerError("Internal Server Error")
    }
    if fileRelativePath.isEmpty {
      for d in defaults {
        if let file = try? (path + String.pathSeparator + d).openForReading() {
          return .custom(200) { writer in
            try? writer.write(file)
            file.close()
          }
        }
      }
    }
    let filePath = path + String.pathSeparator + fileRelativePath
    if let file = try? filePath.openForReading() {
      let mimeType = fileRelativePath.mimeType()
      var responseHeader: [String: String] = [:]
      if let attr = try? FileManager.default.attributesOfItem(atPath: filePath),
         let fileSize = attr[FileAttributeKey.size] as? UInt64 {
        responseHeader["Content-Length"] = String(fileSize)
      }
      return .custom(200, headers: responseHeader, contentType: mimeType) { writer in
        try? writer.write(file)
        file.close()
      }
    }
    return .notFound("Unknown file/directory")
  }
}

public func browse(directory dir: String) -> NanoHTTPRequestHandler {
  return { request in
    guard let (_, value) = request.params.first,
          let path = value.removingPercentEncoding else {
      return NanoHTTPResponse.internalServerError("Internal Server Error")
    }
    var base = request.path
    if base.last != "/" {
      base.append("/")
    }
    let filePath = dir + String.pathSeparator + path
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
          res += "<li><a href=\"\(path)\">\(f)</a></li>"
        }
        return .ok(.htmlBody("<ul style=\"list-style: none;\">\(res)</ul>"))
      } else {
        guard let file = try? filePath.openForReading() else {
          return .notFound("Unable to open file")
        }
        return .custom(200) { writer in
          try? writer.write(file)
          file.close()
        }
      }
    } catch {
      return NanoHTTPResponse.internalServerError("Internal Server Error")
    }
  }
}
