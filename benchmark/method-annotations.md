# HTTP method annotation experiment

> Historical measurements are preserved in this report. Raw benchmark results,
> generated tables, charts, and logs are no longer versioned. Artifact filenames
> below identify local outputs or historical records; use the reproduction
> commands to collect fresh results.

Branch: `experiment/http-method-annotations`, based on
`c1875c5790f012020b94143bd37429b9384df1d3` (`experiment/eclair-annotations`).

Handlers now take method-specific attributes with a single path argument:

```c3
module app;
import c3ttp;

fn String hello() @Get("/hello") => "Hello world!\n";

fn void create(Response* response) @Post("/items")
{
    response.json("{\"created\":true}", 201);
}

fn String health() @Get("/health") @Head("/health") => "ok";

fn int main()
{
    Server server = c3ttp::@server(hello, create, health);
    server.listen()!!;
    return 0;
}
```

The supported attributes are `@Get`, `@Post`, `@Put`, `@Delete`, `@Head`,
`@Options`, `@Patch`, `@Connect`, and `@Trace`. C3 0.8.3 rejects all-uppercase
custom attribute names such as `@GET`; the accepted spelling is `@Get`.
Registration, handler signatures, response lifetimes, and transport behavior
retain their existing semantics.

## Multiple annotations and compatibility

Each method has its own compile-time tag. This matters because C3 replaces
repeated metadata tags: mapping every shorthand to the same `@Route` tag would
silently lose a route when stacking `@Get` and `@Post` on one handler. The
collector now expands all distinct method tags into the existing route triples.
No tags are inspected at runtime.

Use each method annotation once per function. For additional paths with the
same HTTP method, add explicit route triples. Repeating the identical method
attribute is unsupported because the compiler replaces its tag before the
library can inspect it. `@Route({ method, path })` and explicit triples remain
supported and can be mixed with method annotations. Duplicate method/path pairs
across the collected routes still produce compiler errors, including collisions
between a shorthand and `@Route`.

## Generated code

The optimized example's **entire `.text` section is byte-for-byte identical**
to its `@Route` version. The 572-byte dispatcher retains SHA-256
`3539f0ccc3311441afa26973efc31f537b732446a7517c6e02b39a9cd1570db9`.
There are zero differing code bytes. See
`method-annotations-codegen.json`.

This establishes that the shorthand introduces no runtime instruction changes
for this example and compiler configuration. It is not a claim about every
application, route set, or compiler version.

## HTTP measurements

Same workload and environment as the [previous annotation experiment](annotations.md):
Linux x64, Intel Core Ultra 5 125U, C3 0.8.3 / LLVM 22.1.8, `-O3`, one server
worker on CPU 2, two wrk threads on CPUs 4 and 5. Each old/new binary receives
five three-second measurements per backend/concurrency setting with a one-second
warm-up and alternating order. Both return the same `GET /health` response
through four routes. No other compilation or test jobs run during measurement.

| Backend | Connections | Before (req/s) | Method annotations (req/s) | Change |
| --- | ---: | ---: | ---: | ---: |
| epoll | 2 | 153,316 | 154,060 | +0.49% |
| epoll | 64 | 261,671 | 257,157 | -1.73% |
| io-uring | 2 | 154,296 | 154,086 | -0.14% |
| io-uring | 64 | 330,741 | 331,378 | +0.19% |

Median of the per-run p99 latencies:

| Backend | Connections | Before | Method annotations |
| --- | ---: | ---: | ---: |
| epoll | 2 | 506 µs | 507 µs |
| epoll | 64 | 940 µs | 1030 µs |
| io-uring | 2 | 551 µs | 491 µs |
| io-uring | 64 | 930 µs | 426 µs |

Measured throughput changes range from -1.73% to +0.49%, within the observed
run variability and the configured 3% throughput noise allowance. All 40 timed
samples completed without wrk socket or HTTP status errors. The latency results
are included above; this benchmark is not a guarantee of identical timing.

All samples and latency output are in
`method-annotations-http.json`. Small differences
between runs of identical machine code reflect measurement variability, not a
speedup or slowdown caused by method annotations. CPU frequency scaling remained
enabled; this is a local, single-worker, small-response experiment.

## Reproduce

From the repository root, with C3 0.8.3, Python 3, binutils, `taskset`, and `wrk`:

```sh
python3 benchmark/build.py --before-ref c1875c5790f012020b94143bd37429b9384df1d3
python3 benchmark/compare_codegen.py \
  benchmark/out/before-server benchmark/out/after-server \
  --output benchmark/out/method-annotations-codegen.json
python3 benchmark/run.py \
  before=benchmark/out/before-server after=benchmark/out/after-server \
  --wrk /path/to/wrk --runs 5 --seconds 3 \
  --output benchmark/out/method-annotations-http.json
```

The recorded runs used equivalent `method-before-server` and
`method-after-server` filenames to preserve the earlier binaries.

Validation completed with:

```sh
c3c compile-test .
c3c -O3 compile-test .
python3 test/compile_fail.py
python3 test/http_test.py
```

27 unit tests cover all nine method mappings, stacked methods with shared and
separate paths, imported handlers, and compatibility with existing annotations
and explicit routes. 30 compiler checks include duplicate routes, malformed
paths, invalid signatures, and collisions across annotation forms. The HTTP
fixture checks the new attributes on both epoll and io_uring, including a stacked
Get/Head handler, body suppression, query strings, optional handler faults, and
borrowed-body pipelining. The packaged example also builds successfully.
