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
- `Content-Length` bodies
- simple client requests over TCP
- simple server accept / handle / respond flow

Out of scope for now:

- chunked transfer encoding
- TLS / HTTPS
- HTTP/2+

## Build Tests

```bash
c3c compile-test c3ttp.c3 c3ttp_test.c3 -O0
```

## Example Builds

```bash
c3c compile examples/hello_server.c3 --libdir . --lib c3ttp -O0 -o hello_server
c3c compile examples/client_get.c3 --libdir . --lib c3ttp -O0 -o client_get
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
