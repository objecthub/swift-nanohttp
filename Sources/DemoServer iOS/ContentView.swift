//
//  ContentView.swift
//  DemoServer-iOS
//
//  Created by Matthias Zenger on 20/07/2024.
//

import SwiftUI

struct ContentView: View {
  @EnvironmentObject var container: DemoServerContainer
  @State var state = "Running"
  
  var body: some View {
    VStack {
      GeometryReader { geometry in
        ScrollView {
          VStack {
            Text(container.output)
              .font(.system(size: 18))
              .lineLimit(nil)
              .frame(
                minWidth: geometry.size.width,
                idealWidth: geometry.size.width,
                maxWidth: geometry.size.width,
                minHeight: geometry.size.height,
                idealHeight: geometry.size.height,
                maxHeight: .infinity,
                alignment: .topLeading)
          }
        }
      }
      Divider()
      HStack {
        Image(systemName: "globe")
          .imageScale(.large)
          .foregroundStyle(.tint)
        Text("Demo Server: \(self.state)")
          .frame(maxWidth: .infinity)
        if self.state == "Running" {
          Button("Stop server") {
            self.container.server.stop()
            DispatchQueue.main.async {
              self.state = "Stopped"
            }
          }
        } else {
          Button("Start server") {
            try? self.container.server.start(9080, forceIPv4: true)
            DispatchQueue.main.async {
              self.state = "Running"
            }
          }
        }
      }
    }
    .padding()
  }
}

#Preview {
  ContentView()
}
