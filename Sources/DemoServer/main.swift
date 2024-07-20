//
//  main.swift
//  DemoServer-macOS
//
//  Created by Matthias Zenger on 20/07/2024.
//

import Foundation

import Foundation
import Dispatch
import NanoHTTPDemo

do {
  let path = try FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ??
             String.File.currentWorkingDirectory()
  print("directory = \(path)")
  let server = demoServer(directory: path)
  server["/testAfterBaseRoute"] = { request in
    print("Received request: \(request)")
    return .ok(.htmlBody("ok !"))
  }
  try? server.start(9080, forceIPv4: true)
  print("Server has started (port = \(try server.port())). Try to connect now...")
  RunLoop.main.run()
} catch {
  print("Server start error: \(error)")
}
