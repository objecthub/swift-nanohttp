//
//  NanoHTTPResponse.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 20/07/2024.
//  Based on `HttpResponse` of framework `Swifter` by Damian Kołakowski.
//
//  Copyright © 2014-2016 Damian Kołakowski. All rights reserved.
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

import Foundation

public struct NanoHTTPResponse {
  
  public enum Body: ExpressibleByStringLiteral {
    case empty
    case text(String)
    case html(String)
    case json(Any)
    case data(Data, contentType: String? = nil)
    case custom((NanoHTTPResponseBodyWriter) throws -> Void, contentType: String? = nil)
    case socket((NanoSocket) -> Void)
    
    public init(stringLiteral value: String) {
      self = .text(value)
    }
    
    public static func htmlBody(_ content: String) -> Body {
      return .html("<html><meta charset=\"UTF-8\"><body>\(content)</body></html>")
    }
    
    public func contentType() -> String? {
      switch self {
        case .empty:
          return nil
        case .text(_):
          return "text/plain"
        case .html(_):
          return "text/html"
        case .json(_):
          return "application/json"
        case .data(_, let contentType):
          return contentType ?? "application/octet-stream"
        case .custom(_, let contentType):
          return contentType
        case .socket(_):
          return nil
      }
    }
    
    func content() -> (Int?, ((NanoHTTPResponseBodyWriter) throws -> Void)?) {
      do {
        switch self {
          case .empty:
            return (0, nil)
          case .text(let body):
            let data = [UInt8](body.utf8)
            return (data.count, { try $0.write(data) })
          case .html(let html):
            let data = [UInt8](html.utf8)
            return (data.count, { try $0.write(data) })
          case .json(let object):
            guard JSONSerialization.isValidJSONObject(object) else {
              throw ResponseError.invalidObject
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            return (data.count, { try $0.write(data) })
          case .data(let data, _):
            return (data.count, { try $0.write(data) })
          case .custom(let content, _):
            return (nil, content)
          case .socket(_):
            return (nil, nil)
        }
      } catch {
        let data = [UInt8]("Serialization error: \(error)".utf8)
        return (data.count, { try $0.write(data) })
      }
    }
  }
  
  public enum ResponseError: Error {
    case invalidObject
  }
  
  /// The HTTP status code
  public var statusCode: Int
  
  /// HTTP headers
  public var headers: [String : String]
  
  /// HTTP body
  public var body: Body
  
  /// Initializer
  public init(statusCode: Int, headers: [String : String] = [:], body: Body = .empty) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
  
  public static func ok(headers: [String : String] = [:], _ body: Body) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 200, headers: headers, body: body)
  }
  
  public static func created() -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 201)
  }
  
  public static func accepted() -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 202)
  }
  
  public static func switchProtocols(_ headers: [String : String],
                                     _ socketSession: @escaping (NanoSocket) -> Void) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 101, headers: headers, body: .socket(socketSession))
  }
  
  public static func movedPermanently(_ location: String,
                                      _ headers: [String : String] = [:]) -> NanoHTTPResponse {
    var headers = headers
    headers["Location"] = location
    return NanoHTTPResponse(statusCode: 301, headers: headers)
  }
  
  public static func movedTemporarily(_ location: String,
                                      _ headers: [String : String] = [:]) -> NanoHTTPResponse {
    var headers = headers
    headers["Location"] = location
    return NanoHTTPResponse(statusCode: 307, headers: headers)
  }
  
  public static func badRequest(headers: [String : String] = [:],
                                _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 400, headers: headers, body: body)
  }
  
  public static func unauthorized(headers: [String : String] = [:],
                                  _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 401, headers: headers, body: body)
  }
  
  public static func forbidden(headers: [String : String] = [:],
                               _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 403, headers: headers, body: body)
  }
  
  public static func notFound(headers: [String : String] = [:],
                              _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 404, headers: headers, body: body)
  }
  
  public static func methodNotAllowed(headers: [String : String] = [:],
                                      _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 405, headers: headers, body: body)
  }
  public static func notAcceptable(headers: [String : String] = [:],
                                   _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 406, headers: headers, body: body)
  }
  
  public static func conflict(headers: [String : String] = [:],
                              _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 409, headers: headers, body: body)
  }
  
  public static func unsupportedMediaType(headers: [String : String] = [:],
                                          _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 415, headers: headers, body: body)
  }
  
  public static func tooManyRequests(headers: [String : String] = [:],
                                     _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 429, headers: headers, body: body)
  }
  
  public static func internalServerError(headers: [String : String] = [:],
                                         _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 500, headers: headers, body: body)
  }
  
  public static func notImplemented(headers: [String : String] = [:],
                                    _ body: Body = .empty) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: 501, headers: headers, body: body)
  }
  
  public static func custom(_ statusCode: Int,
                            headers: [String : String] = [:],
                            contentType: String? = nil,
                            writer: @escaping (NanoHTTPResponseBodyWriter) throws -> Void) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: statusCode,
                            headers: headers,
                            body: .custom(writer, contentType: contentType))
  }
  
  public var reasonPhrase: String {
    return HTTPURLResponse.localizedString(forStatusCode: self.statusCode)
  }
  
  public func allHeaders() -> [String : String] {
    var headers = self.headers
    if let contentType = self.body.contentType() {
      headers["Content-Type"] = contentType
    }
    return headers
  }
  
  func socketSession() -> ((NanoSocket) -> Void)? {
    switch self.body {
      case .socket(let handler):
        return handler
      default:
        return nil
    }
  }
}
