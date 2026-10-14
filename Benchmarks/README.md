# Benchmarks

Compares the throughput, latency and CPU use of the working copy of NanoHTTP with a release or any commit, to
find out whether a change made the server slower.

```bash
python3 Benchmarks/run.py                                  # the working copy against the tag 1.0.2
python3 Benchmarks/run.py --baseline 1.0.2 --repeats 8 --duration 3
python3 Benchmarks/run.py --scenarios "keep-alive c=16,close c=1 (latency)"
```

The baseline can be any tag or commit (`HEAD`, `main~3`, a hash); the commit it names is printed. It needs a few minutes per scenario (every repeat runs four servers) and an otherwise idle machine. Nothing is
installed: the baseline is exported with `git archive` into `Benchmarks/.work/`, and a small server with the same
routes is built (in release mode) against the baseline and against the working copy. `Benchmarks/loadgen` is the
client: a compiled load generator with one thread per connection that reports requests per second, latency
percentiles and errors.

## The four servers

| Name | What |
|---|---|
| *baseline* (e.g. `1.0.2`) | the default: a thread per connection |
| *baseline* `one-thread` | 1.x: `handlerPriority: nil`, 2.x: `.singleThread` |
| `current` | the working copy, a thread per connection |
| `current one-thread` | the working copy with `threading = .singleThread` |

The accept thread of 1.x runs at `.userInitiated`, not at the 1.x default `.background`, which the system may run on
the slow cores: the comparison would flatter the working copy otherwise.

## Scenarios

`close` opens a new connection for every request (`Connection: close`), `keep-alive` reuses connections, `cN` is the
number of client threads. The responses are `pong` (4 bytes), 100 KB and 10 MB; the POST has a 1 MB body.
`file 100 KB keep-alive` serves a file of 100 KB with `share(file:)` (1.x closed the connection after every file; a
client reconnects without counting that as an error). `close c=1 with 50 idle conns` holds 50 connections open that send nothing. `websocket echo` opens one WebSocket per
client thread and sends 16-byte messages one after the other, each of which the server echoes; 1.x servers with one
thread serve only one of the sockets (a WebSocket held the thread), which shows as errors.

## A release run in about 15 minutes

A scenario costs `repeats x 4 x (duration + warmup + about 0.5 s)`, so all 12 scenarios at the defaults take about 25
minutes for 7 repeats. The scenarios whose ratios hardly vary need few repeats; only the ones that open a connection
for every request (which are bimodal) need many. Two runs, one after the other, on an idle machine:

```bash
python3 Benchmarks/run.py --baseline 1.0.2 --repeats 5 --duration 2 --warmup 0.5 \
  --scenarios "keep-alive c=1,keep-alive c=16,100 KB response c=4,10 MB response c=1,POST 1 MB c=4,file 100 KB keep-alive c=4,websocket echo c=1,websocket echo c=16"
python3 Benchmarks/run.py --baseline 1.0.2 --repeats 8 --duration 2 --warmup 0.5 \
  --scenarios "close c=1 (latency),close c=16,close c=1 with 50 idle conns"
```

`close c=64` is left out: its connection errors come from the load generator, for every server.

## Reading the result

**Look at the second table, the paired ratios.** The same server measures up to 15% apart in two runs a few minutes
apart (cores, clock speeds, other processes), and bimodal in the latency of single requests, so absolute numbers of
different runs mean little. Every repeat runs all four servers one after the other (in the opposite order in every second repeat), and the
ratio is taken between runs that were made back to back. A ratio of 0.97 with 3 wins out of 8 is noise; 0.95 with 0 wins out of 8 is a
real difference of 5%. Use at least 8 repeats for such small differences.

- **Connection-per-request scenarios are bimodal.** On the machine of the author, `close c=16` runs either at about
  2,050 or at about 2,650 requests per second, and every server lands in the one or the other at random (7 of 20
  runs in the slow state, for two builds that are the same in this respect). A difference of 15% in the median of
  8 repeats can be luck: compare 20 or more repeats there, or look at the median of the fast state.
- *req/s*: higher is better; *latency* and *CPU/req* (microseconds of CPU time of the server per request): lower.
- 1.x `one-thread` serves one connection at a time and starves the other connections of a keep-alive load, so its
  latency at `keep-alive c=16` is that of the one connection that is served, and a comparison of latencies there is
  meaningless; compare the throughput.

## What it does not measure

Only the loopback interface (no network), only small numbers of connections, no TLS (there is none), and the
client shares the machine with the server. The client closes short-lived connections with a reset (`SO_LINGER`),
so that tens of thousands of them do not use up the ephemeral ports in `TIME_WAIT`; that is the same for all servers.
