module c3ttp;

import std::core::test;
import std::io;
import std::net::tcp;
import std::thread;
import std::time;

int persistent_request_count;

fn void? handle_counted_persistent(Request* request, Response* response, void* context)
{
	persistent_request_count++;
	response.status = 200;
	response.set_body(string::tformat("req-%d", persistent_request_count));
	if (persistent_request_count >= 2) response.set_header("Connection", "close");
}

fn void? handle_close_immediately(Request* request, Response* response, void* context)
{
	response.status = 200;
	response.set_body("once");
	response.set_header("Connection", "close");
}

struct ConnTestArgs
{
	Server* server;
}

fn int serve_persistent_once_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		ConnTestArgs* args = arg;
		if (catch args.server.serve_once(&handle_counted_persistent)) return 1;
		return 0;
	};
}

fn int serve_close_once_thread(void* arg)
{
	@pool_init(mem, 4096)
	{
		ConnTestArgs* args = arg;
		if (catch args.server.serve_once(&handle_close_immediately)) return 1;
		return 0;
	};
}

fn void connection_reuses_socket_for_multiple_requests() @test
{
	persistent_request_count = 0;

	Server server;
	defer server.free();
	server.init(mem, "127.0.0.1", 0);
	server.listen()!!;
	uint port = server.port;

	ConnTestArgs args = { .server = &server };
	thread::Thread worker;
	worker.create(&serve_persistent_once_thread, &args)!!;

	Client client = new_client();
	Connection conn = client.connect("127.0.0.1", port)!!;
	defer conn.close();

	Request request;
	request.init(tmem, "GET", "/ping");
	defer request.free();
	request.set_header("Host", string::tformat("127.0.0.1:%d", port));

	Response first = conn.send(tmem, &request)!!;
	defer first.free();
	test::eq(200, first.status);
	test::eq("req-1", first.body);
	test::eq(true, conn.alive);

	Response second = conn.send(tmem, &request)!!;
	defer second.free();
	test::eq(200, second.status);
	test::eq("req-2", second.body);
	test::eq(false, conn.alive);

	test::eq(0, worker.join()!!);
}

fn void connection_closes_when_server_sends_close() @test
{
	Server server;
	defer server.free();
	server.init(mem, "127.0.0.1", 0);
	server.listen()!!;
	uint port = server.port;

	ConnTestArgs args = { .server = &server };
	thread::Thread worker;
	worker.create(&serve_close_once_thread, &args)!!;

	Client client = new_client();
	Connection conn = client.connect("127.0.0.1", port)!!;
	defer conn.close();

	Request request;
	request.init(tmem, "GET", "/ping");
	defer request.free();
	request.set_header("Host", string::tformat("127.0.0.1:%d", port));

	Response response = conn.send(tmem, &request)!!;
	defer response.free();
	test::eq(200, response.status);
	test::eq("once", response.body);
	test::eq(false, conn.alive);

	test::eq(0, worker.join()!!);
}

fn void connection_closes_when_request_has_close() @test
{
	Server server;
	defer server.free();
	server.init(mem, "127.0.0.1", 0);
	server.listen()!!;
	uint port = server.port;

	ConnTestArgs args = { .server = &server };
	thread::Thread worker;
	worker.create(&serve_close_once_thread, &args)!!;

	Client client = new_client();
	Connection conn = client.connect("127.0.0.1", port)!!;
	defer conn.close();

	Request request;
	request.init(tmem, "GET", "/ping");
	defer request.free();
	request.set_header("Host", string::tformat("127.0.0.1:%d", port));
	request.set_header("Connection", "close");

	Response response = conn.send(tmem, &request)!!;
	defer response.free();
	test::eq(200, response.status);
	test::eq("once", response.body);
	test::eq(false, conn.alive);

	test::eq(0, worker.join()!!);
}

fn void connection_send_on_closed_returns_error() @test
{
	Server server;
	defer server.free();
	server.init(mem, "127.0.0.1", 0);
	server.listen()!!;
	uint port = server.port;

	ConnTestArgs args = { .server = &server };
	thread::Thread worker;
	worker.create(&serve_close_once_thread, &args)!!;

	Client client = new_client();
	Connection conn = client.connect("127.0.0.1", port)!!;
	defer conn.close();

	Request request;
	request.init(tmem, "GET", "/ping");
	defer request.free();
	request.set_header("Host", string::tformat("127.0.0.1:%d", port));

	Response first = conn.send(tmem, &request)!!;
	defer first.free();
	test::eq(false, conn.alive);

	test::@error(conn.send(tmem, &request), CONNECTION_CLOSED);

	test::eq(0, worker.join()!!);
}
