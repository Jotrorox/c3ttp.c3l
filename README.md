# c3ttp

`c3ttp` is a small HTTP/1.1 client and server library written in plain C3 on top of `std::net::tcp`.

It focuses on:

- idiomatic C3 data types and stream handling
- no `extern` wrappers in the library itself
- simple request/response parsing and writing
- integrated `@test` coverage
- contracts on the public API

Current scope:

- HTTP/1.1 request and response parsing
- `Content-Length` and `Transfer-Encoding: chunked` bodies
- chunked trailers on buffered and streaming paths
- simple client requests over TCP
- simple server accept / handle / respond flow
- persistent HTTP/1.1 connections when neither side asks to close

Validation rules:

- request methods are limited to `GET`, `HEAD`, `POST`, `PUT`, `DELETE`, `OPTIONS`, `PATCH`, `TRACE`, and `CONNECT`
- request targets support origin-form, absolute-form, authority-form for `CONNECT`, and asterisk-form for `OPTIONS *`
- request writers validate both request-target shape and `Host` header syntax
- parsed HTTP/1.1 requests must include `Host`
- duplicate singleton headers are rejected for `Host`, `Content-Length`, `Transfer-Encoding`, and `Connection`
- `Transfer-Encoding: chunked` cannot be combined with `Content-Length`
- only plain `Transfer-Encoding: chunked` is accepted for chunked body parsing and writing
- forbidden trailer fields such as `Content-Length` and `Transfer-Encoding` are rejected
- responses to `HEAD` and responses with status `1xx`, `204`, or `304` are treated as having no message body
- `respond_once` preserves HTTP/1.1 keep-alive unless the request or response asks to close
- `Client.send_url` accepts plain `http` URLs, builds correct origin-form targets, and rejects unsupported schemes explicitly

Out of scope for now:

- TLS / HTTPS
- HTTP/2+

## Public API

[`c3ttp.c3i`](/home/johannes/projects/c3ttp.c3l/c3ttp.c3i) is the source of truth for the supported public surface.

Supported types:

- `Header`
- `HeaderList`
- `Handler`
- `Request`
- `Response`
- `Client`
- `ResourceLimits`
- `ServerTimeouts`
- `ServerOptions`
- `Server`

Supported faults:

- `INVALID_REQUEST_LINE`
- `INVALID_STATUS_LINE`
- `INVALID_HEADER`
- `INVALID_CHUNK`
- `REQUEST_LINE_TOO_LARGE`
- `HEADER_LINE_TOO_LARGE`
- `TOO_MANY_HEADERS`
- `HEADERS_TOO_LARGE`
- `BUFFERED_BODY_TOO_LARGE`
- `CHUNK_TOO_LARGE`
- `CHUNKED_BODY_TOO_LARGE`
- `READ_TIMEOUT`
- `WRITE_TIMEOUT`
- `IDLE_TIMEOUT`
- `HEADER_TIMEOUT`
- `INVALID_VERSION`
- `INVALID_TARGET`
- `INVALID_HOST`
- `INVALID_TRAILER`
- `CONFLICTING_BODY_HEADERS`
- `MISSING_HOST`
- `UNSUPPORTED_SCHEME`
- `UNSUPPORTED_TRANSFER_ENCODING`
- `UNSUPPORTED_METHOD`
- `DUPLICATE_HEADER`

Supported method-style API:

- `Request.init/free/set_body/header/set_header/add_header`
- `Response.init/free/set_body/header/set_header/add_header`
- `Client.send/send_url`
- `Server.init/set_limits/set_timeouts/listen/close/free/serve_once/serve`

Supported top-level API:

- `c3ttp::new_client`
- `c3ttp::default_resource_limits`
- `c3ttp::default_server_timeouts`
- `c3ttp::default_server_options`
- `c3ttp::read_request`
- `c3ttp::read_request_to`
- `c3ttp::read_response`
- `c3ttp::read_response_to`
- `c3ttp::write_request`
- `c3ttp::write_request_from`
- `c3ttp::write_response`
- `c3ttp::write_response_from`
- `c3ttp::exchange`
- `c3ttp::respond_once`
- `c3ttp::respond`

