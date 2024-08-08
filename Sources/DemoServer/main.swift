//
//  main.swift
//  DemoServer-macOS
//
//  Created by Matthias Zenger on 20/07/2024.
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

do {
  let path = try FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ??
             String.File.currentWorkingDirectory()
  let server: NanoHTTPServer  = .demo(server: MacOsHttpServer(), directory: path)
  server["/testAfterBaseRoute"] = { request in
    print("Received request: \(request)")
    return .ok(.htmlBody("ok !"))
  }
  try? server.start(9080, forceIPv4: true)
  RunLoop.main.run()
} catch {
  print("Server start error: \(error)")
}
