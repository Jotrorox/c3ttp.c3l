# Memory and resource comparison

> Historical measurements are preserved in this report. Raw benchmark results,
> generated tables, charts, and logs are no longer versioned. Artifact filenames
> below identify local outputs or historical records; use the reproduction
> commands to collect fresh results.

This extends the template experiment's three-way comparison to process memory,
connection scaling, retained memory, and CPU consumption. It uses the **same
12 binaries** as the throughput comparison: `main`, the starting inventory branch,
and `experiment/templated-routes`, with four literal routes or 4/32/100 mixed routes.
Every binary's SHA-256 is checked against the earlier build manifest before use.
The older branches still use equivalent handwritten matching for dynamic paths.
No library source or pool configuration is changed for these measurements.

## What is measured

Three fresh-process repetitions rotate implementation order for every fixture and
backend: 72 measured load runs in total. The server has one worker pinned to CPU 2,
64 wrk connections on CPUs 4 and 5, and a separate monitor/client on CPU 6.
A readiness request precedes the idle snapshot. Each load run has a one-second
warmup and three measured seconds, with memory sampled every 200 ms. The last
registered route is requested in mixed fixtures; the literal fixture uses `/health`.
The endpoint's status and response body are checked before load, and wrk socket
errors, non-2xx responses, or server exits invalidate a run.

The 100-route fixtures additionally run two probes in each repetition/backend:

1. **Request growth:** 1,000 warmup requests, followed by 100,000 verified requests
   on one persistent connection, sampled every 10,000 requests. Targets alternate
   between one/two captures, the last route, queries, raw encoded delimiters,
   empty captures, late misses, a missing path, and a literal route. This totals
   1.8 million verified measured requests across the three implementations.
2. **Connections and buffers:** a separate fresh process grows from 1 to 64, 256,
   512, and 1,024 persistent connections. Every connection exchanges a validated
   small request. At full capacity, each receives a GET with a **24 KiB body**;
   the handler returns the same small response after the parser consumes the body.
   All clients close, descriptors must return to their initial count, and a second
   1,024-connection/body cycle checks whether retained memory grows again.

The fresh connection process makes its curve independent of pages touched by the
preceding 64-connection load. Connections remain open between increasing count
steps, so each point is a cumulative occupancy measurement. Connection and growth
probes are correctness/resource tests, not throughput tests.

## Metrics and interpretation

- **RSS:** resident pages mapped by the process, including shared library/code
  pages. Taken from `/proc/PID/smaps_rollup`, which avoids the batching of the
  cheaper `/proc/PID/status` RSS counters.
- **USS:** private clean plus private dirty resident pages (and private huge pages
  if present). This helps distinguish application residency from shared code.
- **PSS:** shared pages divided among the processes mapping them. Retained in raw
  data; other processes on this host can change the shared-page accounting.
- **Virtual size:** mapped address space, including reserved, untouched buffers.
  It is not a measurement of physical RAM consumption.
- **Peak RSS/USS:** maximum of the 200 ms samples during measured load. Shorter
  transients can be missed. The kernel's process-lifetime VmHWM and VmPeak are
  recorded separately, including their coarser accounting limitations.
- **CPU per request:** server user plus system CPU ticks divided by completed wrk
  requests. The clock tick is 10 ms on this host. Load-generator/monitor CPU and
  kernel work charged elsewhere are excluded. These instrumented runs should not
  replace the earlier uninstrumented throughput results.

Raw data also includes anonymous/shared pages, swap, minor/major page faults,
voluntary/involuntary context switches, thread counts, and open FD/socket counts.
All figures describe the server process, **not total system memory**: kernel TCP
socket buffers, kernel-only io_uring structures, clients, and the monitor are not
fully included. There is no per-allocation tracing; flat RSS/USS alone does not
prove the absence of every leak. These are bounded tests on a shared laptop.

Every worker preallocates capacity for 1,024 connections and 32 KiB receive buffers
per slot: **32 MiB of receive-buffer address space**, plus connection/parser state,
code, and backend structures. Allocation at startup does not require all pages to
be resident immediately. Larger requests touch more pages; closing sockets leaves
the pool available for reuse. Retained buffer pages therefore need to be compared
with the second cycle before treating a post-close RSS increase as a leak.

