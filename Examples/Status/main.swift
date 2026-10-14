//
//  main.swift
//  ExampleStatus
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

// A server with ONE thread, which does everything: it accepts connections, reads requests, runs the middleware and the
// handlers, writes the responses and drives the WebSockets. Everything that the handlers share is a plain variable:
// nothing here takes a lock (the thread sanitizer would say if that were wrong). The price: a handler that takes a
// second delays every other request by a second.
//
//   swift run ExampleStatus
//   (open http://localhost:8080, and call http://localhost:8080/ping a few times)

import Foundation
import NanoHTML
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

/// Prints where the server listens when it is up, which `run` leaves to a subclass that overrides `listen()`.
final class StatusServer: NanoHTTPServer {
  override func listen() {
    announce("The status page is up", port: (try? self.port()) ?? 0)
    super.listen()
  }
}

// The state: plain variables, because only the one thread of the server touches them.
let started = Date()
var requests = 0
var perPath = [String: Int]()
let live = NanoWebSocketHub()

let server = StatusServer()
server.configuration.threading = .singleThread
server.configuration.listenAddress = network ? .allInterfaces : .loopback
server.configuration.logger = NanoConsoleLogger()

let knownPaths: Set<String> = ["/", "/ping", "/live"]

// Counts every request, and tells the pages that are open (over their WebSockets) at once.
server.middleware.append { request, next in
  requests += 1
  perPath[knownPaths.contains(request.path) ? request.path : "(other)", default: 0] += 1
  live.broadcast(text: "\(requests)")
  return try next(request)
}

let update = Script("""
const counter = document.getElementById('requests');
const socket = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/live');
socket.onmessage = (event) => { counter.textContent = event.data; };
""")

server["/"] = htmlHandler { _ in
  Html {
    Head {
      Title("Status")
      Meta().charset("utf-8")
    }
    Body {
      H1("Status")
      P {
        "Requests served: "
        Strong("\(requests)").id("requests")
      }
      P("Up for \(Int(Date().timeIntervalSince(started))) seconds, on one thread.")
      Table {
        Tr { Th("Path"); Th("Requests") }
        for (path, count) in perPath.sorted(by: { $0.key < $1.key }) {
          Tr { Td(path); Td("\(count)") }
        }
      }
      P {
        A("Ping").href("/ping")
        " (the number above changes on every page that is open)"
      }
      update
    }
  }
}

server["/ping"] = { _ in .ok(.text("pong")) }

server["/live"] = NanoWebSocket.handler(
  connected: { session in session.writeText("\(requests)") },
  hub: live)

NanoProcess.watchSignals { _ in
  server.stop()                        // makes `run` return: the program ends
}

try server.run(port)                   // the main thread is the thread of the server
print("The server has stopped.")
