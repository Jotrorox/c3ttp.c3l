# API performance comparison

For all four API versions versus Eclair, see the
[five-way comparison](five-way/README.md), including a runnable Eclair project,
larger route sets, memory measurements, and usability ratings.

The benchmark compares the original callback server at
`ce049990004207ef47ec6e0cfc01662a316ceb0e` with the new static route API. Both
serve `GET /health` as HTTP 200 with the same two-byte `ok` body and headers.
The new example registers four routes, with `/health` first.

A baseline was collected before changing the library. The final comparison
alternates the old and new binaries to reduce the effect of temperature and
CPU frequency drift. No parser, response framing, connection pool, or event-loop
code was changed. Registration and handler adaptation happen at compile time;
no route table, allocation, or reflection is added to request processing.

## Reproduce

Requires Linux, C3 0.8.3, Python 3, `taskset`, and `wrk`. From the repository root:

```sh
python3 benchmark/build.py
python3 benchmark/run.py \
  before=benchmark/out/before-server after=benchmark/out/after-server \
  --wrk /path/to/wrk --runs 7 --seconds 5 \
  --server-cpu 2 --client-cpus 4,5 \
  --output benchmark/out/comparison.json
```

`build.py` reads the baseline from Git into a temporary directory and builds
both revisions with `-O3`; it does not change the checkout. Override the baseline
with `--before-ref COMMIT`. Its source-based build also works with the original
revision's incomplete library manifest. Build metadata is saved under `out/`.

Choose allowed CPUs on separate physical cores on your machine. This run used
one server worker pinned to CPU 2, two wrk threads on CPUs 4 and 5, 2 or 64
keep-alive connections, a one-second warm-up before every sample, and seven
five-second samples per binary/workload. epoll and io_uring are forced separately;
there is no backend fallback in these measurements. The runner waits for the
previous listener to disappear before launching the next process. A backend startup failure,
wrong health response, non-2xx response, or socket error fails the run. Leave port
8080 free and avoid concurrent load while benchmarking.

The harness reports median throughput and fails when a median decrease exceeds
`--max-regression` (3% by default, a noise allowance rather than a guarantee).
Raw wrk output includes latency percentiles. The recorded backend batches were
collected separately after hardening the runner's io_uring listener cleanup and
readiness checks; each final batch includes all seven pairs per workload. Use `--backends epoll` when io_uring
is unavailable, and report that limitation with the results.

For the parser comparison, alternate these commands seven times, reversing their
order every other round:

```sh
taskset -c 2 benchmark/out/before-parser
taskset -c 2 benchmark/out/after-parser
```

Each process performs five million complete parses per case (GET, fixed-length
POST, chunked POST), using a monotonic clock and an observable result checksum.
Both binaries use the same `parser.c3` workload. The checksum must be 990000000.

## Recorded results

Measured on an Intel Core Ultra 5 125U using C3 0.8.3 / LLVM 22.1.8, Linux x64.
Full versions, CPU information, and wrk revision are in [environment.json](environment.json).

HTTP throughput medians (higher is better):

| Backend | Connections | Before (req/s) | After (req/s) | Change |
| --- | ---: | ---: | ---: | ---: |
| epoll | 2 | 157,028 | 156,903 | -0.08% |
| epoll | 64 | 270,972 | 271,855 | +0.33% |
| io-uring | 2 | 150,789 | 149,608 | -0.78% |
| io-uring | 64 | 327,925 | 334,347 | +1.96% |

Median of the per-run p99 latencies (lower is better):

| Backend | Connections | Before | After |
| --- | ---: | ---: | ---: |
| epoll | 2 | 15 µs | 16 µs |
| epoll | 64 | 350 µs | 351 µs |
| io-uring | 2 | 20 µs | 23 µs |
| io-uring | 64 | 249 µs | 265 µs |

Throughput changed by -0.78% to +1.96%, within the observed run-to-run
variation; no material throughput regression was detected in these workloads.
The p99 medians increased by 1–16 µs. The per-run latency ranges overlap
substantially (for io_uring at 64 connections: 210–537 µs before and 223–322 µs
after), but these measurements do not establish unchanged tail latency.
These were local laptop measurements with
CPU frequency scaling enabled, not a claim of a statistically proven speedup.
All timed HTTP samples completed without wrk socket or HTTP status errors.

Parser medians (lower is better):

| Complete request | Before | After | Change |
| --- | ---: | ---: | ---: |
| GET | 58.147 ns | 58.342 ns | +0.34% |
| Fixed-length POST | 87.228 ns | 87.283 ns | +0.06% |
| Chunked POST | 96.686 ns | 96.706 ns | +0.02% |

The parser binaries' entire `.text` sections are **byte-for-byte identical**
(SHA-256 `deedaee85cd4bf405d22860b0907d4e514f05390b299359024c4d90ba2b3bd07`).
The small timing differences therefore reflect measurement variability.

Raw measurements:

- [baseline-http.json](baseline-http.json): before-only runs collected before API edits.
- [comparison.json](comparison.json): final alternating HTTP measurements.
- [parser-comparison.json](parser-comparison.json): seven alternating parser pairs.

This is a local, single-worker, small-response throughput comparison. It does
not establish performance for large route sets, multi-worker scaling, large
responses, or every handler workload. Static route matching is linear in the
number of preceding routes. The original `serve()` API remains available for
custom dispatch. The functional suite separately checks response helpers,
queries, method matching, faults, HEAD, keep-alive, and borrowed-body pipelining.
