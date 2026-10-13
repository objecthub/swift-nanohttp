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

Describe what the change does and why, and mention behavior changes. CI (GitHub Actions) builds the package,
runs the tests (also under the address and thread sanitizers), builds the iOS demo, and runs the checks above.

## Security

Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in public issues.
