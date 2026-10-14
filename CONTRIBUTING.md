# Contributing

Thank you for your interest. Bug reports, fixes and ideas are welcome.

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
- **Note it in the [CHANGELOG](CHANGELOG.md)**, under *Unreleased*, in the categories Added, Changed, Fixed, Removed or
  Security. Say what a user of the framework sees.
- Code style: two spaces of indentation and the style of the code around it.

## Pull requests

Describe what the change does and why, and mention behavior changes. The project has no continuous integration, so
run the checks yourself before you send a change: the tests, also under the address and thread sanitizers, the three
`Scripts/check_*.py` scripts above, and a build of the iOS demo
(`xcodebuild -project NanoHTTP.xcodeproj -scheme "DemoServer iOS" -destination 'generic/platform=iOS Simulator' build`).

## Version 1

Version 1 is maintained on the branch `release/1.x` until the end of 2027, with fixes for security problems and crashes
only (see [SECURITY.md](SECURITY.md)). A fix goes to `main` first and is then ported to `release/1.x`, with its test.

## Security

Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in public issues.
