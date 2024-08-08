//
//  DemoServerContainer.swift
//  DemoServer iOS
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
import NanoHTTP
import NanoHTTPDemo

final class DemoServerContainer: ObservableObject {
  
  final class iOSHttpServer: NanoHTTPServer {
    weak var container: DemoServerContainer? = nil
    public override func log(_ str: String) {
      if let container {
        DispatchQueue.main.async {
          container.output += str + "\n"
        }
      } else {
        print(str)
      }
    }
    public override func stop() {
      if self.operating {
        super.stop()
        self.log("Server stopped")
      } else {
        super.stop()
      }
    }
    public override func listen(priority: DispatchQoS.QoSClass?) {
      do {
        let port = try self.port()
        self.log("Server has started (port = \(port))")
        if let ip = NetworkInterface.localIP {
          self.log("Try to connect now at http://\(ip):\(port)")
        }
      } catch {}
      super.listen(priority: priority)
    }
  }
  
  let server: NanoHTTPServer
  @Published var output = ""
  
  init() {
    let server = iOSHttpServer()
    self.server = server
    server.container = self
    _ = NanoHTTPServer.demo(server: server,
                            directory: FileManager.default.urls(for: .downloadsDirectory,
                                                                in: .userDomainMask).first?.path ??
                                       (try? String.File.currentWorkingDirectory()) ??
                                       "/")
    try? server.start(9080, forceIPv4: true)
  }
}
