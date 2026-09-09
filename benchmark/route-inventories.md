# Explicit routes with annotation adapters

> Historical measurements are preserved in this report. Raw benchmark results,
> generated tables, charts, and logs are no longer versioned. Artifact filenames
> below identify local outputs or historical records; use the reproduction
> commands to collect fresh results.

Branch: `experiment/explicit-route-annotations`, based on `ad52a0f`.
This experiment combines the explicit branch's route tuples with generic
`@Route` declarations, retaining the existing APIs for compatibility.

```c3
module app;
import c3ttp;

fn String health() @Route({ GET, "/health" }) => "ok";
fn String echo(Request* req) => req.body;

fn int main()
{
    Server server = c3ttp::@server({
        c3ttp::@route(health),
        { Method.HEAD, "/health", &health },
        { Method.POST, "/echo", &echo },
    });
    server.listen("127.0.0.1", 8080)!!;
    return 0;
}
```

## API and tradeoffs

`@route(handler)` reads the handler's generic `@Route` tag and returns a
compile-time `{ Method, path, &handler }` tuple. `@server({ ... })` accepts a
nonempty flat inventory of those tuples. A handler can be reused at additional
methods or paths with explicit tuples; those tuples do not use its annotations.

This is slightly more verbose than `@server(health, echo)`. In exchange, the
registration site has one consistent representation and can combine annotated
handlers, unannotated handlers, and aliases. The braces around an inventory
matter: it reaches the collector as one argument, avoiding recursion per handler.
Using hundreds of separate top-level arguments still has the earlier limit.

A feature module can export `macro @routes()`, returning an inventory. The
application composes modules with `@server(users::@routes(), admin::@routes())`.
Inventories are flat; compose them as separate arguments rather than nesting them.
All duplicates are checked against the complete route set, across inventories.
Empty inventories, missing annotations, unsupported signatures, and invalid paths
produce compile-time errors. Examples and integration tests exercise both forms.

`@route` intentionally reads exactly one generic `@Route`. It does not expand
`@Get`/`@Post` tags. Existing bare-function registration still supports those
method annotations, including stacked methods, and can be mixed with inventories
at the top level. No route is registered merely by annotating a function.

The server transport, handler invocation, response lifetime rules, and request
dispatch are unchanged. Inventories do not allocate router objects or add runtime
lookups. They add module organization, not prefix routing or parameter extraction.

## Route-count scaling

[test/route_inventory.py](../test/route_inventory.py) generates a separate feature
module, alternating annotated and explicit handlers. Each handler returns a unique
body. The executable checks every route with a query string, plus wrong-method
and missing-path responses.

| Registered routes | Result with C3 0.8.3 |
| ---: | --- |
| 100 | Builds successfully; all 102 response checks pass |
| 1,000 | Compiler exceeds its default 4,096 MiB limit for a single memory arena |

The old generic annotation collector failed at 100 bare handlers in the
[five-way comparison](five-way/README.md). Passing a flat inventory removes that
specific recursion bottleneck. The 1,000-route trial establishes a remaining
compiler-memory limitation; this is not a claim of unlimited scaling. The trial
includes both registration and generated response checks, and no memory profile
was collected to attribute the compiler allocation to one expansion.
The recorded successful build time is not an isolated compiler benchmark.

Raw compiler version, timing, and failure diagnostic:
`inventory-scale.json`. The regular regression test defaults
to 100 routes; explicitly requesting 1,000 records the known failure and exits
nonzero.

## Generated dispatcher

Both the original `@Route` example and the hybrid example produce a **572-byte,
146-instruction** dispatcher. Raw bytes are not identical: five RIP-relative
addresses change because identical string literals move in the executable.
The review script verifies every instruction, permitting only those address
changes after checking the referenced literal's actual contents. The relocated
literals are `text/plain; charset=utf-8` and `Not Found`.

See raw code comparison (`inventory-codegen.json`) and
verified literal relocation review (`inventory-codegen-review.json`).
The generated runtime operations are equivalent for this fixture. This is not
a claim that the complete executable's `.text` section is byte-identical.

## HTTP performance

Before: `experiment/eclair-annotations` at
`c1875c5790f012020b94143bd37429b9384df1d3`.
After: the hybrid example and library sources identified by SHA-256 in
`inventory-build.json`.

Both use C3 0.8.3, LLVM 22.1.8, `-O3`, one worker on CPU 2, wrk's two client
threads on CPUs 4/5, and the same four routes with `/health` first. Each sample
uses a fresh process, one-second warmup, and three-second measurement. Five
repetitions alternate order per backend and connection count. Response validation
requires HTTP 200 with `ok`; socket and HTTP errors fail a sample. A greater than
3% median throughput drop fails the existing comparison runner.

| Backend | Connections | Before req/s | Inventory req/s | Change | Before p99 µs | Inventory p99 µs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| epoll | 2 | 155,758 | 157,554 | +1.15% | 16 | 16 |
| epoll | 64 | 275,725 | 272,749 | -1.08% | 346 | 362 |
| io-uring | 2 | 157,990 | 157,285 | -0.45% | 16 | 17 |
| io-uring | 64 | 346,098 | 345,362 | -0.21% | 211 | 214 |

All 40 samples completed without HTTP or socket errors. Throughput differences
range from −1.08% to +1.15%; all pass the configured 3% regression allowance.
The higher-concurrency p99 measurements fluctuate more than throughput, so this
does not establish a latency improvement.

Raw wrk output: `inventory-http.json`. These short loopback
measurements on a laptop include background scheduling and frequency variation;
they are not production capacity estimates. Code inspection provides a separate
check that the registration change adds no dispatch operations.

## Validation and reproduction

- 29 unit tests pass in debug and optimized builds on C3 0.8.3.
- 29 optimized unit tests pass on the C3 0.8.4 prerelease used in the five-way comparison.
- 39 invalid-declaration cases fail with the expected diagnostics, including duplicates across inventories.
- HTTP integration passes 10 cases plus borrowed-body pipelining per backend, using the hybrid inventory.
- The updated packaged example builds successfully.
- 100 mixed routes imported from another module pass all response checks.

```sh
c3c compile-test .
c3c -O3 compile-test .
python3 test/compile_fail.py
python3 test/http_test.py
python3 test/route_inventory.py

# Optional larger experiment; currently exits nonzero and records the failure:
python3 test/route_inventory.py --counts 100 1000 --output benchmark/out/inventory-scale.json

python3 benchmark/build.py --before-ref c1875c5790f012020b94143bd37429b9384df1d3
python3 benchmark/inventory_codegen.py benchmark/out/before-server benchmark/out/after-server \
  --output benchmark/out/inventory-codegen-review.json
python3 benchmark/run.py route=benchmark/out/before-server inventory=benchmark/out/after-server \
  --wrk /path/to/wrk --runs 5 --seconds 3 --output benchmark/out/inventory-http.json
```
