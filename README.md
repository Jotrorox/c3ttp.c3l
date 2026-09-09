# c3ttp

A fast, zero-allocation HTTP/1.1 parser and Linux server engine for [C3](https://c3-lang.org/).

Built for high throughput and predictable latency using zero-copy request views, SIMD-accelerated parsing, and a Linux `io_uring` event loop with automatic `epoll` fallback.

Requires C3 0.8.3 or later.

## Features

- **Zero-allocation parser**: Request methods, targets, headers, and bodies are returned as direct `String` views into the receive buffer.
- **SIMD delimiter scanning**: 32-byte vector operations accelerate delimiter scanning and header validation.
- **Linux `io_uring` & `epoll`**: Uses `io_uring` by default for asynchronous I/O and falls back cleanly to `epoll` when unavailable.
- **Multi-worker architecture**: Multi-process worker model via `SO_REUSEPORT` with CPU affinity pinning and cache-line aligned connection states.
- **Route inventories**: Combine `@Route` handlers with explicit route tuples in a compile-time inventory, with simple string-returning handlers and no runtime route registry.
- **Zero steady-state allocations**: Connection and buffer pools are allocated once at startup per worker.
- **Strict HTTP/1.1 validation**: Handles chunked transfer encoding, trailers, pipelining, keep-alive, and guards against malformed or conflicting framing headers.

## Quick Start

### Minimal Server

```c3
module app;

import c3ttp;

fn String hello() @Route({ GET, "/" })
{
    return "Hello world!\n";
}

fn void status(Request* request, Response* response)
{
    response.set_body("OK");
}

fn int main()
{
    Server server = c3ttp::@server({
        c3ttp::@route(hello),
        { Method.GET, "/status", &status },
    });
    server.listen("127.0.0.1", 8080)!!;
    return 0;
}
```

Run the included example:

```sh
cd examples/hello_server
c3c run hello_server

# Select backend or worker count:
c3c run hello_server -- --epoll
c3c run hello_server -- --workers=2
```

### Route inventories

This branch combines the explicit route API with `@Route` annotations. Use
`c3ttp::@route(handler)` to read a handler's `@Route({ method, path })` declaration
into a compile-time `{ Method, path, &handler }` tuple. Put those entries alongside
ordinary tuples inside **one inventory**, using `@server({ ... })` with braces.
The inventory is explicit about which handlers are exposed, while annotations
keep a route's method and path beside its implementation.

```c3
fn String health() @Route({ GET, "/health" }) => "ok";
fn String echo(Request* request) => request.body;

// In main:
Server server = c3ttp::@server({
    c3ttp::@route(health),
    { Method.HEAD, "/health", &health },
    { Method.POST, "/echo", &echo },
});
```

An explicit tuple is authoritative: it can reuse an annotated handler at another
method or path without changing that handler's declaration. `@route(handler)`
reads exactly its generic `@Route` tag; it does not infer a route from `@Get` or
expand other method annotations. Use a function name, not `&handler`, with
`@route`; use `&handler` in explicit tuples. An annotation alone exposes nothing.

Modules can export inventories for larger services:

```c3
// In module api, with the handlers above:
macro @routes()
{
    return {
        c3ttp::@route(health),
        { Method.POST, "/echo", &echo },
    };
}
// In the application, after importing api and admin:
Server server = c3ttp::@server(api::@routes(), admin::@routes());
```

Each inventory is a nonempty, flat list of triples. Compose inventories as separate
`@server(...)` arguments; do not nest an inventory inside another inventory.
Duplicate method/path pairs are checked across the complete registration, including
module boundaries. Registration order is preserved. Inventories add no runtime
router objects, allocation, or function-pointer lookup beyond the existing server
callback. They do not add path prefixes or dynamic parameter extraction.

A single inventory avoids recursive collection per handler. The mixed 100-route
module test passes; a 1,000-route trial reaches the compiler's default memory
limit. See the [experiment results](benchmark/route-inventories.md) for the
measurements and remaining scaling limits.

### Existing annotation registration

Annotate a function with `@Get("/path")`, `@Post("/path")`, etc., then register its **name**
in `c3ttp::@server(hello, status)`. The method and path belong to the function;
registration does not repeat them. Functions in another imported module can be
registered by qualified name, e.g. `c3ttp::@server(api::health, api::status)`.
An annotation alone does not register a function.

Available method annotations:

| Annotation | HTTP method |
| --- | --- |
| `@Get(path)` | GET |
| `@Post(path)` | POST |
| `@Put(path)` | PUT |
| `@Delete(path)` | DELETE |
| `@Head(path)` | HEAD |
| `@Options(path)` | OPTIONS |
| `@Patch(path)` | PATCH |
| `@Connect(path)` | CONNECT |
| `@Trace(path)` | TRACE |

C3 0.8.3 requires type-style capitalization for custom attributes: `@Get`, not
`@GET`. The annotations select HTTP methods; transport behavior is unchanged.

Different method annotations can share a handler, including different paths:

```c3
fn String health() @Get("/health") @Head("/health")
{
    return "ok";
}
```

Register `health` once to add both routes. Use each method annotation at most
once on a function: C3 overwrites repeated tags of the same name. To expose the
same handler at another path for the same method, add an explicit route triple.

The macro reads annotations at compile time and emits direct comparisons and
calls. It creates no route registry and allocates no memory per request. Missing
annotations, duplicate method/path pairs, malformed paths, and unsupported handler
signatures produce compiler errors. Routes are checked in registration order;
keep frequently used routes near the front when using a large list.

Bare function registration still uses the recursive collector: the historical
[five-way comparison](benchmark/five-way/README.md) builds 32 handlers but hits
the macro call-depth limit at 100. Use the inventory form above to avoid recursion
per handler. Supplying hundreds of separate top-level arguments is still unsupported.

The previous `@Route({ GET, "/path" })` annotation and explicit
`{ method, path, &handler }` API remain supported. All three forms can be mixed,
for example to reuse a handler at another path:

```c3
Server server = c3ttp::@server(
    hello,
    { Method.GET, "/greeting", &hello },
    status,
);
```

All route metadata and function references must be compile-time constants.
This experimental annotation API takes inspiration from
[Eclair](https://github.com/Ecoral360/eclair.c3l). Registration remains a single
`@server(...)` call so the compiler can emit the complete dispatcher. Eclair's
incremental `new_server()` / `server.@add_route()` API, automatic parameter
extraction, and automatic JSON serialization are not implemented here.

Handlers can return `String` (200 with a plain-text body), `String?`, `void`, or
`void?`. Use a `void` handler to set a custom status or content type. Faults from
optional handlers use the engine's existing 500 response and close the connection.
Handlers must be public (C3's default visibility): the generated dispatcher lives
in the library module. Private callbacks are not supported by this macro on C3 0.8.3.

Take only the parameters you need, in any order, up to three parameters:

```c3
fn String echo(Request* request) @Post("/echo")
{
    return request.body; // For a fixed-length body; see chunked bodies below.
}

fn void create(Response* response) @Post("/create")
{
    response.text("created", 201);
}

fn void contextual(Request* request, Response* response, void* context) @Get("/context")
{
    response.text(*(String*)context);
}
```

Set `server.context` for application state and `server.options` for backend,
worker count, and buffer limits. `server.listen()` defaults to `0.0.0.0:8080`
and blocks while serving, just like `serve()`. Construct servers with `@server`
to initialize the handler and default options.

Routing matches the exact, case-sensitive path and method. The query string is
ignored for matching: `/status?verbose=1` matches `/status`. A trailing slash is
significant. An unregistered path or method returns 404; register `HEAD` and
`OPTIONS` explicitly if needed. `"*"` is a literal target for e.g. `OPTIONS *`,
not a wildcard. Parameters, wildcards, decoding, and automatic 405/Allow responses
are not provided.

`request.path()` and `request.query()` expose raw, borrowed strings without
allocation or URL decoding. `request.target` retains the full original target.
`response.text(body, status: 200)` and `response.json(body, status: 200)` set the
body and content type; `json()` takes **already serialized JSON**.
`response.set_body(body)` and `response.set_status(status)` update only their
respective fields. Both preserve the content type and connection policy. A
string-returning handler still produces a 200 plain-text response; use a `void`
handler when setting status and body independently.

`Request` and `Response` are aliases for `RequestView` and `ResponseView`, with
identical layouts and lifetime rules. The original `serve()`, `ViewHandler`,
parser API, and `response.ok()` / `response.set()` remain available. Existing
three-argument `ViewHandler` functions can also be registered directly as routes.

### Installation

Clone this repository as `lib/c3ttp.c3l` in your C3 project and add
`"dependencies": ["c3ttp"]` to `project.json`. The library has no third-party
runtime dependencies. Linux x64 and aarch64 are declared in the manifest; the
included example and benchmarks are verified on Linux x64.

### Standalone Parser

The parser can also be used independently without the server:

```c3
String data = "GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n";

RequestParser parser;
parser.init();

ParseStatus status = parser.parse((char[])data)!!;
if (status == COMPLETE)
{
    String target = parser.request.target;
    String host = parser.request.header(HOST)!!;
}
```

For streaming or fragmented network input, pass the cumulative buffer received so far:

```c3
parser.parse(buffer[:received_len])!!;
```

## Zero-Copy & Lifetimes

Because `RequestView` slices directly into the caller's receive buffer:

- **Buffer stability**: The receive buffer must remain valid and unmoved while reading request fields.
- **Response bodies**: Returned handler strings and memory assigned to `ResponseView.body` must remain valid until asynchronous transmission completes. String literals and slices into the request buffer are safe; local stack arrays and freed temporary allocations are not. The string-returning API borrows memory; it does not copy the body.
- **Chunked bodies**: Chunk payloads are exposed via `request.body_chunks()` because chunk framing makes the payload noncontiguous in the stream.

## Configuration

Server options can be customized via `ServerOptions`:

```c3
ServerOptions options = c3ttp::default_server_options();
options.backend = AUTO;                // AUTO, IO_URING, or POLL (epoll)
options.workers = 0;                   // 0 = one worker per CPU core
options.connections_per_worker = 1024; // Max concurrent connections per worker
options.buffer_size = 32768;           // Receive buffer size per connection (32 KiB)
options.pin_workers = true;            // Pin workers to CPU cores
options.tcp_no_delay = true;           // Enable TCP_NODELAY
```

Each worker allocates `connections_per_worker * buffer_size` upfront (by default, 32 MiB per worker for 1,024 connections).

## Testing

Run the test suite:

```sh
c3c compile-test .
```

To compile with optimizations:

```sh
c3c -O3 compile-test .
```

Compile-time API diagnostics and HTTP integration checks:

```sh
python3 test/compile_fail.py
python3 test/http_test.py
python3 test/route_inventory.py
```

If io_uring is unavailable, run the HTTP checks with
`python3 test/http_test.py --backends epoll`.

## Performance

The [route inventory experiment](benchmark/route-inventories.md) compares this
hybrid API with the generic `@Route` branch, including generated code, HTTP
throughput, and the 100/1,000-route compilation trials.

See [benchmark/README.md](benchmark/README.md) for reproducible before/after
measurements, raw results, and the workload limits of the comparison.
The [annotation experiment](benchmark/annotations.md) separately compares this
API with the previous explicit route API, including a machine-code comparison.
The [method annotation experiment](benchmark/method-annotations.md) compares
`@Get` / `@Post` with `@Route`, including generated code and HTTP measurements.
The [five-way comparison](benchmark/five-way/README.md) benchmarks all four
branches against a runnable Eclair project and evaluates API readability,
usability, route-count scaling, and memory growth.

## Non-Goals

`c3ttp` is intentionally a lean HTTP/1.1 protocol engine and server core, not a full-featured web framework. Dynamic routing, middleware, TLS termination, and compression are out of scope. The optional static route API is a small convenience layer over the original callback engine. In production, TLS and HTTP/2/3 are best terminated by a reverse proxy (such as NGINX, HAProxy, or Envoy) in front of `c3ttp`.
