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
        container.output += str + "\n"
      } else {
        print(str)
      }
    }
  }
  
  let server: NanoHTTPServer
  @Published var output = ""
  
  init() {
    let server = iOSHttpServer()
    self.server = server
    server.container = self
    _ = demoServer(server: server,
                   directory:
                    FileManager.default.urls(for: .downloadsDirectory,
                                             in: .userDomainMask).first?.path ??
                    (try? String.File.currentWorkingDirectory()) ??
                    "/")
    do {
      try? server.start(9080, forceIPv4: true)
      print("Server has started (port = \(try server.port())). Try to connect now...")
    } catch {
      print("Server start error: \(error)")
    }
  }
}
