//
//  DemoServerContainer.swift
//  DemoServer iOS
//
//  Created by Matthias Zenger on 20/07/2024.
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
