#!/usr/bin/env python3
"""Builds the DocC documentation of the NanoHTTP target and fails on warnings.

It checks that the catalog (Sources/NanoHTTP/NanoHTTP.docc) and the documentation comments build,
that every symbol and article link resolves, and that parameters documented in part are documented
completely.

    python3 Scripts/check_docs.py                       # build and check
    python3 Scripts/check_docs.py --output NanoHTTP.doccarchive   # also keep the archive

The archive can be opened in Xcode (File > Open) or served with `xcrun docc preview`.
The build runs on a copy of the package without the Xcode project, so that `xcodebuild` treats it
as a Swift package.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> int:
    output = sys.argv[sys.argv.index("--output") + 1] if "--output" in sys.argv else None
    with tempfile.TemporaryDirectory() as directory:
        package = os.path.join(directory, "NanoHTTP")
        os.makedirs(os.path.join(package, "Tests", "NanoHTTPTests"))
        shutil.copy(os.path.join(ROOT, "Package.swift"), package)
        shutil.copytree(os.path.join(ROOT, "Sources"), os.path.join(package, "Sources"))
        open(os.path.join(package, "Tests", "NanoHTTPTests", "Empty.swift"), "w").close()
        derived = os.path.join(directory, "derived")
        result = subprocess.run(["xcodebuild", "docbuild", "-scheme", "NanoHTTP",
                                 "-destination", "generic/platform=macOS", "-derivedDataPath", derived],
                                cwd=package, capture_output=True, text=True)
        text = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout + "\n" + result.stderr)
        problems = []
        for line in text.splitlines():
            match = re.search(r"(?:" + re.escape(package) + r"/)?((?:Sources)/[^:\s]+:\d+:\d+): (warning|error): (.*?)(?: \(in target.*)?$", line)
            if match:
                entry = f"{match.group(1)}: {match.group(2)}: {match.group(3)}"
                if entry not in problems:
                    problems.append(entry)
        archives = [os.path.join(d, n) for d, ns, _ in os.walk(derived) for n in ns if n.endswith(".doccarchive")]
        if result.returncode != 0 or not archives:
            print("\n".join(problems) or text[-3000:])
            print("error: the documentation does not build")
            return 1
        if output:
            shutil.rmtree(output, ignore_errors=True)
            shutil.copytree(archives[0], output)
    if problems:
        print("\n".join(problems))
        print(f"error: {len(problems)} documentation warnings")
        return 1
    print("the documentation builds without warnings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
