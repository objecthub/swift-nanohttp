#!/usr/bin/env python3
"""Compiles the Swift examples of the documentation, so that they cannot go stale.

Every fenced code block whose info string is exactly `swift` in

  * README.md and the other Markdown files of the repository root,
  * the articles of the DocC catalogs (Sources/NanoHTTP/NanoHTTP.docc, Sources/NanoHTML/NanoHTML.docc), and
  * the documentation comments (`///`) of the Swift sources

is compiled against the library. Blocks with another info string (`bash`, `text`, `swift nocompile`,
...) are not. Errors point at the line of the Markdown file or Swift source that contains the example.

A block is wrapped into a function and must be self-contained: it declares what it uses
(`let server = NanoHTTPServer()`), and may `import` frameworks. A block that declares types or
extensions has to start with the comment line `// file scope`. A block that uses `await` is wrapped
into an `async` function. The examples are only compiled, never run.

    python3 Scripts/check_doc_examples.py            # all examples
    python3 Scripts/check_doc_examples.py --list     # only list the examples
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FENCE = re.compile(r"^(\s*)```(.*)$")


def sources():
    """Yields (relative path, lines, is_swift_source) for everything that may contain examples."""
    for name in sorted(os.listdir(ROOT)):
        if name.endswith(".md"):
            yield name, False
    for module in ("NanoHTTP", "NanoHTML"):
        catalog = os.path.join(ROOT, "Sources", module, module + ".docc")
        if os.path.isdir(catalog):
            for name in sorted(os.listdir(catalog)):
                if name.endswith(".md"):
                    yield os.path.join("Sources", module, module + ".docc", name), False
    for top in ("Sources",):
        for directory, _, names in sorted(os.walk(os.path.join(ROOT, top))):
            for name in sorted(names):
                if name.endswith(".swift"):
                    yield os.path.relpath(os.path.join(directory, name), ROOT), True


def examples():
    """Yields (path, line number of the first code line, code) for every compiled block."""
    for path, is_swift in sources():
        with open(os.path.join(ROOT, path)) as handle:
            lines = handle.read().split("\n")
        current = None
        for number, raw in enumerate(lines, 1):
            line = raw
            if is_swift:
                stripped = raw.lstrip()
                if not stripped.startswith("///"):
                    current = None
                    continue
                line = stripped[3:]
                if line.startswith(" "):
                    line = line[1:]
            match = FENCE.match(line)
            if match and current is None:
                info = match.group(2).strip()
                current = {"compile": info == "swift", "start": number + 1, "code": []}
            elif match and current is not None:
                if current["compile"]:
                    yield path, current["start"], "\n".join(current["code"])
                current = None
            elif current is not None and current["compile"]:
                current["code"].append(line)


def wrap(index, path, start, code):
    """The Swift source for one example."""
    lines = code.split("\n")
    imports = [l for l in lines if l.startswith("import ")]
    body = [l for l in lines if not l.startswith("import ")]
    location = f'#sourceLocation(file: "{path}", line: {start})'
    if body and body[0].strip() == "// file scope":
        return imports, f"{location}\n" + "\n".join(body) + "\n#sourceLocation()\n"
    keyword = "async throws" if re.search(r"\bawait\b", code) else "throws"
    return imports, (f"func example{index}() {keyword} {{\n{location}\n" + "\n".join(body)
                     + "\n#sourceLocation()\n}\n")


def main() -> int:
    found = list(examples())
    if "--list" in sys.argv:
        for path, start, code in found:
            print(f"{path}:{start}: {len(code.splitlines())} lines")
        print(f"{len(found)} examples")
        return 0
    imports = {"import Foundation", "import NanoHTTP", "import NanoHTML"}
    pieces = []
    for index, (path, start, code) in enumerate(found):
        found_imports, text = wrap(index, path, start, code)
        imports.update(found_imports)
        pieces.append(text)
    with tempfile.TemporaryDirectory() as directory:
        os.makedirs(os.path.join(directory, "Sources", "DocExamples"))
        with open(os.path.join(directory, "Package.swift"), "w") as handle:
            handle.write(f"""// swift-tools-version:5.7
import PackageDescription
let package = Package(
  name: "DocExamples",
  platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15)],
  dependencies: [.package(path: "{ROOT}")],
  targets: [.target(name: "DocExamples", dependencies: [.product(name: "NanoHTTP", package: "{os.path.basename(ROOT)}"),
                                                       .product(name: "NanoHTML", package: "{os.path.basename(ROOT)}")])])
""")
        with open(os.path.join(directory, "Sources", "DocExamples", "Examples.swift"), "w") as handle:
            handle.write("\n".join(sorted(imports)) + "\n\n" + "\n".join(pieces))
        result = subprocess.run(["swift", "build"], cwd=directory, capture_output=True, text=True)
        if result.returncode != 0:
            # Only the diagnostics: the output also contains the (very long) compiler command lines.
            plain = re.sub(r"\x1b\[[0-9;]*m", "", result.stdout + "\n" + result.stderr)  # colors
            diagnostics = [line[:400] for line in plain.splitlines()
                           if re.search(r"\d+:\d+: error:", line) and "swift-frontend" not in line]
            print("\n".join(dict.fromkeys(diagnostics)) or (result.stdout + result.stderr)[-3000:])
            print(f"error: the documentation examples do not compile ({len(found)} examples)")
            return 1
    print(f"all {len(found)} documentation examples compile")
    return 0


if __name__ == "__main__":
    sys.exit(main())
