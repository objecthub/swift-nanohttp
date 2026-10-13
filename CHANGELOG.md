# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Test harness: servers on ephemeral loopback ports, a raw-socket HTTP/WebSocket client,
  file-descriptor and leak helpers (`Tests/NanoHTTPTests/Support`).
- More than 130 new tests: security, robustness, HTTP protocol, request parsing, router behavior,
  WebSocket end-to-end, HTML builder. Defects that are known but not yet fixed are recorded as
  *expected failures* (see `Tests/README.md`), so the suite is green and flips red when one is fixed.
- Continuous integration (GitHub Actions): build and test, coverage summary, Address/Thread
  sanitizer runs, iOS demo app build.
- `Scripts/check_xcodeproj.py` (run in CI): fails when a Swift file is missing from, duplicated in or
  stale in `NanoHTTP.xcodeproj`. The new test files were added to the project; duplicate references to
  `IOSafetyTests`, `PingServer` and `ServerThreadingTests` were removed.

- `followSymlinks` parameter for `share(directory:defaults:followSymlinks:)` and
  `browse(directory:followSymlinks:)` (default `false`): serve symbolic links even if they lead out of
  the shared directory. Links that stay inside the directory are always followed.

### Changed
- Existing tests no longer use fixed ports (8080, 9081), no longer ignore bind failures, and the
  flaky `testShouldHandleTheSameRequestConcurrently` waits for all of its requests.
- README: removed the Linux claim (the package never built there; it uses CryptoKit and
  UniformTypeIdentifiers), listed tvOS (declared in `Package.swift`), corrected the license badge
  (BSD 3-Clause, not Apache).

- **Minimum deployment targets raised to macOS 12, iOS 15 and tvOS 15** (`Package.swift` and the Xcode
  project, kept in sync; `Scripts/check_xcodeproj.py` enforces it). Current Xcode versions no longer
  support the previous minimums (macOS 11, iOS 14, tvOS 14), so the Xcode project did not build.
  This is a source-compatibility change for clients that still target the older systems.

### Removed
- Carthage: dropped from the README (badge and requirements) and the `.gitignore` template block.
  No `Cartfile` or shared framework scheme ever existed, so Carthage could not build the package;
  Swift Package Manager is the supported way to depend on NanoHTTP.

### Fixed
- `share(file:)` and `share(directory:defaults:followSymlinks:)` sent the length of a symbolic link
  (the length of its target path) as `Content-Length` instead of the size of the file it points to.
  Linked files longer than that were truncated, shorter ones left clients waiting.

### Security
- `share(directory:defaults:)` and `browse(directory:)` no longer serve files outside the shared
  directory. Requests with `..` segments (also percent-encoded), NUL characters, or paths that lead
  out of the directory through symbolic links are answered with `403 Forbidden`. Symbolic links that
  stay inside the directory, and shared directories that are themselves symbolic links, keep working.

## [1.0.1] - 2024-08-09

### Fixed
- Computation of the local IP address (`NetworkInterface.localIP`).

## [1.0] - 2024-08-08

First release (replaces the former `0.1 (2024-07-19)` entry, which was never tagged).

### Added
- HTTP/1.1 server (`NanoHTTPServer`) based on Swifter, with keep-alive and a pluggable router
  (`NanoHTTPRouter`, default `NanoHTTPSegmentRouter` with `:var`, `::pathvar`, `*` and `**`
  placeholders and sub-router mounting; empty matches for path variables).
- Responses that force closing the connection (`dontKeepAlive`).
- WebSocket support, file sharing (`share`, `browse`), HTML builder (`NanoHTML`).
- `NetworkInterface` and `NetworkInterface.localIP`; the demo servers log the URL under which
  they are reachable.
- Swift Package Manager support; demo server for macOS (command line) and iOS (SwiftUI app).

[Unreleased]: https://github.com/objecthub/swift-nanohttp/compare/1.0.1...HEAD
[1.0.1]: https://github.com/objecthub/swift-nanohttp/compare/1.0...1.0.1
[1.0]: https://github.com/objecthub/swift-nanohttp/releases/tag/1.0
