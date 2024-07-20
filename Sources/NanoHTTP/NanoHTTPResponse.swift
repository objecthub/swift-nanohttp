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

public enum SerializationError: Error {
  case invalidObject
  case notSupported
}

public protocol HttpResponseBodyWriter {
  func write(_ file: String.File) throws
  func write(_ data: [UInt8]) throws
  func write(_ data: ArraySlice<UInt8>) throws
  func write(_ data: Data) throws
}

public enum HttpResponseBody {
  case json(Any)
  case html(String)
  case htmlBody(String)
  case text(String)
  case data(Data, contentType: String? = nil)
  case custom(Any, (Any) throws -> String)
  
  func content() -> (Int, ((HttpResponseBodyWriter) throws -> Void)?) {
    do {
      switch self {
        case .json(let object):
          guard JSONSerialization.isValidJSONObject(object) else {
            throw SerializationError.invalidObject
          }
          let data = try JSONSerialization.data(withJSONObject: object)
          return (data.count, {
            try $0.write(data)
          })
        case .text(let body):
          let data = [UInt8](body.utf8)
          return (data.count, {
            try $0.write(data)
          })
        case .html(let html):
          let data = [UInt8](html.utf8)
          return (data.count, {
            try $0.write(data)
          })
        case .htmlBody(let body):
          let serialized = "<html><meta charset=\"UTF-8\"><body>\(body)</body></html>"
          let data = [UInt8](serialized.utf8)
          return (data.count, {
            try $0.write(data)
          })
        case .data(let data, _):
          return (data.count, {
            try $0.write(data)
          })
        case .custom(let object, let closure):
          let serialized = try closure(object)
          let data = [UInt8](serialized.utf8)
          return (data.count, {
            try $0.write(data)
          })
      }
    } catch {
      let data = [UInt8]("Serialization error: \(error)".utf8)
      return (data.count, {
        try $0.write(data)
      })
    }
  }
}

public enum HttpResponse {
  case switchProtocols([String: String], (Socket) -> Void)
  case ok(HttpResponseBody, [String: String] = [:]), created, accepted
  case movedPermanently(String)
  case movedTemporarily(String)
  case badRequest(HttpResponseBody?)
  case unauthorized(HttpResponseBody?)
  case forbidden(HttpResponseBody?)
  case notFound(HttpResponseBody? = nil)
  case notAcceptable(HttpResponseBody?)
  case tooManyRequests(HttpResponseBody?)
  case internalServerError(HttpResponseBody?)
  case raw(Int, String, [String: String]?, ((HttpResponseBodyWriter) throws -> Void)?)
  
  public var statusCode: Int {
    switch self {
      case .switchProtocols:
        return 101
      case .ok:
        return 200
      case .created:
        return 201
      case .accepted:
        return 202
      case .movedPermanently:
        return 301
      case .movedTemporarily:
        return 307
      case .badRequest:
        return 400
      case .unauthorized:
        return 401
      case .forbidden:
        return 403
      case .notFound:
        return 404
      case .notAcceptable:
        return 406
      case .tooManyRequests:
        return 429
      case .internalServerError:
        return 500
      case .raw(let code, _, _, _):
        return code
    }
  }
  
  public var reasonPhrase: String {
    switch self {
      case .switchProtocols:
        return "Switching Protocols"
      case .ok:
        return "OK"
      case .created:
        return "Created"
      case .accepted:
        return "Accepted"
      case .movedPermanently:
        return "Moved Permanently"
      case .movedTemporarily:
        return "Moved Temporarily"
      case .badRequest:
        return "Bad Request"
      case .unauthorized:
        return "Unauthorized"
      case .forbidden:
        return "Forbidden"
      case .notFound:
        return "Not Found"
      case .notAcceptable:
        return "Not Acceptable"
      case .tooManyRequests:
        return "Too Many Requests"
      case .internalServerError:
        return "Internal Server Error"
      case .raw(_, let phrase, _, _):
        return phrase
    }
  }
  
  public func headers() -> [String: String] {
    var headers = ["Server" : "Swifter \(HttpServer.VERSION)"]
    switch self {
      case .switchProtocols(let switchHeaders, _):
        for (key, value) in switchHeaders {
          headers[key] = value
        }
      case .ok(let body, let customHeaders):
        for (key, value) in customHeaders {
          headers.updateValue(value, forKey: key)
        }
        switch body {
          case .json:
            headers["Content-Type"] = "application/json"
          case .html, .htmlBody:
            headers["Content-Type"] = "text/html"
          case .text:
            headers["Content-Type"] = "text/plain"
          case .data(_, let contentType):
            headers["Content-Type"] = contentType
          default:
            break
        }
      case .movedPermanently(let location):
        headers["Location"] = location
      case .movedTemporarily(let location):
        headers["Location"] = location
      case .raw(_, _, let rawHeaders, _):
        if let rawHeaders {
          for (key, value) in rawHeaders {
            headers.updateValue(value, forKey: key)
          }
        }
      default:
        break
    }
    return headers
  }
  
  func content() -> (length: Int, write: ((HttpResponseBodyWriter) throws -> Void)?) {
    switch self {
      case .ok(let body, _):
        return body.content()
      case .badRequest(let body),
           .unauthorized(let body),
           .forbidden(let body),
           .notFound(let body),
           .tooManyRequests(let body),
           .internalServerError(let body):
        return body?.content() ?? (-1, nil)
      case .raw(_, _, _, let writer):
        return (-1, writer)
      default:
        return (-1, nil)
    }
  }
  
  func socketSession() -> ((Socket) -> Void)? {
    switch self {
      case .switchProtocols(_, let handler):
        return handler
      default:
        return nil
    }
  }
  
  /**
    Makes it possible to compare handler responses with '==', but
    ignores any associated values. This should generally be what
    you want. E.g.:

      let resp = handler(updatedRequest)
          if resp == .NotFound {
          print("Client requested not found: \(request.url)")
      }
  */
  public static func == (inLeft: HttpResponse, inRight: HttpResponse) -> Bool {
      return inLeft.statusCode == inRight.statusCode
  }
}
