//
//  NanoHTTPDemo.swift
//  NanoHTTPDemo
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `DemoServer` of framework `Swifter` by Damian Kołakowski.
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
import NanoHTTP

extension NanoHTTPServer {
  public static func demo(server: NanoHTTPServer = NanoHTTPServer(),
                          directory publicDir: String) -> NanoHTTPServer {
    return demoServer(server: server, directory: publicDir)
  }
}

public func demoServer(server: NanoHTTPServer = NanoHTTPServer(),
                       directory publicDir: String) -> NanoHTTPServer {
  server.log("directory = \(publicDir)")
  server["/public/::path"] = share(directory: publicDir)
  server["/files/::path"] = browse(directory: publicDir)
  server["/"] = htmlHandler {
    html {
      body {
        ul(server.routes) { service in
          if !service.isEmpty {
            li {
              a { href = service; inner = service }
            }
          }
        }
      }
    }
  }
  server["/magic"] = {
    return .ok(headers: ["XXX-Custom-Header" : "value"], .htmlBody("You asked for " + $0.path))
  }
  server["/test/:param1/:param2", "/pathTest/::param/end"] = { request in
    htmlHandler {
      html {
        body {
          h3 { inner = "Address: \(request.address ?? "unknown")" }
          h3 { inner = "Url: \(request.path)" }
          h3 { inner = "Method: \(request.method)" }
          h3 { inner = "Query:" }
          table(request.queryParams) { param in
            tr {
              td { inner = param.0 }
              td { inner = param.1 }
            }
          }
          h3 { inner = "Headers:" }
          table(request.availableHeaders) { header in
            tr {
              td { inner = header }
              td { inner = request.header(header) }
            }
          }
          h3 { inner = "Route params:" }
          table(request.params) { param in
            tr {
              td { inner = param.0 }
              td { inner = param.1 }
            }
          }
        }
      }
    }(request)
  }
  server.get["/upload"] = htmlHandler {
    html {
      body {
        form {
          method = "POST"
          action = "/upload"
          enctype = "multipart/form-data"
          input { name = "my_file1"; type = "file" }
          input { name = "my_file2"; type = "file" }
          input { name = "my_file3"; type = "file" }
          button {
            type = "submit"
            inner = "Upload"
          }
        }
      }
    }
  }
  server.post["/upload"] = { request in
    var response = ""
    for multipart in request.parseMultiPartFormData() {
      guard let name = multipart.name,
            let fileName = multipart.fileName else {
        continue
      }
      response += "Name: \(name) File name: \(fileName) Size: \(multipart.body.count)<br>"
    }
    return .ok(headers: ["XXX-Custom-Header" : "value"], .htmlBody(response))
  }
  server.get["/login"] = htmlHandler {
    html {
      head {
        script { src = "http://cdn.staticfile.org/jquery/2.1.4/jquery.min.js" }
        stylesheet { href = "http://cdn.staticfile.org/twitter-bootstrap/3.3.0/css/bootstrap.min.css" }
      }
      body {
        h3 { inner = "Sign In" }
        form {
          method = "POST"
          action = "/login"
          fieldset {
            input { placeholder = "E-mail"; name = "email"; type = "email"; autofocus = "" }
            input { placeholder = "Password"; name = "password"; type = "password"; autofocus = "" }
            a {
              href = "/login"
              button {
                type = "submit"
                inner = "Login"
              }
            }
          }
        }
        javascript {
          src = "http://cdn.staticfile.org/twitter-bootstrap/3.3.0/js/bootstrap.min.js"
        }
      }
    }
  }
  server.post["/login"] = { request in
    let formFields = request.parseUrlencodedForm()
    return .ok(headers: ["XXX-Custom-Header": "value"],
               .htmlBody(formFields.map({ "\($0.0) = \($0.1)" }).joined(separator: "<br>")))
  }
  server["/demo"] = htmlHandler {
    html {
      body {
        center {
          h2 { inner = "Hello Swift" }
          img { src = "https://devimages.apple.com.edgekey.net/swift/images/swift-hero_2x.png" }
        }
      }
    }
  }
  server["/custom"] = { _ in
    return .custom(200, headers: ["XXX-Custom-Header": "value"]) {
      try $0.write([UInt8]("test".utf8))
    }
  }
  server["/open"] = { _ in
    return .ok(.htmlBody("Open connections: \(server.openConnections)"))
  }
  server["/close"] = { _ in
    DispatchQueue.global().asyncAfter(deadline: .now().advanced(by: .seconds(1))) {
      server.closeAndforgetAllConnections()
    }
    return .ok(.htmlBody("Open connections: \(server.openConnections)"))
  }
  server["/redirect/permanently"] = { _ in
    return .movedPermanently("http://www.google.com")
  }
  server["/redirect/temporarily"] = { _ in
    return .movedTemporarily("http://www.google.com")
  }
  server["/long"] = { _ in
    var longResponse = ""
    for index in 0..<1000 { longResponse += "(\(index)),->" }
    return .ok(headers: ["XXX-Custom-Header": "value"], .htmlBody(longResponse))
  }
  server["/wildcard/*/test/*/:param"] = { request in
    return .ok(headers: ["XXX-Custom-Header": "value"], .htmlBody(request.path))
  }
  server["/stream"] = { _ in
    return .custom(200) { writer in
      for index in 0...100 {
        try writer.write([UInt8]("[chunk \(index)]".utf8))
      }
    }
  }
  server["/websocket-echo"] = websocket(
    text: { (session, text) in session.writeText(text) },
    binary: { (session, binary) in session.writeBinary(binary) },
    pong: { (_, _) in /* Got a pong frame */ },
    connected: { _ in /* New client connected */ },
    disconnected: { _ in /* Client disconnected */ }
  )
  server.notFoundHandler = { _ in
    return .movedPermanently("https://github.com/404")
  }
  server.middleware.append { request in
    server.log("Middleware: \(request.address ?? "unknown address") -> \(request.method) \(request.path)")
    return nil
  }
  return server
}
