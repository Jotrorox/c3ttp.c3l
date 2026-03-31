module c3ttp;

import std::core::test;
import std::io;
import std::net::tcp;
import std::net::os;
import std::thread;

fn void? handle_ping(Request* request, Response* response, void* context)
{
	test::eq("GET", request.method);
	test::eq("/ping", request.target);
	response.status = 200;
	response.set_body("pong");
	response.set_header("Content-Type", "text/plain");
}

fn void? init_buffer(io::ByteBuffer* buffer, String contents = "")
{
	buffer.tinit(contents.len + 16);
	if (contents) buffer.write(contents)!;
}

fn usz count_headers(HeaderList* headers, String name)
{
	usz count;
	foreach (header : *headers)
	{
		if (header_name_eq(header.name, name)) count++;
	}
	return count;
}

fn void request_roundtrip() @test
{
	Request request;
	request.init(tmem, "POST", "/echo", "hello");
	defer request.free();
	request.set_header("Host", "example.com");
	request.set_header("Content-Type", "text/plain");

	io::ByteBuffer buffer;
	buffer.tinit(80);
	defer buffer.free();

	write_request(&buffer, &request)!!;
	Request parsed = read_request(tmem, &buffer)!!;
	defer parsed.free();

	test::eq("POST", parsed.method);
	test::eq("/echo", parsed.target);
	test::eq("hello", parsed.body);
	test::eq("text/plain", parsed.header("content-type")!!);
	test::eq("5", parsed.header("Content-Length")!!);
}

fn void zero_length_request_roundtrip() @test
{
	Request request;
	request.init(tmem, "GET", "/empty");
	defer request.free();
	request.set_header("Host", "example.com");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	write_request(&buffer, &request)!!;
	Request parsed = read_request(tmem, &buffer)!!;
	defer parsed.free();

	test::eq("", parsed.body);
	test::eq("0", parsed.header("Content-Length")!!);
}

fn void response_roundtrip() @test
{
	Response response;
	response.init(tmem, 201, "Created", "{\"ok\":true}");
	defer response.free();
	response.set_header("Content-Type", "application/json");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	write_response(&buffer, &response)!!;
	Response parsed = read_response(tmem, &buffer)!!;
	defer parsed.free();

	test::eq(201, parsed.status);
	test::eq("Created", parsed.reason);
	test::eq("{\"ok\":true}", parsed.body);
	test::eq("application/json", parsed.header("CONTENT-TYPE")!!);
}

fn void zero_length_response_roundtrip() @test
{
	Response response;
	response.init(tmem, 204, "No Content");
	defer response.free();

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	write_response(&buffer, &response)!!;
	Response parsed = read_response(tmem, &buffer)!!;
	defer parsed.free();

	test::eq(204, parsed.status);
	test::eq("", parsed.body);
	test::eq("0", parsed.header("Content-Length")!!);
}

fn void invalid_status_line_without_reason() @test
{
	io::ByteBuffer buffer;
	buffer.tinit(48);
	defer buffer.free();

	buffer.write("HTTP/1.1 204\r\nContent-Length: 0\r\n\r\n")!!;
	test::@error(read_response(tmem, &buffer), INVALID_STATUS_LINE);
}

fn void invalid_request_header_without_separator() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nHost: example.com\r\nBroken\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), INVALID_HEADER);
}

fn void invalid_request_header_without_name() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nHost: example.com\r\n: value\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), INVALID_HEADER);
}

fn void invalid_response_header_without_separator() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nBroken\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_response(tmem, &buffer), INVALID_HEADER);
}

fn void duplicate_request_host_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), DUPLICATE_HEADER);
}

fn void duplicate_request_content_length_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), DUPLICATE_HEADER);
}

fn void duplicate_response_content_length_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_response(tmem, &buffer), DUPLICATE_HEADER);
}

fn void duplicate_request_non_singleton_headers_are_preserved() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nHost: example.com\r\nX-Test: first\r\nX-Test: second\r\n\r\n")!!;
	defer buffer.free();

	Request request = read_request(tmem, &buffer)!!;
	defer request.free();

	test::eq("first", request.header("X-Test")!!);
	test::eq(2, count_headers(&request.headers, "x-test"));
}

fn void duplicate_response_non_singleton_headers_are_preserved() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nX-Test: first\r\nX-Test: second\r\nContent-Length: 0\r\n\r\n")!!;
	defer buffer.free();

	Response response = read_response(tmem, &buffer)!!;
	defer response.free();

	test::eq("first", response.header("X-Test")!!);
	test::eq(2, count_headers(&response.headers, "x-test"));
}

fn void request_without_host_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), MISSING_HOST);
}

fn void unsupported_request_method_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "BREW /coffee HTTP/1.1\r\nHost: example.com\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), UNSUPPORTED_METHOD);
}

fn void lowercase_request_method_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "get / HTTP/1.1\r\nHost: example.com\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), UNSUPPORTED_METHOD);
}

fn void write_request_rejects_unsupported_method() @test
{
	Request request;
	request.init(tmem, "BREW", "/coffee");
	defer request.free();
	request.set_header("Host", "example.com");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	test::@error(write_request(&buffer, &request), UNSUPPORTED_METHOD);
}

struct ServeOnceArgs
{
	Server* server;
}

struct RespondOnceArgs
{
	tcp::TcpSocket* socket;
}

fn int serve_once_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		ServeOnceArgs* args = arg;
		if (catch args.server.serve_once(&handle_ping)) return 1;
		return 0;
	};
}

fn int respond_once_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		RespondOnceArgs* args = arg;
		if (catch respond_once(mem, args.socket, &handle_ping))
		{
			if (catch args.socket.close()) {}
			return 1;
		}
		if (catch args.socket.close()) {}
		return 0;
	};
}

fn uint? bind_test_server(Server* server)
{
	for (uint port = 18080; port < 18112; port++)
	{
		server.init(mem, "127.0.0.1", port);
		if (catch server.listen())
		{
			server.free();
			continue;
		}
		return port;
	}
	return io::GENERAL_ERROR~;
}

fn void tcp_listener_roundtrip() @test
{
	Server server;
	defer server.free();
	uint port = bind_test_server(&server)!!;

	ServeOnceArgs args = { .server = &server };
	thread::Thread worker;
	worker.create(&serve_once_thread, &args)!!;

	Request request;
	request.init(tmem, "GET", "/ping");
	defer request.free();
	request.set_header("Host", string::tformat("127.0.0.1:%d", port));
	request.set_header("Connection", "close");

	Client client = new_client();
	Response response = client.send(tmem, "127.0.0.1", port, &request)!!;
	defer response.free();

	test::eq(0, worker.join()!!);
	test::eq(200, response.status);
	test::eq("pong", response.body);
	test::eq("text/plain", response.header("content-type")!!);
}

fn void respond_once_sets_connection_close_and_closes_socket() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	RespondOnceArgs args = { .socket = &pair.recv };
	thread::Thread worker;
	worker.create(&respond_once_thread, &args)!!;

	pair.send.write("GET /ping HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")!!;
	Response response = read_response(tmem, &pair.send)!!;
	defer response.free();

	test::eq("close", response.header("connection")!!);
	test::eq(0, worker.join()!!);

	pair.send.sock.set_non_blocking(true)!!;
	defer catch (void)pair.send.sock.set_non_blocking(false);

	char[1] extra = {};
	usz? n = pair.send.read(extra[..]);
	if (catch err = n)
	{
		test::@check(false, "expected peer close, got %s", err);
	}
	if (try bytes_read = n)
	{
		test::eq(0, bytes_read);
	}
}
