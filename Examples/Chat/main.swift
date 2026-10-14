//
//  main.swift
//  ExampleChat
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

// A chat room with WebSockets. `NanoWebSocketHub` keeps the sessions and sends a message to all of them, from any
// thread, without locks in this program. The page comes from NanoHTML (the library for pages), and the browser shows
// what it receives with `textContent`, so a message cannot inject HTML.
//
//   swift run ExampleChat
//   (open http://localhost:8080 in two browser windows)

import Foundation
import NanoHTML
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

let page = Script("""
const log = document.getElementById('log');
const form = document.getElementById('form');
const input = document.getElementById('text');
const name = 'guest ' + Math.floor(Math.random() * 1000);
const socket = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/chat');
function add(text) {
  const item = document.createElement('li');
  item.textContent = text;
  log.appendChild(item);
}
socket.onmessage = (event) => add(event.data);
socket.onclose = () => add('(the connection has been closed)');
form.onsubmit = (event) => {
  event.preventDefault();
  if (input.value && socket.readyState === WebSocket.OPEN) {
    socket.send(name + ': ' + input.value);
    input.value = '';
  }
};
""")

let chat = NanoWebSocketHub()
let server = NanoHTTPServer()
server.configuration.listenAddress = network ? .allInterfaces : .loopback
server.configuration.logger = NanoConsoleLogger()
// A page of another site cannot open a WebSocket to this chat (cross-site WebSocket hijacking).
server.configuration.originPolicy = .sameOrigin

server["/"] = htmlHandler { _ in
  Html {
    Head {
      Title("NanoHTTP chat")
      Meta().charset("utf-8")
    }
    Body {
      H1("Chat")
      Ul().id("log")
      Form {
        Input().id("text").type("text").autocomplete("off").autofocus()
        Button("Send").type("submit")
      }.id("form")
      page
    }
  }
}

// Messages go to everybody, the sender included. The hub adds a session when it connects and removes it when it ends
// (also when a client stops reading: it is dropped after a few seconds, so that it cannot hold up the others).
server["/chat"] = NanoWebSocket.handler(
  text: { _, message in
    chat.broadcast(text: message)
  },
  connected: { session in
    session.writeText("Welcome! \(chat.count) here now.")
    chat.broadcast(text: "Somebody joined (\(chat.count) here now).", except: session)
  },
  disconnected: { _ in
    chat.broadcast(text: "Somebody left (\(chat.count) here now).")
  },
  maxMessageSize: 4 * 1024,                // a chat message is short
  hub: chat)

let stopped = DispatchSemaphore(value: 0)
NanoProcess.watchSignals { _ in
  server.stop()
  stopped.signal()
}

try server.start(port)
announce("The chat is open", port: try server.port())
stopped.wait()
