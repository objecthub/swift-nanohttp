# Using NanoHTTP on iOS

Run a server inside an app, and let other devices find it.

## Overview

A server inside an iOS or tvOS app works like a server in a command-line tool, with the following differences.

### Starting and stopping with the app

An app that goes to the background is suspended soon after, and a suspended app does not serve requests. Start the
server when the app becomes active and stop it when it resigns, or tell the user that the server is only available
while the app is on screen:

```swift
// file scope
final class ExampleServerController {
  let server = NanoHTTPServer()

  init() {
    server.get["/hello"] = { _ in .ok(.text("Hello from the app")) }
  }

  func appDidBecomeActive() {
    try? server.start(8080)
  }

  func appWillResignActive() {
    server.stop()
  }
}
```

``NanoHTTPServerIO/start(_:)`` does nothing if the server is already running,
and a stopped server can be started again, so both calls are safe to repeat.

### Finding the address

`NanoNetworkInterface.localIP` is the address of the device on the local network, to show to the user (for example as
`http://192.168.1.20:8080`):

```swift
let server = NanoHTTPServer()
server.configuration.listenAddress = .allInterfaces   // the default, loopback, cannot be reached by other devices
try server.start(8080)
if let address = NanoNetworkInterface.localIP {
  print("Open http://\(address):\(try server.port()) on another device")
}
```

``NanoNetworkInterface/available()`` lists all addresses of the interfaces that are up.

### Permissions

Since iOS 14 the system asks the user for permission before an app uses the local network. Add a short explanation
under the key `NSLocalNetworkUsageDescription` to the `Info.plist` of the app. If other devices cannot reach the
app's server, look at the setting of the app in Settings > Privacy > Local Network.

### Reaching the server from the same app

App Transport Security applies to the requests that an app makes with `URLSession`, also to its own server, unless
the `Info.plist` allows local networking (`NSAppTransportSecurity` with `NSAllowsLocalNetworking`). For a web view
that shows pages of the app's server, the same applies.

### The demo app

The Xcode project of the repository contains an iOS app (`DemoServer iOS`) that runs the demo server and shows its
log.
