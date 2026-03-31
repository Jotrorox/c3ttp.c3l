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
- `Server`

Supported faults:

- `INVALID_REQUEST_LINE`
- `INVALID_STATUS_LINE`
- `INVALID_HEADER`
- `INVALID_CHUNK`
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
- `Server.init/listen/close/free/serve_once/serve`

Supported top-level API:

- `c3ttp::new_client`
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
c3c compile-test c3ttp.c3i c3ttp.c3 c3ttp_test.c3 -O0
```

## Example Builds

```bash
c3c compile examples/hello_server.c3 --libdir .. --lib c3ttp -O0 -o hello_server
c3c compile examples/client_get.c3 --libdir .. --lib c3ttp -O0 -o client_get
```

## Example: Server

```c3
module hello_server;
import c3ttp, std::io;

fn void? hello(Request* request, Response* response, void* context)
{
	response.set_body("hello from c3ttp\n");
	response.set_header("Content-Type", "text/plain; charset=utf-8");
}

fn int main()
{
	Server server;
	server.init(tmem, "127.0.0.1", 8080);
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
