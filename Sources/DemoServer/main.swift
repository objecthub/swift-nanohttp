//
//  main.swift
//  DemoServer-macOS
//
//  Created by Matthias Zenger on 20/07/2024.
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
import Dispatch
import NanoHTTP
import NanoHTTPDemo

final class MacOsHttpServer: NanoHTTPServer {
  public override func stop() {
    if self.operating {
      super.stop()
      self.log("Server stopped")
    } else {
      super.stop()
    }
  }
  
  public override func listen() {
    do {
      let port = try self.port()
      self.log("Server has started (port = \(port))")
      if self.configuration.listenAddress == .loopback {
        self.log("Try to connect now at http://localhost:\(port)")
      } else if let ip = NanoNetworkInterface.localIP {
        self.log("Try to connect now at http://\(ip):\(port)")
      }
    } catch {}
    super.listen()
  }
}

/// The value after an option of the command line (`--port 9000`).
func option(_ name: String) -> String? {
  let arguments = CommandLine.arguments
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
    return nil
  }
  return arguments[index + 1]
}

do {
  // The folder that is shared: the Downloads folder, or the one that `--directory` names.
  let path = option("--directory").map { ($0 as NSString).expandingTildeInPath } ??
             FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ??
             FileManager.default.currentDirectoryPath
  let macServer = MacOsHttpServer()
  // A command-line tool shows what the server reports in its terminal; the default logger writes to the
  // unified logging system (Console app), which a terminal does not show.
  macServer.configuration.logger = NanoConsoleLogger()
  // The pages of the demo are used from the browser of this machine: other sites should not be able to use the server
  // through that browser (DNS rebinding, forms and WebSockets of other pages).
  macServer.configuration.hostPolicy = .automatic
  macServer.configuration.originPolicy = .sameOrigin
  let server: NanoHTTPServer = .demo(server: macServer, directory: path)
  server["/testAfterBaseRoute"] = { request in
    print("Received request: \(request)")
    return .ok(.htmlBody("ok !"))
  }
  // The server shares a folder (Downloads by default): only this machine can reach it, unless asked otherwise.
  if CommandLine.arguments.contains("--network") {
    server.configuration.listenAddress = .allInterfaces
  }
  // Everything on one thread: requests are served one at a time (the WebSocket demo keeps it busy).
  if CommandLine.arguments.contains("--single-thread") {
    server.configuration.threading = .singleThread
  }
  try server.start(UInt16(option("--port") ?? "") ?? 9080)          // `--port 0` picks a free port
  RunLoop.main.run()
} catch {
  print("Server start error: \(error)")
}
