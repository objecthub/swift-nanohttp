#!/usr/bin/env python3
"""Compares the throughput and latency of the current NanoHTTP with a release (or any commit).

    python3 Benchmarks/run.py                       # current code against the tag 1.0.2
    python3 Benchmarks/run.py --baseline 1.0.2 --repeats 8 --duration 3
    python3 Benchmarks/run.py --scenarios "keep-alive c=16,close c=1 (latency)"

It exports the baseline with `git archive`, builds a small server (identical routes) against it and against the
working copy, and drives each with `Benchmarks/loadgen` over the loopback interface. The servers are run
one after the other *within every repeat* (interleaved), because the same server measures 15% apart in
two runs minutes apart: only ratios of runs that were made back to back mean something.

Read the second table (paired ratios) first. See Benchmarks/README.md.
"""
import argparse, json, os, shutil, signal, socket, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WORK = os.path.join(HERE, ".work")

SCENARIOS = {
  # name: loadgen arguments
  "close c=1 (latency)":      ["/ping", "-c", "1"],
  "close c=16":               ["/ping", "-c", "16"],
  "close c=64":               ["/ping", "-c", "64"],
  "keep-alive c=1":           ["/ping", "-c", "1", "-k"],
  "keep-alive c=16":          ["/ping", "-c", "16", "-k"],
  "100 KB response c=4":      ["/blob/100k", "-c", "4"],
  "10 MB response c=1":       ["/blob/10m", "-c", "1"],
  "POST 1 MB c=4":            ["/upload", "-c", "4", "--post", "1048576"],
  "close c=1, 50 idle conns": ["/ping", "-c", "1", "--idle", "50"],
  "file 100 KB keep-alive c=4": ["/file/100k", "-c", "4", "-k"],
  "websocket echo c=1":       ["/ws", "-c", "1", "--ws"],
  "websocket echo c=16":      ["/ws", "-c", "16", "--ws"],
}

COMMON = """
import Foundation
import NanoHTTP

// The same routes for every version, so that only the framework differs.
let arguments = CommandLine.arguments       // benchserver MODE PORT
let mode = arguments[1]
let port = UInt16(arguments[2])!
let server = NanoHTTPServer()
var blobs = [String: Data]()               // created before the server starts, only read by the handlers
for (name, size) in [("1k", 1024), ("100k", 100 * 1024), ("1m", 1024 * 1024), ("10m", 10 * 1024 * 1024)] {
  blobs[name] = Data(repeating: 0x61, count: size)
}
server.get["/ping"] = { _ in .ok(.text("pong")) }
for name in ["1k", "100k", "1m", "10m"] {
  let blob = blobs[name]!
  server.get["/blob/\\(name)"] = { _ in .ok(.data(blob, contentType: "application/octet-stream")) }
}
server.post["/upload"] = { request in .ok(.text("\\(request.body.count)")) }
server["/ws"] = WEBSOCKET_HANDLER(text: { session, text in session.writeText(text) })
// A file of 100 KB, which `share(file:)` serves (a file that is closed after every response in 1.x).
let benchmarkFile = NSTemporaryDirectory() + "nanohttp-benchmark-100k.bin"
try? blobs["100k"]!.write(to: URL(fileURLWithPath: benchmarkFile))
server["/file/100k"] = SHARE_FILE(file: benchmarkFile)
"""

# NanoHTTP 1.x: listenAddressIPv4 and the parameters of start(); "serial" is handlerPriority: nil
# (the accept thread is at .userInitiated: the default of .background would run it on efficiency cores).
TAIL_1X = """
server.listenAddressIPv4 = "127.0.0.1"
try server.start(port, forceIPv4: true, priority: .userInitiated,
                 handlerPriority: mode == "serial" ? nil : .userInitiated)
RunLoop.main.run()
"""
# NanoHTTP 2.x: server.configuration
TAIL_2X = """
server.configuration.threading = mode == "single" ? .singleThread : .perConnection
try server.start(port)
RunLoop.main.run()
"""

def sh(*args, cwd=None, check=True, quiet=True):
    result = subprocess.run(args, cwd=cwd, capture_output=quiet, text=True)
    if check and result.returncode != 0:
        sys.exit(f"failed: {' '.join(args)}\n{result.stdout}\n{result.stderr}")
    return result

