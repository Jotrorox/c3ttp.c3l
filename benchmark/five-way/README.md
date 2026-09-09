# Five-way API comparison

> Historical measurements are preserved in this report. Raw benchmark results,
> generated tables, charts, and logs are no longer versioned. Artifact filenames
> below identify local outputs or historical records; use the reproduction
> commands to collect fresh results.

This experiment compares the four existing c3ttp branches with an unmodified,
pinned Eclair checkout. It adds benchmark applications and reports; it does not
change any library implementation. Results were collected on 2026-09-09.

## Implementations

| Label | Branch / dependency | Revision | Routing API |
| --- | --- | --- | --- |
| main | `main` | `ce049990004207ef47ec6e0cfc01662a316ceb0e` | Handwritten `ViewHandler` passed to `serve` |
| explicit | `feat/developer-api` | `9585c33c35477119f3161172c6bc9733a54389ab` | `@server({ Method.GET, path, &handler }, ...)` |
| route | `experiment/eclair-annotations` | `c1875c5790f012020b94143bd37429b9384df1d3` | `@Route({ GET, path })`, then `@server(handler, ...)` |
| methods | `experiment/http-method-annotations` | `3e5d6c84c3183dd24ecb7cb37a1ce5c5f4cde89f` | `@Get(path)` / `@Post(path)`, then `@server(handler, ...)` |
| eclair | [Ecoral360/eclair.c3l](https://github.com/Ecoral360/eclair.c3l/tree/f8a837d0649d797fada62eadacc8cb7843939cca) | `f8a837d0649d797fada62eadacc8cb7843939cca` | `@Route`, then incremental `server.@add_route(handler)` |

Eclair's Dessert dependency is pinned to
`8a3f69794ef63d56c044c3f8734442fbd45c7f63`, from Eclair's lockfile.
Both dependencies are cloned into a temporary workspace; their source is unchanged.

## How the comparison works

All five use C3 **0.8.4 prerelease**, compiler commit
`acda47f794e860946dd048b77558ad3ec4c6bdde`, LLVM 22.1.8, and `-O3`.
Eclair requires 0.8.4 and cannot use the installed 0.8.3 release's reflection API.
Using the same newer compiler for every implementation avoids comparing compiler
versions. Eclair's C backend is also compiled with **`-O3`**: the compiler wrapper
records the actual arguments, retained in build.json (`results/build.json`).
The application's `cflags` setting alone did not propagate to that dependency's
C compilation, so the wrapper supplies the flag explicitly.

The host is a Linux laptop with an Intel Core Ultra 5 125U. Each server has one
worker pinned to CPU 2. Two wrk threads run on CPUs 4 and 5, over loopback port
8080. No other benchmark or compilation runs alongside the timed tests. This is
not an isolated production machine: frequency scaling and background processes
can affect results. Full compiler, CPU, kernel, build commands, revisions, source
hashes, and binary hashes are in the build metadata.

The primary comparison uses **epoll for all five**. A separate four-way io_uring
comparison uses the small GET workload; Eclair has no io_uring backend here.
Each sample starts a fresh server, warms it for one second, and measures three
seconds. Five repetitions rotate implementation order. Reported throughput is
the median; ranges are observed min–max, not confidence intervals. p99 is the
median of wrk's five per-run p99 values, not a combined percentile.

The four-route fixture registers these endpoints in the same order:

| Method | Path | Response body |
| --- | --- | --- |
| GET | `/health` | `ok` |
| GET | `/hello` | `Hello world!\n` |
| GET | `/status` | `OK` |
| POST | `/echo` | The fixed-length request body |

The larger fixtures append 28 or 96 literal GET routes, returning `ok`. The
32-route workload requests `/route/027`; the 100-route workload requests
`/route/095`. The POST benchmark sends and receives 256 bytes. The original
`main` branch gets a handwritten dispatcher with the same methods, paths, query
boundary behavior, and 404 behavior; its original example's catch-all 200 handler
would not have been an equivalent workload. Fixture generation is in
[build.py](build.py); the generated applications remain in the temporary workspace.

These are **whole HTTP server** measurements. Different parsers, socket settings,
allocators, response headers, and routing features remain part of each library.
For example, Eclair emits a Date header; c3ttp emits a Content-Type header.
c3ttp enables TCP_NODELAY by default; Eclair's C backend has no equivalent setting
in this checkout. Actual health response headers are retained in the raw results.
The Eclair/c3ttp difference cannot be attributed solely to annotation syntax.
There is no TLS, database, JSON serialization, multicore scaling, or WAN traffic
in these measurements.

## Performance results

Median **requests/second**, epoll throughout:

| Implementation | 4 routes: GET, c2 | 4 routes: GET, c64 | 256-byte POST, c64 | 32 routes: last GET, c64 | 100 routes: last GET, c64 |
| --- | ---: | ---: | ---: | ---: | ---: |
| main | 155,553 | 267,816 | 260,216 | 267,743 | 267,792 |
| Explicit routes | 157,732 | 268,387 | 261,702 | 268,578 | 267,654 |
| `@Route` | 155,066 | 269,123 | 260,771 | 269,350 | **compile failure** |
| `@Get` / `@Post` | 156,087 | 266,674 | 261,999 | 267,692 | **compile failure** |
| Eclair | 20,930 | 66,123 | 47,068 | 60,965 | **memory limit** |

Generated chart (local output): `results/throughput.svg`.

For the small GET workload at 64 connections, c3ttp is about **4.0–4.1×**
Eclair's throughput. The POST difference is about **5.5–5.6×**. The method
annotation version is within 0.5% of main on the small GET tests and has identical
executable code to the explicit and generic annotation versions in the tested
fixtures. There is no evidence here of a throughput penalty from method annotations.

With io_uring, the same 64-connection GET test reaches **338,642–341,446 req/s**
across the four c3ttp versions. That is a separate backend comparison, not an
io_uring result for Eclair.

There are **130 valid samples and five failed samples**. All five failures are
Eclair's 100-route workload: it exhausts the 2 GiB virtual-memory ceiling during
the measured interval. The final failed server log (`results/eclair-100-memory-limit.log`)
records `mem::OUT_OF_MEMORY`. Partial throughput from those failed runs is excluded.

The complete tables (`results/tables.md`) include every workload, p99, ranges, and
end-of-sample RSS. http.json (`results/http.json`) retains wrk output, run order,
validation results, memory measurements, and any failed samples.
validation.json (`results/validation.json`) adds a final check of 100 repeated GET
and POST requests per benchmark endpoint on persistent connections; those checks
pass for all runnable implementations. The mixed-target Eclair failure remains
recorded separately.

### Build scaling

These are single clean application builds with warm filesystem caches, not repeated
compiler benchmarks. Binary sizes include debug information and are not RSS.

| Implementation | 4 routes: seconds / KiB | 32 routes: seconds / KiB | 100 routes: seconds / KiB |
| --- | ---: | ---: | ---: |
| main | 1.79 / 544 | 1.86 / 549 | 1.92 / 555 |
| explicit | 1.81 / 546 | 1.89 / 560 | 1.99 / 599 |
| route | 1.84 / 546 | 1.87 / 560 | **compile failure** |
| methods | 1.80 / 546 | 1.87 / 560 | **compile failure** |
| eclair | 1.88 / 523 | 1.97 / 551 | 2.03 / 628 |

### Annotation overhead

The explicit, `@Route`, and method annotation applications have **byte-identical
executable `.text` sections** for matching four-route fixtures. The dispatcher is
299 bytes. The 32-route explicit and method annotation applications also have
identical `.text` sections; their dispatcher is 2,064 bytes.

See explicit versus Route (`results/codegen-explicit-route-4.json`),
Route versus method annotations (`results/codegen-route-methods-4.json`), and
32-route explicit versus method annotations (`results/codegen-explicit-methods-32.json`).
Small measured differences between these binaries are not evidence of an
annotation runtime cost. These results establish equivalence for the tested
fixtures, rather than proving every possible application has identical output.

## Correctness and growth findings

### Annotation registration fails at 100 handlers

Both annotation branches build and run the 32-route fixture, but **fail to compile
100 registered handlers** with “max call depth reached”. Their recursive
`@collect_routes` expansion reaches the compiler's macro call-depth limit.
The explicit branch, handwritten main application, and Eclair compile all 100.
The full diagnostics are retained in build.json (`results/build.json`).

The 100-route table consequently has no throughput number for either annotation
branch. This is an API scalability limitation even though the generated runtime
code is fast. Switching to explicit tuples inside an annotation branch is not an
established workaround: those branches still process registration through the
collector. A collector redesign is required before recommending this API for
hundreds of handlers. The experiment deliberately preserves the branches as-is.

### Eclair mishandles different targets on a persistent connection

All fresh-connection route/status/body checks pass. The persistent-connection
sequence `GET /health`, `GET /health?probe=1`, `GET /hello`, `GET /status`, then
`POST /echo` produces a reproducible Eclair failure: `/status` returns 404, and
its log reports the target as `/statu`. The query request also causes an unexpected
connection close. This happens with 4, 32, and 100 routes. c3ttp passes the same
sequence in both backends.

The benchmark uses repeated identical requests at each URL. Its Eclair throughput
numbers describe that narrower workload, **not general persistent-connection
correctness**. Fresh-connection validation and these mixed-request results are
recorded separately, so the throughput table does not disguise a failed check.
This is a reproducible observation of the pinned Eclair/C-backend combination;
this experiment does not establish which component contains the underlying bug.

### Eclair retains memory per request

A separate probe sends 5,000 requests sequentially on a persistent connection,
recording RSS every 1,000 requests. It uses `/health` with four routes and the last
route with 32 or 100 routes. c3ttp's RSS stays flat after initialization in these
probes; Eclair's rises with request count and with the number of routes scanned.

| Implementation | Routes | RSS before MiB | After 5,000 requests MiB | Increase MiB |
| --- | ---: | ---: | ---: | ---: |
| main | 4 | 6.81 | 6.81 | 0.00 |
| explicit | 4 | 6.62 | 6.62 | 0.00 |
| route | 4 | 6.74 | 6.74 | 0.00 |
| methods | 4 | 6.74 | 6.74 | 0.00 |
| eclair | 4 | 2.41 | 5.00 | 2.59 |
| main | 32 | 6.81 | 6.81 | 0.00 |
| explicit | 32 | 6.68 | 6.68 | 0.00 |
| route | 32 | 6.69 | 6.69 | 0.00 |
| methods | 32 | 6.80 | 6.80 | 0.00 |
| eclair | 32 | 2.44 | 25.63 | 23.20 |
| main | 100 | 6.75 | 6.75 | 0.00 |
| explicit | 100 | 6.75 | 6.75 | 0.00 |
| eclair | 100 | 2.34 | 72.23 | 69.89 |

The source explains why this warrants concern: `Route.match_target` initializes
an allocated hash map before matching each candidate, including unsuccessful
candidates; `Router.dispatch_target` allocates a split target and retains the
successful parameter map. These request allocations have no corresponding free
in the inspected dispatch path. RSS alone is not an exact allocation count, but
its sustained increase agrees with that source inspection.

All benchmark processes have the same 2 GiB virtual-address-space ceiling to
bound this growth. A crashed server, socket error, or non-2xx wrk response marks a
sample failed and excludes it from medians; failures are retained. Restarting
between samples bounds accumulation, so these short runs do not demonstrate
long-term stability.

## Readability and usability ratings

These are engineering judgments on a **1–10 scale**, not benchmark scores.
Readability rates how easily a reviewer can see the method, path, and handler.
API usability rates registration, handler ergonomics, expressiveness, and setup.
Large-system suitability additionally weighs route-count scaling, application
state isolation, memory behavior, and the observed correctness limitations.
Scores assess these exact experimental versions, not hypothetical future fixes.

| Implementation | Readability | API usability | Large-system suitability | Main reason |
| --- | ---: | ---: | ---: | --- |
| main | 4 | 3 | 5 | Full control and fast core; routing, validation, and organization are application code. |
| Explicit routes | 7 | 7 | 7 | Central route inventory, compiler checks, no request allocations; 100 routes work. |
| `@Route` | 8 | 8 | 5 | Metadata beside handlers and simple registration; 100-handler compilation fails. |
| `@Get` / `@Post` | 9 | 8 | 5 | Clearest HTTP intent and same generated code; inherits the registration limit. |
| Eclair | 9 | 8 | 2 | Concise API and richer routing conveniences; persistent-connection failure and memory growth are serious limitations. |

The two annotation APIs reduce repetition and let handlers live in imported
modules. The method form is the easiest to scan. Both still need a central
registration call. c3ttp supports application context, worker configuration, and
compile-time checks for duplicate method/path pairs and unsupported signatures.
The three higher-level APIs have the same basic runtime routing model: literal
paths in registration order, with no automatic path parameter binding, JSON
serialization, nested router groups, or automatic 405 responses.

Eclair's own implementation adds nested router prefixes, dynamic `:parameter`
matching, parameter inference, and Dessert serialization. Those conveniences are
relevant to API ergonomics, but they are not exercised by this throughput test.
Its root router is process-global, shared by `Server` instances, which complicates
isolated applications and tests. c3ttp's per-server context is a clearer starting
point for explicit application state, although applications still own synchronization
and borrowed response-body lifetimes.

For a small service, **the method annotation API is the strongest design direction**:
clear route declarations with no measured code-generation penalty. For a service
with hundreds of handlers today, **the explicit branch is the most practical of
these versions**. Before adopting annotations there, remove recursive collection,
then rerun 100- and 1,000-route compile and dispatch checks. For more complex
applications, route grouping and typed parameter extraction would be useful
additions, provided their cost is measured separately. Eclair offers inspiration
for those features, but this pinned version needs its observed correctness and
memory issues resolved before it is a sound basis for a long-running service.

## What two routes look like

The original API requires a dispatcher:

```c3
fn void? handle(RequestView* req, ResponseView* res, void* context)
{
    if (req.method_id == GET && req.target == "/health") res.ok("ok");
    else if (req.method_id == POST && req.target == "/echo") res.ok(req.body);
    else res.set(404, "Not Found");
}
// In main:
c3ttp::serve("127.0.0.1", 8080, &handle)!!;
```

The explicit branch puts the route inventory at registration:

```c3
fn String health() { return "ok"; }
fn String echo(Request* req) { return req.body; }
// In main:
Server server = c3ttp::@server(
    { Method.GET, "/health", &health },
    { Method.POST, "/echo", &echo });
```

The generic annotation branch moves that metadata to the functions:

```c3
fn String health() @Route({ GET, "/health" }) { return "ok"; }
fn String echo(Request* req) @Route({ POST, "/echo" }) { return req.body; }
// In main:
Server server = c3ttp::@server(health, echo);
```

The method annotation branch shortens the declarations:

```c3
fn String health() @Get("/health") { return "ok"; }
fn String echo(Request* req) @Post("/echo") { return req.body; }
// In main:
Server server = c3ttp::@server(health, echo);
```

Eclair uses incremental registration and a body accessor:

```c3
fn String health() @Route({ GET, "/health" }) { return "ok"; }
fn String echo(Request* req) @Route({ POST, "/echo" }) { return req.body(); }
// In main:
Server server = eclair::new_server(8080);
server.@add_route(health);
server.@add_route(echo);
```

Each `Server` example finishes with `server.listen(...)` using that library's
signature. These excerpts emphasize API shape; the compiled benchmark fixtures
include full startup and identical query matching. The runnable Eclair project is
[eclair/src/main.c3](eclair/src/main.c3).

## Verification

The root library's 27 optimized unit tests pass with both C3 0.8.3 and the
comparison's 0.8.4 prerelease. Final HTTP validation covers 23 implementation /
route-count / backend configurations, 893 fresh-connection checks, and 6,000
repeated GET/POST checks. All of those pass; the Eclair mixed-target failure is
retained separately. The standalone Eclair project was rebuilt and tested as well.
See checks.json (`results/checks.json`) and
standalone project validation (`results/eclair-project-validation.json`).

## Reproduce

Run from the repository root on Linux. You need Python 3, a C compiler, taskset,
wrk, and the C3 compiler above. The temporary workspace defaults to
`/tmp/c3ttp-five-way`; set `C3TTP_COMPARISON_DIR` to choose another directory.
Keeping cloned source outside the repository also keeps `c3c compile-test .`
from recursively compiling multiple copies of the libraries.

```sh
mkdir -p /tmp/c3ttp-five-way/toolchain
curl -fL https://github.com/c3lang/c3c/releases/download/latest-prerelease-tag/c3-linux.tar.gz \
  -o /tmp/c3ttp-five-way/toolchain/c3-linux.tar.gz
tar -xzf /tmp/c3ttp-five-way/toolchain/c3-linux.tar.gz \
  -C /tmp/c3ttp-five-way/toolchain
/tmp/c3ttp-five-way/toolchain/c3/c3c --version
python3 benchmark/five-way/build.py
python3 benchmark/five-way/run.py --wrk /path/to/wrk \
  --output /tmp/c3ttp-five-way/http.json
python3 benchmark/five-way/summarize.py /tmp/c3ttp-five-way/http.json
```

The prerelease download URL is mutable. For an exact reproduction, verify its
compiler commit and archive SHA-256 against build.json (`results/build.json`), or
use an archived copy of that toolchain. `build.py --compiler /path/to/c3c` accepts
another compiler for a new experiment, recording its version. The build step
clones and pins Eclair and Dessert automatically and preserves build failures as
data. It leaves failed-build stale binaries out of the run manifest.

To run the standalone Eclair project after setup:

```sh
cd benchmark/five-way/eclair
/tmp/c3ttp-five-way/toolchain/c3/c3c clean-run eclair_benchmark --cc ../cc-record.py
# In another terminal:
curl http://127.0.0.1:8080/health
curl --data 'hello' http://127.0.0.1:8080/echo
```

For a custom workspace, add `--libdir /your/workspace/lib` to that C3 command.
The project's feature flag keeps its Eclair-only module out of the root library's
recursive test build. `run.py --validate-only` repeats route checks and bounded
memory probes without timing wrk. Servers listen on port 8080; stop the standalone
example before starting the benchmark. Eclair's default listener binds all
interfaces; the benchmark client uses loopback.

SVG chart regeneration optionally needs matplotlib. The JSON and Markdown summary
are produced without it. The checked-in chart is a standalone artifact.
