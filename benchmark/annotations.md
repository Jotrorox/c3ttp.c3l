# Route annotation experiment

Branch: `experiment/eclair-annotations`, based on
`9585c33c35477119f3161172c6bc9733a54389ab` (`feat/developer-api`).

The experiment adds Eclair-style `@Route({ GET, "/path" })` annotations and
`Response.set_body()` / `Response.set_status()`. The API shape was inspected in
[Eclair's route implementation](https://github.com/Ecoral360/eclair.c3l/blob/f8a837d0649d797fada62eadacc8cb7843939cca/src/route.c3),
cloned into a temporary directory. No Eclair code or runtime dependencies are
vendored into this library.

```c3
fn String hello() @Route({ GET, "/hello" }) => "Hello world!\n";

fn void api_status(Request* request, Response* response) @Route({ GET, "/status" })
{
    response.set_body("OK");
}

fn int main()
{
    Server server = c3ttp::@server(hello, api_status);
    server.listen()!!;
    return 0;
}
```

Use `module app; import c3ttp;` above this example. The registration form collects
all annotated functions at compile time. It deliberately keeps the static
`@server(...)` constructor: incremental `server.@add_route()` registration would
need a different runtime representation. Path matching, request/response
lifetimes, handler signatures, and the transport engine retain their existing
semantics. Explicit route triples can still be mixed with annotated functions.
This is an annotation experiment, not a port of Eclair's parameter inference,
JSON serialization, router groups, or complete framework behavior.

## Compiler result

The macro forwards each remaining argument pack into a recursive macro with an
expression parameter (`#first`). That preserves a function's declaration and
its module scope when reading `@Route` metadata. Directly indexing the raw macro
argument pack treats function names as values on the installed C3 0.8.3 compiler.
Both annotated functions and explicit triples are reduced to the original
compile-time route representation before generating the dispatcher.

The old and new optimized example dispatchers are **byte-for-byte identical**:
572 bytes, SHA-256
`3539f0ccc3311441afa26973efc31f537b732446a7517c6e02b39a9cd1570db9`.
Across the complete executable `.text` section there is only one differing byte:
a startup panic's source-line number changed from 54 to 49 when the registration
list became shorter. The request-handling instructions are unchanged.
See [annotations-codegen.json](annotations-codegen.json).

These results are specific to the included example, route set, compiler, and
build flags. The comparison helper intentionally fails if the symbol bytes
change, including address/layout changes that need manual inspection.

## HTTP comparison

Same machine and pinning as the [original benchmark](README.md): Linux x64,
Intel Core Ultra 5 125U, C3 0.8.3 / LLVM 22.1.8, `-O3`, one server worker on CPU 2,
two wrk threads on CPUs 4 and 5. Each binary receives five three-second samples
per backend/concurrency combination, with a one-second warm-up per sample and
alternating order. Both serve the same `GET /health` body through four routes.

| Backend | Connections | Before (req/s) | Annotated (req/s) | Change |
| --- | ---: | ---: | ---: | ---: |
| epoll | 2 | 155,614 | 156,777 | +0.75% |
| epoll | 64 | 268,448 | 269,986 | +0.57% |
| io-uring | 2 | 157,792 | 160,246 | +1.56% |
| io-uring | 64 | 340,933 | 339,838 | -0.32% |

Median of the per-run p99 latencies:

| Backend | Connections | Before | Annotated |
| --- | ---: | ---: | ---: |
| epoll | 2 | 17 µs | 16 µs |
| epoll | 64 | 355 µs | 355 µs |
| io-uring | 2 | 16 µs | 16 µs |
| io-uring | 64 | 226 µs | 218 µs |

Throughput changes range from -0.32% to +1.56%; no material throughput
regression was detected. All 40 timed samples completed without wrk socket or
HTTP status errors. These small differences are not evidence of a speedup.

All samples are retained in [annotations-http.json](annotations-http.json).
The unchanged dispatcher is stronger evidence of annotation overhead than small
wall-clock differences on this laptop with CPU frequency scaling enabled.
The network test is still limited to a small response and a single worker;
these results are not a performance claim about every application.

## Reproduce

From the repository root, with `c3c`, Python 3, binutils, `taskset`, and `wrk`:

```sh
python3 benchmark/build.py --before-ref 9585c33c35477119f3161172c6bc9733a54389ab
python3 benchmark/compare_codegen.py \
  benchmark/out/before-server benchmark/out/after-server \
  --output benchmark/out/annotations-codegen.json
python3 benchmark/run.py \
  before=benchmark/out/before-server after=benchmark/out/after-server \
  --wrk /path/to/wrk --runs 5 --seconds 3 \
  --output benchmark/out/annotations-http.json
```

The saved measurements use the equivalent `annotation-before-server` and
`annotation-after-server` filenames to preserve the earlier benchmark binaries.

Functional checks:

```sh
c3c compile-test .
c3c -O3 compile-test .
python3 test/compile_fail.py
python3 test/http_test.py
```

The annotation tests cover equality with explicit routes, mixed registration,
imported handlers, single routes, optional errors, application context, and
independent response setters. The real-socket fixture uses annotated handlers
for query matching, JSON, echo, faults, and keep-alive/pipelining on both Linux
backends. Compiler checks retain the original invalid route cases and add
missing annotations, passing a pointer instead of a function name, annotation
collisions, and invalid annotated paths/signatures.
