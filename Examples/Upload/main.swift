//
//  main.swift
//  ExampleUpload
//
//  Copyright © 2026 Matthias Zenger. All rights reserved.
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

// A form with a file upload. It shows `multipart/form-data` bodies, the limits of the server, cookies, and the
// post/redirect/get pattern: the answer to the form is a redirect, and a cookie carries the message for the page that
// follows (and deletes itself). The files are not stored: only their names and sizes are listed.
//
//   swift run ExampleUpload
//   (open http://localhost:8080 and choose files)

import Foundation
import NanoHTML
import NanoHTTP

struct Upload {
  let name: String
  let size: Int
  let type: String
}

/// What has been uploaded. Requests run on several threads, so there is a lock.
final class Uploads {
  private let lock = NSLock()
  private var items = [Upload]()
  
  func add(_ upload: Upload) {
    self.lock.lock()
    self.items.append(upload)
    self.lock.unlock()
  }
  
  var all: [Upload] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.items
  }
}

// The command line: `--port 8080` (0 picks a free port) and `--network` (reachable from other devices, not only from
// this machine).
let options = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
  guard let index = options.firstIndex(of: name), index + 1 < options.count else {
    return nil
  }
  return options[index + 1]
}
let port = UInt16(option("--port") ?? "") ?? 8080
let network = options.contains("--network")

func announce(_ message: String, port: Int) {
  let host = network ? (NanoNetworkInterface.localIP ?? "localhost") : "localhost"
  print("\(message) at http://\(host):\(port)  (Ctrl-C stops the server)")
  fflush(stdout)
}

let uploads = Uploads()
let server = NanoHTTPServer()
server.configuration.listenAddress = network ? .allInterfaces : .loopback
server.configuration.logger = NanoConsoleLogger()
server.configuration.limits.maxBodyBytes = 5 * 1024 * 1024      // the whole request is held in memory
server.configuration.limits.maxMultipartParts = 20              // fields and files of one form

/// The page: everything that comes from a request or from a file name is escaped by NanoHTML.
func page(message: String?, uploads: [Upload]) -> HTMLNode {
  Html {
    Head {
      Title("Upload")
      Meta().charset("utf-8")
    }
    Body {
      H1("Upload")
      if let message {
        P(message).id("message")
      }
      Form {
        P {
          Label("Note: ")
          Input().type("text").name("note")
        }
        P {
          Input().type("file").name("files").multiple()
        }
        Button("Send").type("submit")
      }.method("post").action("/upload").enctype("multipart/form-data")
      H2("Received so far")
      Ul {
        for upload in uploads {
          Li("\(upload.name): \(upload.size) bytes (\(upload.type))")
        }
      }
    }
  }
}

server.get["/"] = { request in
  let message = request.cookie("flash")
  var response = NanoHTTPResponse.html(page(message: message, uploads: uploads.all))
  if message != nil {
    response.deleteCookie(named: "flash")                   // shown once
  }
  return response
}

server.post["/upload"] = { request in
  let parts = request.parseMultiPartFormData()              // no parts at all if the body is not well-formed
  guard !parts.isEmpty else {
    throw NanoHTTPError.badRequest("Send the form as multipart/form-data")
  }
  var received = 0
  for part in parts {
    // A file name is what the client says: it is only displayed here. Never use it as a path without checking it.
    if let name = part.fileName, !name.isEmpty {
      uploads.add(Upload(name: name, size: part.body.count, type: part.headers["content-type"] ?? "unknown"))
      received += 1
    }
  }
  let note = parts.first { $0.name == "note" }.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
  var response = NanoHTTPResponse.seeOther("/")             // the browser fetches the page with GET: reloading it is safe
  response.setCookie(NanoHTTPCookie(name: "flash",
                                    value: "Received \(received) file(s). Your note: \(note.prefix(80))",
                                    maxAge: 60))
  return response
}

let stopped = DispatchSemaphore(value: 0)
NanoProcess.watchSignals { _ in
  server.stop()
  stopped.signal()
}

try server.start(port)
announce("The upload page is up", port: try server.port())
stopped.wait()
