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

fn void? handle_ping_keep_alive(Request* request, Response* response, void* context)
{
	handle_ping(request, response, context)!;
	response.set_header("Connection", "keep-alive");
}

fn void? handle_head_ping(Request* request, Response* response, void* context)
{
	test::eq("HEAD", request.method);
	test::eq("/ping", request.target);
	response.status = 200;
	response.set_body("pong");
	response.set_header("Content-Type", "text/plain");
}

struct RequestCounter
{
	int value;
}

fn void? handle_count(Request* request, Response* response, void* context)
{
	RequestCounter* counter = context;
	counter.value++;
	response.status = 200;
	response.set_body(string::tformat("request-%d", counter.value));
	if (request.target == "/close") response.set_header("Connection", "close");
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

fn void informational_response_roundtrip_has_no_body() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 100 Continue\r\nContent-Length: 4\r\n\r\nbodytail")!!;
	defer buffer.free();

	Response response = read_response(tmem, &buffer)!!;
	defer response.free();

	test::eq(100, response.status);
	test::eq("", response.body);
	test::eq("bodytail", (String)buffer.bytes[buffer.read_idx:8]);
}

fn void no_content_response_writer_suppresses_body() @test
{
	Response response;
	response.init(tmem, 204, "No Content", "ignored");
	defer response.free();

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	write_response(&buffer, &response)!!;

	String encoded = (String)buffer.bytes[:buffer.write_idx];
	test::@check(!encoded.contains("ignored"), "did not expect a 204 response body");
	test::@check(!encoded.contains("Content-Length:"), "did not expect an implicit content-length for 204");
	test::eq("HTTP/1.1 204 No Content\r\n\r\n", encoded);
}

fn void not_modified_response_roundtrip_has_no_body() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 304 Not Modified\r\nContent-Length: 7\r\n\r\npayload")!!;
	defer buffer.free();

	Response response = read_response(tmem, &buffer)!!;
	defer response.free();

	test::eq(304, response.status);
	test::eq("", response.body);
	test::eq("payload", (String)buffer.bytes[buffer.read_idx:7]);
}

fn void head_exchange_does_not_send_or_read_a_response_body() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	RespondOnceArgs args = { .socket = &pair.recv };
	thread::Thread worker;
	worker.create(&respond_head_thread, &args)!!;

	Request request;
	request.init(tmem, "HEAD", "/ping");
	defer request.free();
	request.set_header("Host", "example.com");
	request.set_header("Connection", "close");

	Response response = exchange(tmem, &pair.send, &request)!!;
	defer response.free();

	test::eq(200, response.status);
	test::eq("", response.body);
	test::eq("4", response.header("Content-Length")!!);
	test::eq(0, worker.join()!!);
}

fn void chunked_request_roundtrip() @test
{
	Request request;
	request.init(tmem, "POST", "/chunked", "hello world");
	defer request.free();
	request.set_header("Host", "example.com");
	request.set_header("Transfer-Encoding", "chunked");

	io::ByteBuffer buffer;
	buffer.tinit(96);
	defer buffer.free();

	write_request(&buffer, &request)!!;

	String encoded = (String)buffer.bytes[:buffer.write_idx];
	test::@check(encoded.contains("Transfer-Encoding: chunked\r\n"), "expected chunked transfer encoding header");
	test::@check(!encoded.contains("Content-Length:"), "did not expect content-length header");
	test::@check(encoded.contains("\r\nb\r\nhello world\r\n0\r\n\r\n"), "expected chunked body");

	Request parsed = read_request(tmem, &buffer)!!;
	defer parsed.free();

	test::eq("hello world", parsed.body);
	test::eq("chunked", parsed.header("Transfer-Encoding")!!);
}

fn void chunked_response_roundtrip() @test
{
	Response response;
	response.init(tmem, 200, "OK", "chunk-response");
	defer response.free();
	response.set_header("Transfer-Encoding", "chunked");

	io::ByteBuffer buffer;
	buffer.tinit(96);
	defer buffer.free();

	write_response(&buffer, &response)!!;

	String encoded = (String)buffer.bytes[:buffer.write_idx];
	test::@check(encoded.contains("Transfer-Encoding: chunked\r\n"), "expected chunked transfer encoding header");
	test::@check(!encoded.contains("Content-Length:"), "did not expect content-length header");
	test::@check(encoded.contains("\r\ne\r\nchunk-response\r\n0\r\n\r\n"), "expected chunked body");

	Response parsed = read_response(tmem, &buffer)!!;
	defer parsed.free();

	test::eq("chunk-response", parsed.body);
	test::eq("chunked", parsed.header("Transfer-Encoding")!!);
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
	test::@error(parsed.header("Content-Length"), INVALID_HEADER);
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

fn void invalid_chunked_request_body_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\nbogus\r\nhello\r\n0\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), INVALID_CHUNK);
}

