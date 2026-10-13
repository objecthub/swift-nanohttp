#!/usr/bin/env python3
"""Checks that NanoHTTP.xcodeproj references every Swift file (Sources/, Tests/, Package.swift) exactly once.

SwiftPM discovers files by itself, but the Xcode project (used for the iOS demo app and the
framework targets) lists them explicitly and has to be kept in sync by hand:

  * every .swift file below Sources/ and Tests/ (and Package.swift) must have exactly ONE file reference,
  * every Swift file reference must point at a file that exists,
  * every file reference must be compiled by exactly one build phase entry,
  * the deployment targets must match the platforms declared in Package.swift: the project-level
    settings and the library/test targets (NanoHTTP, NanoHTTPDemo, NanoHTTPTests) must be equal to
    them, the demo apps (DemoServer, DemoServer iOS) may be higher but not lower.

Files are matched by name; all Swift file names in this repository are unique.

    python3 Scripts/check_xcodeproj.py [path/to/project.pbxproj]
"""
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "NanoHTTP.xcodeproj", "project.pbxproj")
PACKAGE = os.path.join(ROOT, "Package.swift")
LIBRARY_TARGETS = {"NanoHTTP", "NanoHTTPDemo", "NanoHTTPTests"}
SETTINGS = {"macOS": "MACOSX_DEPLOYMENT_TARGET", "iOS": "IPHONEOS_DEPLOYMENT_TARGET",
            "tvOS": "TVOS_DEPLOYMENT_TARGET"}


def package_platforms():
    """{'macOS': (12, 0), ...} from the `platforms:` list of Package.swift."""
    with open(PACKAGE) as handle:
        text = handle.read()
    return {name: (int(major), int(minor or 0))
            for name, major, minor in re.findall(r"\.(macOS|iOS|tvOS)\(\.v(\d+)(?:_(\d+))?\)", text)}


def configuration_settings(text):
    """Yields (owner, deployment-target settings) for every build configuration."""
    owners = {}
    for match in re.finditer(r"/\* Build configuration list for (PBXNativeTarget|PBXProject) \"([^\"]+)\" \*/ = \{\s*isa = XCConfigurationList;\s*buildConfigurations = \((.*?)\);", text, re.S):
        kind, name, configurations = match.groups()
        for identifier in re.findall(r"(\w{24})", configurations):
            owners[identifier] = "<project>" if kind == "PBXProject" else name
    for identifier, body in re.findall(r"(\w{24}) /\* \w+ \*/ = \{\s*isa = XCBuildConfiguration;(.*?)\n\t\t\};", text, re.S):
        found = {key: tuple(int(part) for part in value.split("."))
                 for key, value in re.findall(r"(\w+_DEPLOYMENT_TARGET) = ([\d.]+);", body)}
        yield owners.get(identifier, "?"), found


def version(value):
    return ".".join(str(part) for part in value)


def swift_files_on_disk():
    found = collections.defaultdict(list)
    for name in os.listdir(ROOT):  # e.g. Package.swift, which the project lists as well
        if name.endswith(".swift"):
            found[name].append(name)
    for top in ("Sources", "Tests"):
        for directory, _, names in os.walk(os.path.join(ROOT, top)):
            for name in names:
                if name.endswith(".swift"):
                    found[name].append(os.path.relpath(os.path.join(directory, name), ROOT))
    return found


def main() -> int:
    project = sys.argv[1] if len(sys.argv) > 1 else PROJECT
    with open(project) as handle:
        text = handle.read()
    # id -> file name, for PBXFileReference entries of Swift files
    references = {}
    for match in re.finditer(r"^\s*(\w{24}) /\* [^*]+ \*/ = \{isa = PBXFileReference;[^}]*?path = \"?([^\";]+\.swift)\"?;", text, re.M):
        references[match.group(1)] = match.group(2)
    by_name = collections.defaultdict(list)
    for identifier, name in references.items():
        by_name[name].append(identifier)
    # file reference id -> number of build files compiling it
    compiled = collections.Counter(re.findall(r"isa = PBXBuildFile; fileRef = (\w{24})", text))

    disk = swift_files_on_disk()
    problems = []
    for name, paths in sorted(disk.items()):
        if len(paths) > 1:
            problems.append(f"ambiguous: several files are named {name}: {', '.join(paths)}")
        count = len(by_name.get(name, []))
        if count == 0:
            problems.append(f"missing in project: {paths[0]}")
        elif count > 1:
            problems.append(f"duplicate references ({count}) in project: {paths[0]}")
    for name in sorted(by_name):
        if name not in disk:
            problems.append(f"stale reference in project (file does not exist): {name}")
    for name, identifiers in sorted(by_name.items()):
        for identifier in identifiers:
            if compiled[identifier] > 1:
                problems.append(f"compiled more than once: {name}")
    wanted = package_platforms()
    for owner, found in configuration_settings(text):
        for platform, setting in SETTINGS.items():
            if setting not in found or platform not in wanted:
                continue
            actual, minimum = found[setting], wanted[platform]
            must_match = owner == "<project>" or owner in LIBRARY_TARGETS
            if (must_match and actual != minimum) or actual < minimum:
                problems.append(f"{setting} of {owner} is {version(actual)}, Package.swift declares "
                                f"{platform} {version(minimum)} ({'must be equal' if must_match else 'must not be lower'})")
    if problems:
        print("NanoHTTP.xcodeproj is out of sync with the source tree:")
        for problem in problems:
            print("  -", problem)
        print("Fix the project (or Package.swift) so both agree, and commit the change.")
        return 1
    print(f"NanoHTTP.xcodeproj is in sync: {len(disk)} Swift files, each referenced once; "
          f"deployment targets match Package.swift ({', '.join(f'{k} {version(v)}' for k, v in sorted(wanted.items()))}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
