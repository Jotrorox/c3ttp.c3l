module c3ttp;

import std::core::test;
import std::io;

fn void? handle_ping(Request* request, Response* response, void* context)
{
	test::eq("GET", request.method);
	test::eq("/ping", request.target);
	response.status = 200;
	response.set_body("pong");
	response.set_header("Content-Type", "text/plain");
}

fn void request_roundtrip() @test
{
	Request request;
	request.init(tmem, "POST", "/echo", "hello");
	defer request.free();
	request.set_header("Content-Type", "text/plain");

	io::ByteBuffer buffer;
	buffer.tinit(64);
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

fn void invalid_status_line_without_reason() @test
{
	io::ByteBuffer buffer;
	buffer.tinit(32);
	defer buffer.free();

	buffer.write("HTTP/1.1 204\r\nContent-Length: 0\r\n\r\n")!!;
	test::@error(read_response(tmem, &buffer), INVALID_STATUS_LINE);
}

fn void socket_roundtrip() @test
{
	io::ByteBuffer buffer;
	buffer.tinit(128);
	defer buffer.free();

	Request request;
	request.init(tmem, "GET", "/ping");
	defer request.free();
	request.set_header("Host", "example.test");
	request.set_header("Connection", "close");

	write_request(&buffer, &request)!!;
	respond_once(tmem, &buffer, &handle_ping)!!;
	Response response = read_response(tmem, &buffer)!!;
	defer response.free();
	test::eq(200, response.status);
	test::eq("pong", response.body);
	test::eq("text/plain", response.header("content-type")!!);
}
