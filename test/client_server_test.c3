module c3ttp;

import std::core::test;
import std::io;
import std::net::tcp;
import std::net::os;
import std::thread;
import std::time;

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

fn void? handle_echo_request_observation(Request* request, Response* response, void* context)
{
	response.status = 200;
	response.set_body(request.target);
	response.set_header("X-Observed-Method", request.method);
	response.set_header("X-Observed-Host", request.header("Host")!!);
}

const usz LARGE_RESPONSE_BODY_SIZE = 16 * 1024 * 1024;

fn void? handle_large_body(Request* request, Response* response, void* context)
{
	DString body = dstring::new_with_capacity(response.allocator, LARGE_RESPONSE_BODY_SIZE);
	defer body.free();
	body.append_repeat('x', LARGE_RESPONSE_BODY_SIZE);
	response.status = 200;
	response.set_body(body.str_view());
	response.set_header("Content-Type", "text/plain");
}

fn ServerOptions tiny_server_options()
{
	ServerOptions options = default_server_options();
	options.timeouts.header_timeout = time::ms(20);
	options.timeouts.read_timeout = time::ms(20);
	options.timeouts.idle_timeout = time::ms(20);
	options.timeouts.write_timeout = time::ms(20);
	return options;
}

struct ServeOnceArgs
{
	Server* server;
}

struct RespondOnceArgs
{
	tcp::TcpSocket* socket;
}

struct RespondArgs
{
	tcp::TcpSocket* socket;
	RequestCounter* counter;
}

struct TimedRespondArgs
{
	tcp::TcpSocket* socket;
	ServerOptions options;
	Handler handler;
	fault expected_fault;
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

fn int serve_once_echo_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		ServeOnceArgs* args = arg;
		if (catch args.server.serve_once(&handle_echo_request_observation)) return 1;
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

fn int timed_respond_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		TimedRespondArgs* args = arg;
		if (catch err = respond_socket_impl(mem, args.socket, args.handler, 0, null, args.options))
		{
			if (err == args.expected_fault) return 0;
			if (catch args.socket.close()) {}
			return 1;
		}
		return 1;
	};
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

fn void send_url_rejects_unsupported_scheme() @test
{
	Client client = new_client();

	test::@error(client.send_url(tmem, "GET", "https://example.com/"), UNSUPPORTED_SCHEME);
	test::@error(client.send_url(tmem, "GET", "mailto:user@example.com"), UNSUPPORTED_SCHEME);
}

fn void respond_socket_header_timeout_is_enforced() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	TimedRespondArgs args = {
		.socket = &pair.recv,
		.options = tiny_server_options(),
		.handler = &handle_ping,
		.expected_fault = HEADER_TIMEOUT
	};
	thread::Thread worker;
	worker.create(&timed_respond_thread, &args)!!;

	test::eq(0, worker.join()!!);
}

fn void respond_socket_read_timeout_is_enforced() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	TimedRespondArgs args = {
		.socket = &pair.recv,
		.options = tiny_server_options(),
		.handler = &handle_ping,
		.expected_fault = READ_TIMEOUT
	};
	thread::Thread worker;
	worker.create(&timed_respond_thread, &args)!!;

	pair.send.write("POST /ping HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhe")!!;
	test::eq(0, worker.join()!!);
}

fn void respond_socket_idle_timeout_is_enforced() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	TimedRespondArgs args = {
		.socket = &pair.recv,
		.options = tiny_server_options(),
		.handler = &handle_ping_keep_alive,
		.expected_fault = IDLE_TIMEOUT
	};
	thread::Thread worker;
	worker.create(&timed_respond_thread, &args)!!;

	pair.send.write("GET /ping HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n")!!;
	Response response = read_response(tmem, &pair.send)!!;
	defer response.free();
	test::eq("pong", response.body);

	test::eq(0, worker.join()!!);
}

fn void respond_socket_write_timeout_is_enforced() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	TimedRespondArgs args = {
		.socket = &pair.recv,
		.options = tiny_server_options(),
		.handler = &handle_large_body,
		.expected_fault = WRITE_TIMEOUT
	};
	thread::Thread worker;
	worker.create(&timed_respond_thread, &args)!!;

	pair.send.write("GET /ping HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")!!;
	thread::sleep(time::ms(80))!!;
	test::eq(0, worker.join()!!);
}

fn void mixed_case_connection_close_is_honored() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	RespondOnceArgs args = { .socket = &pair.recv };
	thread::Thread worker;
	worker.create(&respond_keep_alive_thread, &args)!!;

	pair.send.write("GET /ping HTTP/1.1\r\nHost: example.com\r\nConnection: ClOsE\r\n\r\n")!!;
	Response response = read_response(tmem, &pair.send)!!;
	defer response.free();

	test::eq("close", response.header("Connection")!!);
	test::eq(0, worker.join()!!);
}

fn void connection_close_token_in_list_is_honored_case_insensitively() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	RespondOnceArgs args = { .socket = &pair.recv };
	thread::Thread worker;
	worker.create(&respond_keep_alive_thread, &args)!!;

	pair.send.write("GET /ping HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive, ClOsE\r\n\r\n")!!;
	Response response = read_response(tmem, &pair.send)!!;
	defer response.free();

	test::eq("close", response.header("Connection")!!);
	test::eq(0, worker.join()!!);
}

fn void connection_closed_does_not_match_close_token() @test
{
	tcp::TcpSocketPair pair;
	pair.init()!!;
	defer if (catch pair.destroy()) {}

	RespondOnceArgs args = { .socket = &pair.recv };
	thread::Thread worker;
	worker.create(&respond_keep_alive_thread, &args)!!;

	pair.send.write("GET /ping HTTP/1.1\r\nHost: example.com\r\nConnection: closed\r\n\r\n")!!;
	Response response = read_response(tmem, &pair.send)!!;
	defer response.free();

	test::eq("pong", response.body);
	test::eq("keep-alive", response.header("Connection")!!);
	test::eq(0, worker.join()!!);
}

fn void send_url_builds_origin_form_target_and_host_header() @test
{
	Server server;
	server.init(mem, "127.0.0.1", 0);
	defer server.free();
	server.listen()!!;

	ServeOnceArgs args = { .server = &server };
	thread::Thread worker;
	worker.create(&serve_once_echo_thread, &args)!!;

	Client client = new_client();
	Response response = client.send_url(tmem, "GET", string::tformat("http://127.0.0.1:%d?x=1", server.port))!!;
	defer response.free();

	test::eq(0, worker.join()!!);
	test::eq("GET", response.header("X-Observed-Method")!!);
	test::eq("/?x=1", response.body);
	test::eq(string::tformat("127.0.0.1:%d", server.port), response.header("X-Observed-Host")!!);
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
