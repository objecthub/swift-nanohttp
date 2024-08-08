//
//  ContentView.swift
//  DemoServer-iOS
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