def has_namespaces(source_root):
    """Whether this version has `NanoFiles` and `NanoWebSocket` (2.0), or still the global `share` and `websocket`."""
    try:
        with open(os.path.join(source_root, "Sources", "NanoHTTP", "NanoFiles.swift")) as handle:
            return "enum NanoFiles" in handle.read()
    except OSError:
        return False

def build_server(name, source_root, uses_configuration):
    """Creates and builds a server package that depends on the NanoHTTP package at `source_root`."""
    directory = os.path.join(WORK, name)
    shutil.rmtree(directory, ignore_errors=True)
    os.makedirs(os.path.join(directory, "Sources", "benchserver"))
    package = os.path.basename(source_root.rstrip("/"))
    with open(os.path.join(directory, "Package.swift"), "w") as handle:
        handle.write(f'''// swift-tools-version:5.7
import PackageDescription
let package = Package(
  name: "{name}",
  platforms: [.macOS(.v12)],
  dependencies: [.package(path: "{source_root}")],
  targets: [.executableTarget(name: "benchserver", dependencies: [.product(name: "NanoHTTP", package: "{package}")])])
''')
    with open(os.path.join(directory, "Sources", "benchserver", "main.swift"), "w") as handle:
        common = COMMON
        if has_namespaces(source_root):
            common = common.replace("WEBSOCKET_HANDLER", "NanoWebSocket.handler").replace("SHARE_FILE", "NanoFiles.share")
        else:
            common = common.replace("WEBSOCKET_HANDLER", "websocket").replace("SHARE_FILE", "share")
        handle.write(common + (TAIL_2X if uses_configuration else TAIL_1X))
    print(f"building {name} ...", flush=True)
    sh("swift", "build", "-c", "release", cwd=directory)
    return os.path.join(directory, ".build", "release", "benchserver")

def cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return 0.0
    minutes, seconds = out.split(":")
    return int(minutes) * 60 + float(seconds)