## Results

Memory use is essentially unchanged by templated routing in these fixtures.
At 100 routes and 64 active connections, the new branch's peak private memory
is only **16–20 KiB above** the two baselines, depending on backend. RSS differences
are somewhat larger and include variation in shared/code residency; they should
not be read as pure router heap costs.

Median resident memory for **100 mixed routes**, MiB:

| Backend / implementation | Idle | Peak at 64 connections | 1,024 small requests | 1,024 × 24 KiB bodies | After closing all |
| --- | ---: | ---: | ---: | ---: | ---: |
| epoll / main | 6.68 | 6.92 | 10.73 | 34.73 | 34.73 |
| epoll / starting branch | 6.79 | 7.03 | 10.73 | 34.73 | 34.73 |
| epoll / templates | 6.68 | 6.93 | 10.80 | 34.80 | 34.80 |
| io_uring / main | 7.06 | 7.31 | 11.12 | 35.12 | 35.12 |
| io_uring / starting branch | 7.18 | 7.43 | 11.18 | 35.18 | 35.18 |
| io_uring / templates | 7.13 | 7.38 | 11.14 | 35.14 | 35.14 |

Idle/load and connection figures come from independent fresh-process trials;
small differences between their starting footprints are expected.

The main growth comes from **touched receive-buffer pages**. Increasing to 1,024
small requests adds roughly 4 MiB of private residency. Sending 24 KiB bodies at
that capacity adds another 24 MiB. The higher memory remains after close because
the pool remains allocated. The second full-capacity/body cycle adds **0 KiB of
private memory in every repetition**, consistent with pool reuse.

All **18 sustained-request probes** show **0 KiB RSS growth and 0 KiB USS growth**
at every 10,000-request checkpoint after warmup. There are **72 successful runs,
zero failed runs, 63,674,485 measured load requests, and 1,800,000 verified growth
requests**. Open descriptors rise from **5 to 1,029** at full capacity and return
to **5** after both close cycles in every implementation/backend. Warmed measured
load incurs **zero minor faults, zero major faults, and zero swap** in these runs.

CPU usage is also close, but is not identical. For the last route in 100 routes,
server CPU microseconds per request are:

| Backend | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| epoll | 2.568 | 2.526 | 2.538 |
| io_uring | 1.774 | 1.779 | 1.832 |

The template fixture charges about 3% more CPU per request on io_uring in this
instrumented 100-route workload. These short runs are not precise hardware-cycle
benchmarks; absolute costs and the underlying CPU ticks are retained for review.
Route-count scaling from 4 to 100 is modest in memory because it adds generated
code rather than another per-connection route registry. The library's fixed pools
remain the dominant cost, and these measurements cover **one worker** only.

See complete memory tables (`memory-tables.md`), raw samples (`memory-results.json`),
and machine-readable summary (`memory-summary.json`). Tables report medians; the
raw samples and summary retain observed ranges. No failed run is included in a
median.

Generated chart (local output): `memory.svg`.

## Reproduce

Run after building the three-way fixtures in the parent experiment:

```sh
python3 benchmark/templates/compare.py --wrk /path/to/wrk --build-only \
  --output /tmp/c3ttp-template-build.json
python3 benchmark/templates/memory.py --wrk /path/to/wrk \
  --manifest /tmp/c3ttp-template-build.json
python3 benchmark/templates/summarize_memory.py --plot
```

If the earlier throughput binaries still exist and match their recorded hashes,
run `memory.py` directly with its default `results.json` manifest, as done here.
The memory run records the complete build identities rather than depending only
on paths to temporary binaries. C3 0.8.3, Python 3, Linux procfs, taskset, and wrk
are needed; matplotlib is optional for regenerating the SVG. Choose valid CPU IDs
with `--server-cpu`, `--client-cpus`, and `--monitor-cpu`. `--backends epoll` skips
io_uring where unavailable. Port 8080 must be free, and the client needs at least
1,056 available file descriptors for the default full-capacity test.

A short harness check is:

```sh
python3 benchmark/templates/memory.py --wrk /path/to/wrk --runs 1 --seconds 1 \
  --requests 1000 --sample-requests 100 --labels templates --fixtures mixed-100 \
  --output /tmp/c3ttp-memory-smoke/results.json
```
