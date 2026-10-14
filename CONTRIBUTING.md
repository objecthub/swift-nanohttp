# Contributing

Thank you for your interest. Bug reports, fixes and ideas are welcome. [ARCHITECTURE.md](ARCHITECTURE.md) explains how the
package is put together; read it before you change the connection, the loops or the sockets.

## Build and test

```bash
swift build
swift test
swift test --sanitize=thread        # and --sanitize=address: both have to be clean
```

The tests start servers on free loopback ports; they do not need the network. `Tests/README.md` explains how
the suite is organized, how known bugs are recorded (`expectKnownIssue`), and the helpers for writing tests (a
raw socket client for the exact bytes of a request, `withTestServer`, fixtures).

## Rules

- **A change comes with a test.** For a bug fix, the test fails without the fix.
- **Performance does not get worse.** `python3 Benchmarks/run.py` compares the working copy with a release
  (see `Benchmarks/README.md`); run it for changes to the connection, parser, socket and response code.
- **Public API is documented** with `///` comments. Examples in the documentation are compiled
  (`python3 Scripts/check_doc_examples.py`), and the documentation has to build without warnings
  (`python3 Scripts/check_docs.py`).
- **The Xcode project is kept up to date.** Whenever a Swift file is added, removed or renamed, change
  `NanoHTTP.xcodeproj` too, and keep its deployment targets equal to those of `Package.swift`:
  `python3 Scripts/check_xcodeproj.py` checks it.
- **The examples keep running.** The programs in `Examples/` are Swift package targets only: they are not in the Xcode
  project, and `check_xcodeproj.py` does not look at them. `python3 Scripts/check_examples.py` builds them, runs each against
  real requests and checks that it stops on `SIGTERM` (`--sanitize=thread` runs them under the thread sanitizer). A
  feature that users will want to see belongs in an example if it fits one.
- **Both threading modes.** A feature gets tests with threads per connection and with one thread
  (`configuration.threading = .singleThread`), and the code that runs on the one thread must not need a lock.
- **Note it in the [CHANGELOG](CHANGELOG.md)**, under *Unreleased*, in the categories Added, Changed, Fixed, Removed or
  Security. Say what a user of the framework sees.
- Code style: two spaces of indentation and the style of the code around it.

## Pull requests

Describe what the change does and why, and mention behavior changes. The project has no continuous integration, so
run the checks yourself before you send a change:

1. `swift test`, `swift test --sanitize=address` and `swift test --sanitize=thread`: all green, no sanitizer reports.
2. The four checks of `Scripts/`: `check_xcodeproj.py`, `check_doc_examples.py`, `check_docs.py` and `check_examples.py`.
3. The Xcode builds: the scheme `NanoHTTP` and the scheme `NanoHTML` for the iOS and the tvOS simulator, `DemoServer iOS`
   (`-destination 'generic/platform=iOS Simulator'`), `DemoServer` and `NanoHTTPDemo`
   (`xcodebuild -project NanoHTTP.xcodeproj -scheme <scheme> -destination <destination> build`).
4. For a change to the connection, parser, socket, response or loop code: `python3 Benchmarks/run.py --baseline HEAD` (paired
   runs against the last commit; a release run takes about 12 minutes, see `Benchmarks/README.md`).

A long run on a laptop that is on battery can be interrupted by the machine going to sleep, which shows as tests that take
minutes and timing assertions that fail: plug it in, or start the run with `caffeinate -i -s <command>`.

## Version 1

Version 1 is maintained on the branch `release/1.x` until the end of 2027, with fixes for security problems and crashes
only (see [SECURITY.md](SECURITY.md)). A fix goes to `main` first and is then ported to `release/1.x`, with its test.

## Security

Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in public issues.