def wait_listening(port, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return True
        except OSError:
            time.sleep(0.05)
    return False

next_port = [21000 + (os.getpid() % 1000) * 10]

def run_once(server, scenario, duration, warmup):
    binary, mode = server
    next_port[0] += 1
    port = next_port[0]
    process = subprocess.Popen([binary, mode, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not wait_listening(port):
            return {"error": "the server did not start"}
        for _ in range(20):  # warm up, not measured
            try:
                client = socket.create_connection(("127.0.0.1", port), timeout=2)
                client.sendall(b"GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                client.recv(4096)
                client.close()
            except OSError:
                pass
        before = cpu_seconds(process.pid)
        begin = time.time()
        out = subprocess.run([LOADGEN, str(port)] + SCENARIOS[scenario] + ["-d", str(duration), "-w", str(warmup), "--timeout", "2"],
                             capture_output=True, text=True, timeout=duration + warmup + 60)
        wall = time.time() - begin
        after = cpu_seconds(process.pid)
        result = json.loads(out.stdout)
        result["cpu_pct"] = 100.0 * (after - before) / wall
        requests = result["rps"] * (duration + warmup)
        result["cpu_us_per_req"] = 1e6 * (after - before) / requests if requests > 0 else None
        return result
    finally:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()

def median(runs, key):
    values = [r[key] for r in runs if r.get(key) is not None]
    return statistics.median(values) if values else None

def fmt(value, digits=0):
    return "-" if value is None else f"{value:,.{digits}f}"

def print_summary(scenario, results):
    print(f"\n### {scenario}")
    print(f"{'server':24} {'req/s':>9} {'MB/s':>8} {'p50 µs':>9} {'p99 µs':>9} {'max µs':>10} {'CPU µs/req':>11} {'errors':>7}")
    for name, runs in results.items():
        print(f"{name:24} {fmt(median(runs,'rps')):>9} {fmt(median(runs,'mbps'),1):>8} {fmt(median(runs,'p50_us')):>9} "
              f"{fmt(median(runs,'p99_us')):>9} {fmt(median(runs,'max_us')):>10} {fmt(median(runs,'cpu_us_per_req')):>11} "
              f"{fmt(median(runs,'errors')):>7}")

PAIRS = [("current", "{tag}"), ("current one-thread", "{tag} one-thread")]
METRICS = [("rps", "req/s", +1), ("p50_us", "p50 latency", -1), ("p99_us", "p99 latency", -1), ("cpu_us_per_req", "CPU/req", -1)]

def print_paired(all_results, tag):
    for a, b in PAIRS:
        b = b.format(tag=tag)
        print(f"\n=== {a} / {b}: median of the ratios of runs made back to back; 'wins' = repeats in which {a} was better")
        print(f"{'scenario':26}" + "".join(f"{label:>26}" for _, label, _ in METRICS))
        for scenario, results in all_results.items():
            cells = []
            for key, _, better in METRICS:
                ratios = [x[key] / y[key] for x, y in zip(results[a], results[b]) if x.get(key) and y.get(key)]
                if not ratios:
                    cells.append("-")
                    continue
                wins = sum(1 for q in ratios if (q >= 1 if better > 0 else q <= 1))
                cells.append(f"{statistics.median(ratios):5.2f}x  wins {wins:2d}/{len(ratios):2d}")
            print(f"{scenario:26}" + "".join(f"{c:>26}" for c in cells))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--baseline", default="1.0.2", help="a tag or commit of this repository (default: 1.0.2)")
    parser.add_argument("--scenarios", default="all", help="comma-separated names; all: %s" % ", ".join(SCENARIOS))
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--duration", type=float, default=3)
    parser.add_argument("--warmup", type=float, default=1)
    options = parser.parse_args()
    scenario_names = list(SCENARIOS) if options.scenarios == "all" else options.scenarios.split(",")
    for name in scenario_names:
        if name not in SCENARIOS:
            sys.exit(f"unknown scenario {name!r}")

    os.makedirs(WORK, exist_ok=True)
    # The export is named after the commit, not after the name that was given: `HEAD` and branches move.
    commit = subprocess.run(["git", "rev-parse", "--verify", "--quiet", options.baseline + "^{commit}"],
                            cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if not commit:
        sys.exit(f"{options.baseline!r} is no commit of this repository")
    print(f"baseline: {options.baseline} = {commit[:12]}", flush=True)
    baseline = os.path.join(WORK, "baseline-" + commit[:12])
    if not os.path.isdir(baseline):
        os.makedirs(baseline)
        archive = subprocess.Popen(["git", "archive", options.baseline], cwd=ROOT, stdout=subprocess.PIPE)
        subprocess.run(["tar", "-x", "-C", baseline], stdin=archive.stdout, check=True)
        if archive.wait() != 0:
            shutil.rmtree(baseline)
            sys.exit(f"git archive {options.baseline} failed")
    baseline_uses_configuration = "struct Configuration" in open(os.path.join(baseline, "Sources/NanoHTTP/NanoHTTPServerIO.swift")).read()
    sh("swift", "build", "-c", "release", cwd=os.path.join(HERE, "loadgen"))
    LOADGEN = os.path.join(HERE, "loadgen", ".build", "release", "loadgen")
    baseline_binary = build_server("baseline-server", baseline, baseline_uses_configuration)
    current_binary = build_server("current-server", ROOT, True)
    tag = options.baseline
    servers = {
      tag:                     (baseline_binary, "single" if False else ("threads")),
      f"{tag} one-thread":     (baseline_binary, "single" if baseline_uses_configuration else "serial"),
      "current":               (current_binary, "threads"),
      "current one-thread":    (current_binary, "single"),
    }
    all_results = {}
    for scenario in scenario_names:
        results = {name: [] for name in servers}
        for repeat in range(options.repeats):
            # The order alternates: a machine that slows down (or speeds up) during a repeat would otherwise
            # favor the server that always runs first.
            order = list(servers.items())
            if repeat % 2 == 1:
                order.reverse()
            runs = {}
            for name, server in order:
                runs[name] = run_once(server, scenario, options.duration, options.warmup)
            for name in servers:
                results[name].append(runs[name])
        all_results[scenario] = results
        print_summary(scenario, results)
        sys.stdout.flush()
    print_paired(all_results, tag)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    with open(os.path.join(WORK, f"results-{stamp}.json"), "w") as handle:
        json.dump(all_results, handle, indent=1)
    print(f"\nraw results: Benchmarks/.work/results-{stamp}.json")
