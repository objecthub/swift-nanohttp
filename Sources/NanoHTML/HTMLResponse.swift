//
//  HTMLResponse.swift
//  NanoHTML
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
import NanoHTTP

extension NanoHTTPResponse {
  /// A response that contains a page or any other node, as `text/html; charset=utf-8`.
  /// The page is rendered at once, so the response has a length and the connection can be
  /// used again.
  ///
  /// ```swift
  /// let server = NanoHTTPServer()
  /// server["/missing"] = { request in
  ///   .html(Html { Body { P("There is no \(request.path)") } }, status: 404)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - page: The node to send: usually an ``Html`` element, which is sent as a complete
  ///     document.
  ///   - status: The status code of the response.
  ///   - headers: More headers of the response.
  public static func html(_ page: HTMLNode,
                          status: Int = 200,
                          headers: [String: String] = [:]) -> NanoHTTPResponse {
    return NanoHTTPResponse(statusCode: status, headers: headers, body: .html(page.rendered()))
  }
}

/// Returns a handler that answers with a page that a block builds. The block runs for
/// every request and receives the request, so that the page can show what the request
/// asked for.
///
/// ```swift
/// let server = NanoHTTPServer()
/// server["/hello/:name"] = htmlHandler { request in
///   Html {
///     Head { Title("Hello") }
///     Body {
///       H1("Hello, \(request.params["name"] ?? "world")!") // text is escaped
///       Ul {
///         for header in request.availableHeaders.sorted() {
///           Li("\(header): \(request.header(header) ?? "")")
///         }
///       }
///     }
///   }
/// }
/// ```
///
/// The block can throw: the error is answered like the error of any other handler. The
/// pages are built from values and share nothing, so the handler can run on several
/// threads at the same time, and needs no locks on a server that runs on one thread.
///
/// - Parameter page: Builds the page for a request.
public func htmlHandler(@HTMLBuilder _ page: @escaping (NanoHTTPRequest) throws -> HTMLNode)
    -> NanoHTTPRequestHandler {
  return { request in
    return NanoHTTPResponse.html(try page(request))
  }
}
