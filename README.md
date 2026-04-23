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
c3c compile c3ttp.c3i src/api.c3 src/client_server.c3 src/http.c3 src/io.c3 examples/hello_server.c3 src/router.c3 -Oz -o hello_server
c3c compile c3ttp.c3i src/api.c3 src/client_server.c3 src/http.c3 src/io.c3 examples/client_get.c3 src/router.c3 -Oz -o client_get
```

For long-lived servers, do not initialize `Server` with `tmem`. Use `mem` or another non-temp allocator so per-request allocations can be reclaimed normally across many requests.

See [`c3ttp.c3i`](https://github.com/Jotrorox/c3ttp.c3l/blob/main/c3ttp.c3i) for the supported public surface.

- `Request` / `Response`
- `Client.send` / `Client.send_url`
- `Server.listen` / `Server.serve_once` / `Server.serve`
- `Server.serve_evented` / `Server.serve_prefork`
- `read_request` / `read_response`
- `write_request` / `write_response`
