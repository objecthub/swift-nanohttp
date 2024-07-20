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

public func shareFile(_ path: String) -> HttpRequestHandler {
  return { _ in
    if let file = try? path.openForReading() {
      let mimeType = path.mimeType()
      var responseHeader: [String: String] = ["Content-Type": mimeType]
      if let attr = try? FileManager.default.attributesOfItem(atPath: path),
         let fileSize = attr[FileAttributeKey.size] as? UInt64 {
        responseHeader["Content-Length"] = String(fileSize)
      }
      return .raw(200, "OK", responseHeader, { writer in
        try? writer.write(file)
        file.close()
      })
    }
    return .notFound()
  }
}

public func shareFilesFromDirectory(_ directoryPath: String,
                                    defaults: [String] = ["index.html", "default.html"]) -> HttpRequestHandler {
  return { request in
    guard let fileRelativePath = request.params.first else {
      return .notFound()
    }
    if fileRelativePath.value.isEmpty {
      for path in defaults {
        if let file = try? (directoryPath + String.pathSeparator + path).openForReading() {
          return .raw(200, "OK", [:], { writer in
            try? writer.write(file)
            file.close()
          })
        }
      }
    }
    let filePath = directoryPath + String.pathSeparator + fileRelativePath.value
    if let file = try? filePath.openForReading() {
      let mimeType = fileRelativePath.value.mimeType()
      var responseHeader: [String: String] = ["Content-Type": mimeType]
      if let attr = try? FileManager.default.attributesOfItem(atPath: filePath),
         let fileSize = attr[FileAttributeKey.size] as? UInt64 {
        responseHeader["Content-Length"] = String(fileSize)
      }
      return .raw(200, "OK", responseHeader, { writer in
        try? writer.write(file)
        file.close()
      })
    }
    return .notFound()
  }
}

public func directoryBrowser(_ dir: String) -> HttpRequestHandler {
  return { request in
    guard let (_, value) = request.params.first else {
      return .notFound()
    }
    let filePath = dir + String.pathSeparator + value
    do {
      guard try filePath.exists() else {
        return .notFound()
      }
      if try filePath.directory() {
        var files = try filePath.files()
        files.sort(by: {$0.lowercased() < $1.lowercased()})
        return scopes {
          html {
            body {
              table(files) { file in
                tr {
                  td {
                    a {
                      href = request.path + "%2F" + file
                      inner = file
                    }
                  }
                }
              }
            }
          }
        }(request)
      } else {
        guard let file = try? filePath.openForReading() else {
          return .notFound()
        }
        return .raw(200, "OK", [:], { writer in
          try? writer.write(file)
          file.close()
        })
      }
    } catch {
      return HttpResponse.internalServerError(.text("Internal Server Error"))
    }
  }
}
