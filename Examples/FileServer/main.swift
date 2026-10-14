//
//  main.swift
//  ExampleFileServer
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

// Serves a directory: its files (with ranges and caching headers) and a listing. Requests that try to leave the
// directory are refused. The server is reachable from this machine only, and refuses requests for other host names.
//
//   swift run ExampleFileServer --directory ~/Downloads
//   swift run ExampleFileServer --directory ~/Downloads --network     # for other devices, on a network that you trust

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

let directory = (option("--directory") ?? ".") as NSString
let path = directory.expandingTildeInPath
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
  print("\(path) is not a directory")
  exit(1)
}

let server = NanoHTTPServer()
server.configuration.listenAddress = network ? .allInterfaces : .loopback
server.configuration.logger = NanoConsoleLogger()
// A web page that the user opens can make the browser send requests to this server. The policies refuse the ones that
// are not meant for it: a request for another host name (DNS rebinding, which makes a page of another site address
// this server), and, for the methods that change something, a request that a page of another site causes. (With
// `--network` the server is reachable from the network, and the host name cannot be checked.)
server.configuration.hostPolicy = .automatic
server.configuration.originPolicy = .sameOrigin

server["/files/::path"] = NanoFiles.share(directory: path)          // GET /files/photos/cat.jpg
server["/browse/::path"] = NanoFiles.browse(directory: path)        // a listing of the directory
server.get["/"] = { _ in .seeOther("/browse/") }

let stopped = DispatchSemaphore(value: 0)
NanoProcess.watchSignals { _ in
  server.stop()
  stopped.signal()
}

try server.start(port)
announce("Sharing \(path)", port: try server.port())
stopped.wait()