Additional public data carried by parsed messages:

- `Request.trailers`
- `Response.trailers`

Not part of the intentional public API:

- `HTTP_11`
- `Request.header_ref`
- `Response.header_ref`

## Build Tests

```bash
c3c compile-test .
```

## Example Builds

```bash
c3c compile c3ttp.c3i c3ttp.c3 examples/hello_server.c3 -O0 -o hello_server
c3c compile c3ttp.c3i c3ttp.c3 examples/client_get.c3 -O0 -o client_get
```

## Example: Server

```c3
module hello_server;
import c3ttp, std::io, std::time;

fn void? hello(Request* request, Response* response, void* context)
{
	response.set_body("hello from c3ttp\n");
	response.set_header("Content-Type", "text/plain; charset=utf-8");
}

fn int main()
{
	ServerOptions options = c3ttp::default_server_options();
	options.limits.max_buffered_body_size = 256 * 1024;
	options.limits.max_chunked_body_size = 512 * 1024;
	options.timeouts.header_timeout = time::sec(5);
	options.timeouts.idle_timeout = time::sec(10);

	Server server;
	server.init(tmem, "127.0.0.1", 8080, 64, options);
	defer server.free();

	io::printn("Serving one request on http://127.0.0.1:8080");
	server.serve(&hello, 1)!!;
	return 0;
}
```

## Example: Client

```c3
module client_get;
import c3ttp, std::io;

fn int main()
{
	Client client = c3ttp::new_client();
	Response response = client.send_url(tmem, "GET", "http://example.com/")!!;
	defer response.free();

	io::printfn("%d %s", response.status, response.reason);
	io::printn(response.body);
	return 0;
}
```

## Streaming Bodies

The existing `read_request`, `read_response`, `write_request`, and `write_response`
APIs still buffer bodies in memory.

For large bodies, use the explicit streaming APIs:

```c3
io::ByteWriter sink;
sink.tinit();
defer sink.destroy()!!;

Response response = c3ttp::read_response_to(tmem, &socket, &sink)!!;
defer response.free();
```

```c3
io::ByteReader source;
source.init((char[])"payload");

Request request;
request.init(tmem, "POST", "/upload");
defer request.free();
request.set_header("Host", "example.com");

c3ttp::write_request_from(&socket, &request, &source, 7)!!;
```

When `Transfer-Encoding: chunked` is set, `write_request_from` and
`write_response_from` stream until EOF on the body source and emit any
entries present in `request.trailers` or `response.trailers`.

## Limits And Timeouts

Buffered parsers and the built-in server now expose explicit hard limits.

- `ResourceLimits.max_request_line_size`
- `ResourceLimits.max_header_line_size`
- `ResourceLimits.max_header_count`
- `ResourceLimits.max_total_header_bytes`
- `ResourceLimits.max_buffered_body_size`
- `ResourceLimits.max_chunk_size`
- `ResourceLimits.max_chunked_body_size`

All `read_request`, `read_request_to`, `read_response`, and `read_response_to`
entry points accept an optional `ResourceLimits` argument. If omitted, the
library uses conservative defaults suitable for general HTTP/1.1 use.

`ServerOptions.timeouts` controls socket-level server behavior:

- `header_timeout`: maximum time to receive the request line and header block
- `read_timeout`: maximum time to receive a request body after headers are complete
- `idle_timeout`: maximum keep-alive idle time before the next request starts
- `write_timeout`: maximum time allowed while sending the response

Example parser hardening:

```c3
ResourceLimits limits = c3ttp::default_resource_limits();
limits.max_buffered_body_size = 128 * 1024;
limits.max_chunked_body_size = 256 * 1024;

Request request = c3ttp::read_request(tmem, &socket, limits)!!;
defer request.free();
```