fn void conflicting_chunked_and_content_length_are_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n5\r\nhello\r\n0\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_response(tmem, &buffer), CONFLICTING_BODY_HEADERS);
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

fn void send_url_rejects_unsupported_scheme() @test
{
	Client client = new_client();

	test::@error(client.send_url(tmem, "GET", "https://example.com/"), UNSUPPORTED_SCHEME);
	test::@error(client.send_url(tmem, "GET", "mailto:user@example.com"), UNSUPPORTED_SCHEME);
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

fn int respond_keep_alive_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		RespondOnceArgs* args = arg;
		if (catch respond_once(mem, args.socket, &handle_ping_keep_alive))
		{
			if (catch args.socket.close()) {}
			return 1;
		}
		return 0;
	};
}

fn int respond_head_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		RespondOnceArgs* args = arg;
		if (catch respond_once(mem, args.socket, &handle_head_ping))
		{
			if (catch args.socket.close()) {}
			return 1;
		}
		if (catch args.socket.close()) {}
		return 0;
	};
}

struct RespondArgs
{
	tcp::TcpSocket* socket;
	RequestCounter* counter;
}

fn int respond_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		RespondArgs* args = arg;
		if (catch respond(mem, args.socket, &handle_count, 0, args.counter))
		{
			if (catch args.socket.close()) {}
			return 1;
		}
		if (catch args.socket.close()) {}
		return 0;
	};
}

fn void tcp_listener_roundtrip() @test
{
	Server server;
	defer server.free();
	server.init(mem, "127.0.0.1", 0);
	server.listen()!!;
	uint port = server.port;

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

fn void server_listen_with_ephemeral_port_updates_server_port() @test
{
	Server server;
	defer server.free();
	server.init(mem, "127.0.0.1", 0);

	server.listen()!!;

	test::eq(true, server.is_listening);
	test::ne(0u, server.port);
}

fn void serve_once_uses_existing_listener_without_rebinding() @test
{
	Server server;
	defer server.free();
	server.init(mem, "127.0.0.1", 0);
	server.listen()!!;
	uint port = server.port;

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
	test::eq(port, server.port);
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

fn void respond_once_keeps_socket_open_when_handler_allows_it() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	RespondOnceArgs args = { .socket = &pair.recv };
	thread::Thread worker;
	worker.create(&respond_keep_alive_thread, &args)!!;

	pair.send.write("GET /ping HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n")!!;
	Response response = read_response(tmem, &pair.send)!!;
	defer response.free();

	test::eq("keep-alive", response.header("connection")!!);
	test::eq(0, worker.join()!!);

	pair.send.write("x")!!;
}

fn void respond_reuses_connection_until_close() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	RequestCounter counter;
	RespondArgs args = { .socket = &pair.recv, .counter = &counter };
	thread::Thread worker;
	worker.create(&respond_thread, &args)!!;

	pair.send.write("GET /first HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n")!!;
	Response first = read_response(tmem, &pair.send)!!;
	defer first.free();
	test::eq("request-1", first.body);

	pair.send.write("GET /close HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")!!;
	Response second = read_response(tmem, &pair.send)!!;
	defer second.free();
	test::eq("request-2", second.body);
	test::eq("close", second.header("Connection")!!);

	test::eq(0, worker.join()!!);
}

fn void server_serve_once_reuses_connection_until_close() @test
{
	Server server;
	defer server.free();
	server.init(mem, "127.0.0.1", 0);
	server.listen()!!;
	uint port = server.port;

	ServeOnceArgs args = { .server = &server };
	thread::Thread worker;
	worker.create(&serve_once_thread, &args)!!;

	tcp::TcpSocket socket = tcp::connect("127.0.0.1", port)!!;
	defer catch (void)socket.close();

	Request first_request;
	first_request.init(tmem, "GET", "/ping");
	defer first_request.free();
	first_request.set_header("Host", string::tformat("127.0.0.1:%d", port));
	first_request.set_header("Connection", "keep-alive");

	Response first = exchange(tmem, &socket, &first_request)!!;
	defer first.free();
	test::eq("pong", first.body);

	Request second_request;
	second_request.init(tmem, "GET", "/ping");
	defer second_request.free();
	second_request.set_header("Host", string::tformat("127.0.0.1:%d", port));
	second_request.set_header("Connection", "close");

	Response second = exchange(tmem, &socket, &second_request)!!;
	defer second.free();
	test::eq("pong", second.body);
	test::eq("close", second.header("Connection")!!);

	test::eq(0, worker.join()!!);
}
