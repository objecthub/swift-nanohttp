#!/usr/bin/env python3
"""Prints per-file line coverage of Sources/NanoHTTP from SwiftPM's code-coverage JSON.

    swift test --enable-code-coverage
    python3 Scripts/coverage_summary.py "$(swift test --show-codecov-path)" [--min PERCENT]

With --min the script exits non-zero if total line coverage is below PERCENT.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    minimum = None
    if "--min" in sys.argv:
        minimum = float(sys.argv[sys.argv.index("--min") + 1])
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
    rows = []
    for entry in data["data"][0]["files"]:
        marker = "/Sources/NanoHTTP/"
        if marker not in entry["filename"]:
            continue
        lines = entry["summary"]["lines"]
        rows.append((entry["filename"].split(marker)[1], lines["covered"], lines["count"], lines["percent"]))
    covered = sum(row[1] for row in rows)
    total = sum(row[2] for row in rows)
    for name, hit, count, percent in sorted(rows, key=lambda row: row[3]):
        print(f"{name:<34} {hit:>5}/{count:<5} {percent:6.1f}%")
    overall = 100.0 * covered / total if total else 0.0
    print(f"{'TOTAL (Sources/NanoHTTP)':<34} {covered:>5}/{total:<5} {overall:6.1f}%")
    if minimum is not None and overall < minimum:
        print(f"error: line coverage {overall:.1f}% is below the required {minimum:.1f}%")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
