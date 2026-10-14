//
//  main.swift
//  ExampleHello
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

// A first server: a few routes, a route variable, a query parameter and a page for everything else.
//
//   swift run ExampleHello
//   curl http://localhost:8080/hello/Ada
//   curl 'http://localhost:8080/search?q=swift'

import Foundation
import NanoHTTP

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

let server = NanoHTTPServer()
server.configuration.listenAddress = network ? .allInterfaces : .loopback
server.configuration.logger = NanoConsoleLogger()      // the default logger writes to the system log

server.get["/"] = { _ in
  .ok(.text("Hello from NanoHTTP!\nTry /hello/Ada, /search?q=swift or POST something to /echo.\n"))
}

// `:name` matches one segment of the path; its text is in `request.params`.
server.get["/hello/:name"] = { request in
  .ok(.text("Hello, \(request.params["name"] ?? "world")!\n"))
}

// The query of the request is decoded: `?q=a%20b` is "a b".
server.get["/search"] = { request in
  .ok(.text("You searched for: \(request.query("q") ?? "nothing")\n"))
}

server.post["/echo"] = { request in
  .ok(.text(request.bodyString ?? ""))
}

// The answer to every path that no route matches.
server.notFoundHandler = { request in
  .notFound(.text("There is nothing at \(request.path)\n"))
}

// Ctrl-C and `kill` stop the server: the callback runs on a queue of its own, not inside the signal handler.
let stopped = DispatchSemaphore(value: 0)
NanoProcess.watchSignals { _ in
  server.stop()
  stopped.signal()
}

try server.start(port)
announce("Listening", port: try server.port())
stopped.wait()
