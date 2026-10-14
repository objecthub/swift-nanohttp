//
//  main.swift
//  ExampleTodoAPI
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

// A JSON API for a list of things to do: models in and out (`Codable`), status codes and headers, errors as JSON,
// and state that the handlers share (they run at the same time, on several threads, so it needs a lock).
//
//   swift run ExampleTodoAPI
//   curl -X POST -d '{"title":"Buy milk"}' http://localhost:8080/todos
//   curl http://localhost:8080/todos
//   curl -X PATCH -d '{"done":true}' http://localhost:8080/todos/1
//   curl -X DELETE http://localhost:8080/todos/1

import Foundation
import NanoHTTP

struct Todo: Codable {
  let id: Int
  var title: String
  var done: Bool
}

struct NewTodo: Decodable {
  let title: String
}

struct TodoChange: Decodable {
  let title: String?
  let done: Bool?
}

/// The list of things to do. Every request is handled on a thread of its own, so every access takes the lock.
final class TodoStore {
  private let lock = NSLock()
  private var todos = [Todo]()
  private var lastID = 0
  
  var all: [Todo] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.todos
  }
  
  func todo(_ id: Int) -> Todo? {
    return self.all.first { $0.id == id }
  }
  
  func add(title: String) -> Todo {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.lastID += 1
    let todo = Todo(id: self.lastID, title: title, done: false)
    self.todos.append(todo)
    return todo
  }
  
  func change(_ id: Int, with change: TodoChange) -> Todo? {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard let index = self.todos.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    self.todos[index].title = change.title ?? self.todos[index].title
    self.todos[index].done = change.done ?? self.todos[index].done
    return self.todos[index]
  }
  
  func remove(_ id: Int) -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard let index = self.todos.firstIndex(where: { $0.id == id }) else {
      return false
    }
    self.todos.remove(at: index)
    return true
  }
}

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

let store = TodoStore()
let server = NanoHTTPServer()
server.configuration.listenAddress = network ? .allInterfaces : .loopback
server.configuration.logger = NanoConsoleLogger()

/// The `id` of the route, or a `400` if it is no number. A handler can throw: a `NanoHTTPError` is the response.
func id(of request: NanoHTTPRequest) throws -> Int {
  guard let id = Int(request.params["id"] ?? "") else {
    throw NanoHTTPError.badRequest("The id is not a number")
  }
  return id
}

server.get["/todos"] = { _ in
  try .json(store.all)
}

server.post["/todos"] = { request in
  let new = try request.json(NewTodo.self)             // 400 if the body is not JSON of this form
  guard !new.title.trimmingCharacters(in: .whitespaces).isEmpty else {
    throw NanoHTTPError.unprocessableContent("The title is empty")
  }
  let todo = store.add(title: new.title)
  return try .json(todo, status: 201, headers: ["Location": "/todos/\(todo.id)"])
}

server.get["/todos/:id"] = { request in
  let id = try id(of: request)
  guard let todo = store.todo(id) else {
    throw NanoHTTPError.notFound("There is no todo \(id)")
  }
  return try .json(todo)
}

server.patch["/todos/:id"] = { request in
  let id = try id(of: request)
  guard let todo = store.change(id, with: try request.json(TodoChange.self)) else {
    throw NanoHTTPError.notFound("There is no todo \(id)")
  }
  return try .json(todo)
}

server.delete["/todos/:id"] = { request in
  let id = try id(of: request)
  guard store.remove(id) else {
    throw NanoHTTPError.notFound("There is no todo \(id)")
  }
  return .noContent()
}

// The errors of the handlers are answered as JSON, too: {"error": "..."}. Returning `nil` leaves an error to the default
// (a `500` without details for everything that is not a `NanoHTTPError`).
server.errorHandler = { error, _ in
  guard let error = error as? NanoHTTPError else {
    return nil
  }
  return try? NanoHTTPResponse.json(["error": error.message ?? "Error"], status: error.status)
}

// Middleware wraps the handling of every request: here, a line for the log.
server.middleware.append { request, next in
  let begin = Date()
  let response = try next(request)
  let milliseconds = Date().timeIntervalSince(begin) * 1000
  print("\(request.method) \(request.rawPath) -> \(response.statusCode) (\(Int(milliseconds)) ms)")
  return response
}

let stopped = DispatchSemaphore(value: 0)
NanoProcess.watchSignals { _ in
  server.stop()
  stopped.signal()
}

try server.start(port)
announce("The API is listening", port: try server.port())
stopped.wait()
