//
//  NanoSocketError.swift
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


/// Errors of sockets. The associated text is the description of the system error (`strerror`).
public enum NanoSocketError: Error {
  
  /// A socket could not be created.
  case socketCreationFailed(String)
  
  /// `SO_REUSEADDR` could not be set.
  case socketSettingReUseAddrFailed(String)
  
  /// The socket could not be bound: the port is in use, or the listen address
  /// is not an address of this machine (or no address at all).
  case bindFailed(String)
  
  /// The socket could not be put into the listening state.
  case listenFailed(String)
  
  /// Writing failed, or the socket is closed.
  case writeFailed(String)
  
  /// The address of the peer is not available, or the socket is closed.
  case getPeerNameFailed(String)
  
  /// The address of the peer could not be converted.
  case convertingPeerNameFailed
  
  /// An address could not be converted into text.
  case getNameInfoFailed(String)
  
  /// Accepting a connection failed.
  case acceptFailed(String)
  
  /// Reading failed: the connection ended or failed, the socket is closed, or
  /// a number of bytes that cannot be read was requested.
  case recvFailed(String)
  
  /// The local address is not available, or the socket is closed.
  case getSockNameFailed(String)
  /// A read or write did not finish within the time set with
  /// ``NanoSocket/setReceiveTimeout(_:)`` or ``NanoSocket/setSendTimeout(_:)``.
  case timedOut
}
