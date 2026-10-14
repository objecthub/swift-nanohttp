#!/usr/bin/env python3
"""Builds the DocC documentation of the NanoHTTP and NanoHTML targets and fails on warnings.

It checks that the catalogs (Sources/NanoHTTP/NanoHTTP.docc, Sources/NanoHTML/NanoHTML.docc) and the documentation comments build,
that every symbol and article link resolves, and that parameters documented in part are documented
completely.

    python3 Scripts/check_docs.py                       # build and check
    python3 Scripts/check_docs.py --output docs        # also keep the archives (docs/NanoHTTP.doccarchive, ...)

The archives can be opened in Xcode (File > Open) or served with `xcrun docc preview`.
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


MODULES = ("NanoHTTP", "NanoHTML")


def build(package, derived, module):
    """Builds the documentation of one module; returns (problems, archive or None, output text)."""
    result = subprocess.run(["xcodebuild", "docbuild", "-scheme", module,
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
    archives = [os.path.join(d, n) for d, ns, _ in os.walk(derived) for n in ns
                if n == module + ".doccarchive"]
    ok = result.returncode == 0 and bool(archives)
    return problems, (archives[0] if ok else None), text


def main() -> int:
    output = sys.argv[sys.argv.index("--output") + 1] if "--output" in sys.argv else None
    failed = False
    all_problems = []
    with tempfile.TemporaryDirectory() as directory:
        package = os.path.join(directory, "NanoHTTP")
        os.makedirs(os.path.join(package, "Tests", "NanoHTTPTests"))
        shutil.copy(os.path.join(ROOT, "Package.swift"), package)
        shutil.copytree(os.path.join(ROOT, "Sources"), os.path.join(package, "Sources"))
        # The manifest names the directories of the examples, which have to exist (nothing in them is built).
        shutil.copytree(os.path.join(ROOT, "Examples"), os.path.join(package, "Examples"))
        open(os.path.join(package, "Tests", "NanoHTTPTests", "Empty.swift"), "w").close()
        for module in MODULES:
            problems, archive, text = build(package, os.path.join(directory, "derived-" + module), module)
            if archive is None:
                print("\n".join(problems) or text[-3000:])
                print(f"error: the documentation of {module} does not build")
                failed = True
                continue
            if output:
                os.makedirs(output, exist_ok=True)
                target = os.path.join(output, module + ".doccarchive")
                shutil.rmtree(target, ignore_errors=True)
                shutil.copytree(archive, target)
            all_problems += problems
    if failed:
        return 1
    if all_problems:
        print("\n".join(all_problems))
        print(f"error: {len(all_problems)} documentation warnings")
        return 1
    print("the documentation builds without warnings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
