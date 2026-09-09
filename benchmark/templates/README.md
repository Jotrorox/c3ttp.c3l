# Templated route experiment

`experiment/templated-routes` adds compile-time whole-segment parameters to the
existing route inventories and annotations:

```c3
fn String? number(RouteParams* params) @Get("/get-number-back/{number}")
{
    return params.get("number");
}
// In main:
Server server = c3ttp::@server(number);
```

`GET /get-number-back/5` returns `5`. Matching borrows the raw segment, so `0005`
and `%2F` are preserved, and query strings are excluded. This syntax describes a
segment, not a numeric type constraint. Applications can validate or convert it
before responding. The [public API documentation](../../README.md#templated-routes-experiment)
covers grammar, ordering, errors, and lifetimes.

## Design

The registration macro parses each template once at compile time into literal
runs and capture names. It emits direct literal comparisons, bounded scans to the
next slash or query delimiter, and a direct handler call. Literal-only routes
continue to use the previous exact-target/query-boundary matcher. No runtime
route registry, template parsing, heap allocation, or `RequestView` fields are
introduced.

Each template has at most eight named captures. A handler can accept
`RouteParams*` in any argument position alongside request, response, and context.
The container uses fixed stack storage; `get(name)` returns a borrowed `String?`.
The container pointer expires when the handler returns, but a captured value can
be returned as a response body because it points into the existing request buffer.
Only entries below `count` may be read. Candidate capture storage deliberately
skips default initialization; the matcher writes every exposed name/value and
`count` before invoking a handler. This avoids clearing unused slots for every
candidate, without relying on compiler optimization for correctness.

Registration order determines precedence, including overlaps between literal and
template routes. Put special cases first. Identical method/template shapes are
rejected even when their capture names differ. Other overlaps are allowed and
ordered. Empty captures, malformed braces, embedded captures, invalid identifiers,
repeated names, and more than eight captures are rejected or fail to match as
appropriate. Unmatched methods/paths still return 404. Wildcards, regexes, decoding,
typed binding, and automatic 405 responses are outside this experiment.

The dispatcher remains a linear scan, and duplicate checking is quadratic in
route count. This experiment checks up to 100 routes; it does not establish
thousand-route scalability or production readiness. Braces in route declarations
now have reserved meaning, a compatibility change for applications registering
raw literal braces.

## Comparison method

The pinned baselines are:

- `main`: `ce049990004207ef47ec6e0cfc01662a316ceb0e`.
- Starting branch: `experiment/explicit-route-annotations` at `19fb56d`.
- New implementation: the working tree on `experiment/templated-routes`, captured
  with a SHA-256 for every library source and generated fixture.

Both older branches lack template matching. The literal fixture uses main's
handwritten dispatcher and each experiment's native inventory API. The mixed
fixtures add equivalent handwritten segment matchers to both baseline applications;
the libraries themselves are unchanged. The starting branch uses its native
inventory for `/health`, reached through the handwritten wrapper. All versions
preserve route order, raw captures, query boundaries, method checks, and 404s.
Thus mixed results compare the convenience API against application code doing
similar work, not against nonexistent native template APIs on the older branches.

Fixtures have four literal routes, or 4/32/100 mixed routes. Mixed fixtures register
`/health`, `/get-number-back/{number}`, `/users/{user}/posts/{post}`, then numbered
`/route/NNN/{value}` routes. Bodies are identical for every measured request.
The 32-route workload requests the final route. The 100-route fixture measures
compilation and validates every endpoint; it is not an HTTP throughput workload.

All builds use the installed C3 0.8.3 compiler and `-O3`. One worker runs on CPU 2,
with two wrk threads on CPUs 4 and 5 over loopback at 64 connections. Each fresh
server warms for one second and is measured for three seconds. Five repetitions
rotate implementation order. epoll covers every workload, and the one-capture
workload additionally uses io_uring. Compilation, validation, and microbenchmarks
finish before HTTP timing begins.

The separate dispatch loop uses a runtime command-line target, a non-inlined
callback wrapper, ten million calls per sample, and a verified response checksum.
Its measurements include the common wrapper/checksum costs and are not isolated
instruction latencies. It includes a late template miss as well as successful
matches. Fixed repeated targets favor CPU prediction; these tests do not model
random production traffic.

Each fixture/backend also checks varying requests on one persistent connection,
wrong methods, misses, and raw captures, then 5,000 repeated requests with RSS
read before and after. The test suite separately covers pipelined response lifetimes.
The benchmark rejects wrk socket errors, non-2xx responses, or server exits and
retains any failed samples. These are short laptop measurements with frequency
scaling and background activity, so small differences should not be treated as
proven gains or regressions. RSS stability alone does not prove absence of leaks;
the no-allocation claim also follows from the matching implementation.

## Verification

All 34 unit tests pass in debug and optimized builds on C3 0.8.3, and optimized
builds also pass on the locally available 0.8.4 prerelease. This includes 10,000
deterministic comparisons against an independent segment-splitting oracle,
all eight capture slots, raw borrowed addresses, missing names, optional handlers,
all four injected argument types, suffixes, query boundaries, and overlap order.
All 51 compile-failure cases pass, including 12 new template diagnostics.
Both epoll and io_uring pass 19 HTTP cases and two pipelining checks apiece.
The existing 100-route inventory test also passes.

## Results

All six HTTP throughput medians are within **1.3% of both baselines** on this
host. For `/get-number-back/5`, epoll reaches **262,692 req/s** versus 263,043
on main and 260,609 on the starting branch. io_uring reaches **334,298 req/s**
versus 336,405 and 337,313 respectively. The two-capture endpoint is about 1.2%
lower than both baselines; the final match in 32 routes is 1.25% below main and
0.27% above the starting branch. These differences overlap the observed run
variation and do not establish a consistent HTTP performance regression or gain.
The mixed `/health` workload has visibly wider throughput and latency variation;
its raw samples remain included.

There are **90 valid HTTP samples, no failed samples, 90 dispatch samples, and
129,930 successful validation requests** across 24 fixture/backend configurations.
All 12 builds succeed, including 100 mixed routes. RSS changes by **0 KiB** in
every 5,000-request probe. The 100-route template fixture compiles in 3.66 seconds
versus 3.23/3.35 seconds for the handwritten baselines; these single warm-cache
builds describe this run, not precise compiler performance estimates.

The literal dispatcher matches the starting branch's 580-byte, 157-instruction
sequence, allowing only verified relocated addresses of identical string literals.
See [machine-code comparison](literal-codegen.json). This establishes equivalence
for this fixture, rather than every possible literal application.

The dispatch-only medians show the remaining API cost more clearly than HTTP:
one capture takes 4.61 ns versus 5.50 ns on main and 4.00 ns on the starting
branch's handwritten adapter. Two captures take 10.23 ns versus 7.80/7.15 ns.
The last match in 32 routes takes 42.93 ns versus 41.08/40.73 ns; a late miss
is 41.62 ns versus 40.87/40.89 ns. These are absolute costs for these fixed targets,
not a general speedup claim. Large inventories still scan every preceding route.
The starting branch's mixed `/health` wrapper adds an extra call, so its higher
microbenchmark cost on that one endpoint should not be attributed to native
literal routing.

See [measured tables](tables.md), [raw results and build metadata](results.json),
and [test logs](checks.json). Throughput uses medians with observed min–max;
latency uses the median of each run's p99, not a combined percentile.

## Memory and resource usage

The [memory comparison](memory.md) measures RSS, private memory, virtual address
space, CPU per request, connection scaling through all 1,024 slots, and retained
memory across two large-body cycles. It reuses the same verified binaries and adds
100,000-request growth probes on both backends.

## Reproduce

Run from the repository root with C3 0.8.3, Python 3, taskset, and wrk installed:

```sh
c3c compile-test .
c3c -O3 compile-test .
python3 test/compile_fail.py
python3 test/http_test.py
python3 test/route_inventory.py
python3 benchmark/templates/compare.py --wrk /path/to/wrk
python3 benchmark/templates/summarize.py
python3 benchmark/inventory_codegen.py \
  /tmp/c3ttp-template-benchmark/current-literal-4/server \
  /tmp/c3ttp-template-benchmark/templates-literal-4/server \
  --output benchmark/templates/literal-codegen.json
```

The harness writes isolated source snapshots and binaries to
`/tmp/c3ttp-template-benchmark`, leaving the baselines unchanged. `--workdir`,
`--output`, `--compiler`, CPU selection, runs, durations, and backends are configurable.
Use `--backends epoll` if io_uring is unavailable. The default run requires port
8080 to be free. Source generation is deterministic and retained in `compare.py`;
raw metadata records the exact commands, compiler version, hashes, and CPU details.
