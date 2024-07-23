//
//  NanoHTTPRouter.swift
//  NanoHTTP
//
//  Created by Matthias Zenger on 23/07/2024.
//

import Foundation

public protocol NanoHTTPRouter {
  func register(_ method: String?, path: String, handler: NanoHTTPRequestHandler?)
  func merge(_ router: NanoHTTPRouter, withPrefix prefix: String) throws
  func route(_ method: String, path: String) -> ([String: String], NanoHTTPRequestHandler)?
  func routes() -> [String]
}

public enum NanoHTTPRouterError: Error {
  case unableToMerge
  case incompatibleRouterForMerge
}
