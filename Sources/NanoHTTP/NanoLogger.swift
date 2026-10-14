//
//  NanoLogger.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 14/10/2026.
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

import Foundation
import os

/// How important a message of the server is.
public enum NanoLogLevel: Int, Comparable, CustomStringConvertible {
  
  /// Details that help to find out what happened: nothing the server reports by itself.
  case debug = 0
  
  /// Something worth knowing that is not a problem: a client that went away in the middle of a
  /// response, a client that did not follow a protocol, a recovery.
  case info = 1
  
  /// Something that the server worked around, but that should not happen and may need attention:
  /// accepting connections fails, the connection limit is reached, a response header was dropped.
  case warning = 2
  
  /// A failure of the application: a handler that threw an error, a response that could not be built.
  case error = 3
  
  public static func < (lhs: NanoLogLevel, rhs: NanoLogLevel) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
  
  public var description: String {
    switch self {
      case .debug: return "debug"
      case .info: return "info"
      case .warning: return "warning"
      case .error: return "error"
    }
  }
}

/// Receives the messages that a server reports: a response that could not be written, a pause in
/// accepting connections, a handler that threw an error, a WebSocket client that broke the protocol.
/// Set the logger of a server with ``NanoHTTPServerIO/Configuration/logger``.
///
/// The message is given as an autoclosure: a logger that does not use a message (it is below the
/// level that the logger wants) does not pay for building its text. A logger can be called from any
/// thread, also at the same time, and has to be safe for that.
///
/// ```swift
/// // file scope
/// /// Collects what the server reports, for a window that shows it.
/// final class ExampleCollectingLogger: NanoHTTPLogger {
///   private let lock = NSLock()
///   private(set) var lines = [String]()
///
///   func log(_ level: NanoLogLevel, _ message: @autoclosure () -> String) {
///     guard level >= .info else {
///       return
///     }
///     let line = "\(level): \(message())"
///     self.lock.lock()
///     self.lines.append(line)
///     self.lock.unlock()
///   }
/// }
/// ```
public protocol NanoHTTPLogger {
  /// Logs a message.
  func log(_ level: NanoLogLevel, _ message: @autoclosure () -> String)
}

extension NanoHTTPLogger {
  /// Logs a message of the level ``NanoLogLevel/debug``.
  public func debug(_ message: @autoclosure () -> String) {
    self.log(.debug, message())
  }
  
  /// Logs a message of the level ``NanoLogLevel/info``.
  public func info(_ message: @autoclosure () -> String) {
    self.log(.info, message())
  }
  
  /// Logs a message of the level ``NanoLogLevel/warning``.
  public func warning(_ message: @autoclosure () -> String) {
    self.log(.warning, message())
  }
  
  /// Logs a message of the level ``NanoLogLevel/error``.
  public func error(_ message: @autoclosure () -> String) {
    self.log(.error, message())
  }
}

/// A logger that writes to the unified logging system of Apple's platforms (`os.Logger`): the messages
/// appear in the console of Xcode and in the Console app, with the subsystem `org.objecthub.NanoHTTP`.
/// It is the default logger of a server.
///
/// The messages are logged as public: they contain paths and error descriptions of your own server,
/// which are what a developer wants to read. Messages of the level ``NanoLogLevel/debug`` are not
/// kept by the system unless debug logging is switched on for the subsystem.
///
/// A command-line tool does not see these messages in its terminal; give it a ``NanoConsoleLogger``.
public final class NanoOSLogger: NanoHTTPLogger {
  private let logger: Logger
  
  /// The lowest level that is logged.
  public let minimumLevel: NanoLogLevel
  
  /// - Parameters:
  ///   - subsystem: The subsystem of the messages.
  ///   - category: The category of the messages.
  ///   - minimumLevel: The lowest level that is logged; messages below it are not even built.
  public init(subsystem: String = "org.objecthub.NanoHTTP",
              category: String = "server",
              minimumLevel: NanoLogLevel = .info) {
    self.logger = Logger(subsystem: subsystem, category: category)
    self.minimumLevel = minimumLevel
  }
  
  public func log(_ level: NanoLogLevel, _ message: @autoclosure () -> String) {
    guard level >= self.minimumLevel else {
      return
    }
    let text = message()
    switch level {
      case .debug:
        self.logger.debug("\(text, privacy: .public)")
      case .info:
        self.logger.info("\(text, privacy: .public)")
      case .warning:
        self.logger.warning("\(text, privacy: .public)")
      case .error:
        self.logger.error("\(text, privacy: .public)")
    }
  }
}

/// A logger that prints one line for every message, such as `[WARNING] Unable to accept a connection`,
/// for command-line tools and for tests. By default the lines are printed to the standard output, and every line is
/// flushed: when the output goes to a pipe or a file (`tool | tee log`), the standard output is buffered, and the
/// lines would otherwise show up late.
public final class NanoConsoleLogger: NanoHTTPLogger {
  private let output: (String) -> Void
  
  /// The lowest level that is logged.
  public let minimumLevel: NanoLogLevel
  
  /// - Parameters:
  ///   - minimumLevel: The lowest level that is logged; messages below it are not even built.
  ///   - output: Receives every line. It is called from any thread: the default (`print`, and a flush) is safe for that.
  public init(minimumLevel: NanoLogLevel = .info,
              output: @escaping (String) -> Void = { print($0); fflush(stdout) }) {
    self.minimumLevel = minimumLevel
    self.output = output
  }
  
  public func log(_ level: NanoLogLevel, _ message: @autoclosure () -> String) {
    guard level >= self.minimumLevel else {
      return
    }
    self.output("[\(level.description.uppercased())] \(message())")
  }
}

/// A logger that discards everything: use it to switch logging off.
public struct NanoSilentLogger: NanoHTTPLogger {
  public init() {
  }
  
  public func log(_ level: NanoLogLevel, _ message: @autoclosure () -> String) {
  }
}
