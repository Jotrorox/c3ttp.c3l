# c3ttp

Small HTTP/1.1 client and server library for C3, built on `std::net::tcp`.

- `c3ttp.c3i`: public API
- `src/`: implementation
- `test/`: package tests
- `examples/`: usage examples

- HTTP/1.1 request and response parsing
- `Content-Length` and `Transfer-Encoding: chunked`
- buffered and streaming body APIs
- basic TCP client and server helpers
- keep-alive support for HTTP/1.1
- Linux `epoll` event loop for server workloads
- Linux prefork serving with `SO_REUSEPORT`
- `TCP_NODELAY` enabled for client connections and accepted server sockets

```bash
c3c compile-test .
(cd examples/hello_server && c3c build)
(cd examples/client_get && c3c build)
(cd examples/router_simple && c3c build)
```

For long-lived servers, do not initialize `Server` with `tmem`. Use `mem` or another non-temp allocator so per-request allocations can be reclaimed normally across many requests.

See [`c3ttp.c3i`](https://github.com/Jotrorox/c3ttp.c3l/blob/main/c3ttp.c3i) for the supported public surface.

- `Request` / `Response`
- `Client.send` / `Client.send_url`
- `Server.listen` / `Server.serve_once` / `Server.serve`
- `Server.serve_evented` / `Server.serve_prefork`
- `read_request` / `read_response`
- `write_request` / `write_response`

HTTP messages are parsed and serialized using strict HTTP/1.1 syntax and framing. On Linux, `serve_evented` uses nonblocking persistent connections. Its per-connection input and output buffers are allocated lazily and start at 1 KiB and 256 bytes respectively, growing automatically when needed.

Connection and prefork memory usage can be configured explicitly:

```c3
ServerOptions options = c3ttp::default_server_options();
options.max_connections = 512; // Default: 1024; zero means unlimited.
Server server;
server.init(mem, "127.0.0.1", 8080, 64, options);
server.serve_prefork(&handler, 4)!!; // Explicit worker count; zero uses CPU count.
```

`max_connections` applies to each event loop, so in prefork mode the process-wide theoretical maximum is the per-worker limit multiplied by the worker count.
