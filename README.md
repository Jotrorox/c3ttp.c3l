# c3ttp

A fast, zero-allocation HTTP/1.1 parser and Linux server engine for [C3](https://c3-lang.org/).

Built for high throughput and predictable latency using zero-copy request views, SIMD-accelerated parsing, and a Linux `io_uring` event loop with automatic `epoll` fallback.

Requires C3 0.8.3 or later.

## Features

- **Zero-allocation parser**: Request methods, targets, headers, and bodies are returned as direct `String` views into the receive buffer.
- **SIMD delimiter scanning**: 32-byte vector operations accelerate delimiter scanning and header validation.
- **Linux `io_uring` & `epoll`**: Uses `io_uring` by default for asynchronous I/O and falls back cleanly to `epoll` when unavailable.
- **Multi-worker architecture**: Multi-process worker model via `SO_REUSEPORT` with CPU affinity pinning and cache-line aligned connection states.
- **Zero steady-state allocations**: Connection and buffer pools are allocated once at startup per worker.
- **Strict HTTP/1.1 validation**: Handles chunked transfer encoding, trailers, pipelining, keep-alive, and guards against malformed or conflicting framing headers.

## Quick Start

### Minimal Server

```c3
module app;

import c3ttp;

fn void? handle(RequestView* request, ResponseView* response, void* context)
{
    if (request.target == "/health")
    {
        c3ttp::ResponseView.ok(response, "ok");
        return;
    }
    c3ttp::ResponseView.set(response, 404, "not found");
}

fn int main()
{
    ServerOptions options = c3ttp::default_server_options();
    options.workers = 0; // 0 pins one worker per CPU core
    c3ttp::serve("0.0.0.0", 8080, &handle, options: options)!!;
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
- **Response bodies**: Memory assigned to `ResponseView.body` must remain valid until asynchronous transmission completes. String literals and slices into the request buffer are safe; local stack variables are not.
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

## Non-Goals

`c3ttp` is intentionally a lean HTTP/1.1 protocol engine and server core, not a full-featured web framework. Routing, middleware, TLS termination, and compression are out of scope. In production, TLS and HTTP/2/3 are best terminated by a reverse proxy (such as NGINX, HAProxy, or Envoy) in front of `c3ttp`.
