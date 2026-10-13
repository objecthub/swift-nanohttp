# Migrating from 1.x to 2.0

2.0 is not released yet; this guide grows with the changes on the way. Every item says what to change.

## Server configuration

A server is configured with one object, `server.configuration` (`NanoHTTPServerIO.Configuration`), instead of
properties and parameters of `start`.

| 1.x | 2.0 |
|---|---|
| `server.listenAddressIPv4 = "127.0.0.1"` and `start(8080, forceIPv4: true)` | nothing: loopback is the default |
| no address (all network interfaces) | `server.configuration.listenAddress = .allInterfaces` |
| `server.listenAddressIPv4 = "192.168.1.20"` and `forceIPv4: true` | `server.configuration.listenAddress = .address("192.168.1.20")` |
| `server.listenAddressIPv6 = "::1"` | `server.configuration.listenAddress = .address("::1")` |
| `server.limits = NanoHTTPParser.Limits(...)` | `server.configuration.limits = NanoHTTPParser.Limits(...)` |
| `start(8080, priority: .userInitiated, handlerPriority: .utility)` | `configuration.acceptQoS = .userInitiated`, `configuration.connectionQoS = .utility`, `start(8080)` |
| `override func listen(priority:)` | `override func listen()` |
| `NanoSocket.tcpSocketForListen(port, true, 8, "127.0.0.1")` | `NanoSocket.tcpSocketForListen(port, .loopback, backlog: 8)` |

**Check who must reach the server.** A 1.x server without an address listened on all network interfaces. In 2.0 that
needs `.allInterfaces`; without it, devices on the network get "connection refused", and an iOS app that is meant to
be reached from another device stops working. A server that is only used by the same machine needs no change, and is
no longer exposed to the network by accident.

`forceIPv4` is gone: `.loopback` is an IPv4 socket (`127.0.0.1`), `.allInterfaces` is one socket for IPv4 and IPv6,
and `.address(_)` uses the family of the address. `.address("0.0.0.0")` listens on all IPv4 interfaces only.

`start` takes only the port, and returns after the server has started to listen.

**`priority: nil` is gone**, and with it the one-thread mode of 1.x. Use
`server.configuration.threading = .singleThread` instead (see below): `start(8080)` runs the whole server on one
thread of its own, and `run(8080)` on the calling thread, like `start(8080, priority: nil)` did. In 1.x, `priority: nil`
served the connections on the accepting thread (`handlerPriority: nil`) or accepted on the calling thread (`priority:
nil`); the new mode is better than both because connections that wait for a request no longer block the thread.
The one-thread mode does not use `connectionQoS`; `acceptQoS` is the priority of its thread.

```swift
let server = NanoHTTPServer()
server.configuration.threading = .singleThread
try server.run(8080)
```

## Timeouts and the number of connections

New defaults in `server.configuration`: `idleTimeout` 60 s, `readTimeout` 30 s, `writeTimeout` 30 s and
`maxConnections` 128. A client that is silent for a minute is disconnected, a request that stalls for 30 seconds gets
`408`, and the 129th simultaneous connection gets `503`. Raise or disable (`nil`) what does not fit, for example for
clients that keep many connections open for a long time:

```swift
let server = NanoHTTPServer()
server.configuration.idleTimeout = nil
server.configuration.maxConnections = 512
```

WebSocket sessions are not disconnected for being silent, but each one counts towards `maxConnections` and occupies a
thread.
