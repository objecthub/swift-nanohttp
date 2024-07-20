//
//  DemoServer_iOSApp.swift
//  DemoServer-iOS
//
//  Created by Matthias Zenger on 20/07/2024.
//

import SwiftUI

@main
struct DemoServerApp: App {
  @StateObject private var container = DemoServerContainer()
  
  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(self.container)
    }
  }
}
