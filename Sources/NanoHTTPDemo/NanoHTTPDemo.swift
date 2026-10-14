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
import NanoHTML

extension NanoHTTPServer {
  /// Adds the demo routes to a server, see ``demoServer(server:directory:)``.
  public static func demo(server: NanoHTTPServer = NanoHTTPServer(),
                          directory publicDir: String) -> NanoHTTPServer {
    return demoServer(server: server, directory: publicDir)
  }
}

/// Adds routes that demonstrate the framework to `server`: an index of the routes, routes that echo the
/// request, a form and an upload, redirects, a streamed response, a WebSocket echo, and `directory`
/// served read-only at `/public/...` (files) and `/files/...` (a browsable listing). Everything in
/// `directory` is readable by anybody who can reach the server; use a directory without secrets.
/// This is a demonstration, not a template for production code.
public func demoServer(server: NanoHTTPServer = NanoHTTPServer(),
                       directory publicDir: String) -> NanoHTTPServer {
  server.log("directory = \(publicDir)")
  server["/public/::path"] = NanoFiles.share(directory: publicDir)
  server["/files/::path"] = NanoFiles.browse(directory: publicDir)
  server["/"] = htmlHandler { _ in
    Html {
      Body {
        Ul {
          for route in server.routes.sorted() where !route.isEmpty {
            Li { A(route).href(route) }
          }
        }
      }
    }
  }
  server["/magic"] = {
    return .ok(headers: ["XXX-Custom-Header" : "value"], .htmlBody("You asked for " + $0.path.htmlEscaped))
  }
  server["/test/:param1/:param2", "/pathTest/::param/end"] = htmlHandler { request in
    Html {
      Body {
        H3("Address: \(request.address ?? "unknown")")
        H3("Url: \(request.path)")
        H3("Method: \(request.method)")
        H3("Query:")
        Table {
          for (name, value) in request.queryParams {
            Tr { Td(name); Td(value) }
          }
        }
        H3("Headers:")
        Table {
          for name in request.availableHeaders {
            Tr { Td(name); Td(request.header(name) ?? "") }
          }
        }
        H3("Route params:")
        Table {
          for (name, value) in request.params {
            Tr { Td(name); Td(value) }
          }
        }
      }
    }
  }
  server.get["/upload"] = htmlHandler { _ in
    Html {
      Body {
        Form {
          Input().name("my_file1").type("file")
          Input().name("my_file2").type("file")
          Input().name("my_file3").type("file")
          Button("Upload").type("submit")
        }
        .method("POST").action("/upload").enctype("multipart/form-data")
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
      response += "Name: \(name.htmlEscaped) File name: \(fileName.htmlEscaped) Size: \(multipart.body.count)<br>"
    }
    return .ok(headers: ["XXX-Custom-Header" : "value"], .htmlBody(response))
  }
  server.get["/login"] = htmlHandler { _ in
    Html {
      Head {
        Script().src("https://cdn.staticfile.org/jquery/2.1.4/jquery.min.js")
        Link().rel("stylesheet")
              .href("https://cdn.staticfile.org/twitter-bootstrap/3.3.0/css/bootstrap.min.css")
      }
      Body {
        H3("Sign In")
        Form {
          Fieldset {
            Input().placeholder("E-mail").name("email").type("email").autofocus()
            Input().placeholder("Password").name("password").type("password")
            A { Button("Login").type("submit") }.href("/login")
          }
        }
        .method("POST").action("/login")
        Script().src("https://cdn.staticfile.org/twitter-bootstrap/3.3.0/js/bootstrap.min.js")
      }
    }
  }
  server.post["/login"] = { request in
    let formFields = request.parseUrlencodedForm()
    return .ok(headers: ["XXX-Custom-Header": "value"],
               .htmlBody(formFields.map({ "\($0.0.htmlEscaped) = \($0.1.htmlEscaped)" }).joined(separator: "<br>")))
  }
  server["/demo"] = htmlHandler { _ in
    Html {
      Body {
        Div {
          H2("Hello Swift")
          Img().src("https://devimages.apple.com.edgekey.net/swift/images/swift-hero_2x.png")
               .alt("The Swift logo")
        }
        .style("text-align: center")
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
    return .ok(headers: ["XXX-Custom-Header": "value"], .htmlBody(request.path.htmlEscaped))
  }
  server["/stream"] = { _ in
    return .custom(200) { writer in
      for index in 0...100 {
        try writer.write([UInt8]("[chunk \(index)]".utf8))
      }
    }
  }
  server["/websocket-echo"] = NanoWebSocket.handler(
    text: { (session, text) in session.writeText(text) },
    binary: { (session, binary) in session.writeBinary(binary) },
    pong: { (_, _) in /* Got a pong frame */ },
    connected: { _ in /* New client connected */ },
    disconnected: { _ in /* Client disconnected */ }
  )
  server.notFoundHandler = { _ in
    return .movedPermanently("https://github.com/404")
  }
  server.middleware.append { request, next in
    server.log("Middleware: \(request.address ?? "unknown address") -> \(request.method) \(request.rawPath)")
    return try next(request)
  }
  return server
}
