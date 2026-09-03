module c3ttp;

import std::core::test;

fn void parses_complete_request_without_copying() @test
{
	String wire = "GET /hello?q=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: c3ttp-test\r\nConnection: close\r\n\r\n";
	test::eq((usz)3, find_byte((char[])wire, 0, ' '));
	test::eq((usz)14, find_byte((char[])wire, 4, ' '));
	RequestParser parser;
	parser.init();
	test::eq(ParseStatus.COMPLETE, parser.parse((char[])wire)!!);
	test::eq(Method.GET, parser.request.method_id);
	test::eq("GET", parser.request.method);
	test::eq("/hello?q=1", parser.request.target);
	test::eq("example.com", parser.request.header(HOST)!!);
	test::eq("c3ttp-test", parser.request.header(USER_AGENT)!!);
	test::eq(false, parser.request.keep_alive);
	test::eq((uptr)wire.ptr, (uptr)parser.request.method.ptr);
	test::eq((usz)wire.len, parser.request.message_length);
}

fn void parses_incrementally_from_cumulative_buffer() @test
{
	String wire = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello";
	RequestParser parser;
	parser.init();
	for (usz length = 1; length < wire.len; length++)
	{
		test::eq(ParseStatus.NEED_MORE, parser.parse((char[])wire[:length])!!);
	}
	test::eq(ParseStatus.COMPLETE, parser.parse((char[])wire)!!);
	test::eq("hello", parser.request.body);
	test::eq((usz)5, parser.request.body_length);
}

fn void rejects_replaced_or_shrinking_incremental_buffer() @test
{
	String first = "GET / HTTP/1.1\r\nHost:";
	String replacement = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
	RequestParser parser;
	parser.init();
	test::eq(ParseStatus.NEED_MORE, parser.parse((char[])first)!!);
	test::@error(parser.parse((char[])replacement), INVALID_INPUT_BUFFER);

	parser.init();
	test::eq(ParseStatus.NEED_MORE, parser.parse((char[])replacement[:20])!!);
	test::@error(parser.parse((char[])replacement[:19]), INVALID_INPUT_BUFFER);
}

fn void parses_chunked_body_as_zero_copy_slices() @test
{
	String wire = "POST /chunks HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: yes\r\n\r\n";
	RequestParser parser;
	parser.init();
	for (usz length = 1; length < wire.len; length++)
	{
		test::eq(ParseStatus.NEED_MORE, parser.parse((char[])wire[:length])!!);
	}
	test::eq(ParseStatus.COMPLETE, parser.parse((char[])wire)!!);
	test::eq(true, parser.request.chunked);
	test::eq((usz)2, parser.request.chunk_count);
	test::eq("Wiki", parser.request.body_chunks()[0]);
	test::eq("pedia", parser.request.body_chunks()[1]);
	test::eq((usz)9, parser.request.body_length);
}

fn void rejects_smuggling_prone_framing() @test
{
	String wire = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n";
	RequestParser parser;
	parser.init();
	test::@error(parser.parse((char[])wire), CONFLICTING_BODY_HEADERS);
}

fn void stops_at_first_pipelined_request() @test
{
	String first = "GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n";
	String wire = "GET /one HTTP/1.1\r\nHost: localhost\r\n\r\nGET /two HTTP/1.1\r\nHost: localhost\r\n\r\n";
	RequestParser parser;
	parser.init();
	test::eq(ParseStatus.COMPLETE, parser.parse((char[])wire)!!);
	test::eq("/one", parser.request.target);
	test::eq((usz)first.len, parser.request.message_length);
}

fn void rejects_overflowing_content_length_and_chunk_size() @test
{
	String fixed = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 184467440737095516160\r\n\r\n";
	RequestParser parser;
	parser.init();
	test::@error(parser.parse((char[])fixed), INVALID_CONTENT_LENGTH);

	String chunked = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n100000000000000000\r\n";
	parser.init();
	test::@error(parser.parse((char[])chunked), BODY_TOO_LARGE);
}

fn void enforces_request_and_header_limits_incrementally() @test
{
	Limits limits = default_limits();
	limits.max_request_line = 8;
	RequestParser parser;
	parser.init(limits);
	String request = "GET /too-long HTTP/1.1";
	test::@error(parser.parse((char[])request), REQUEST_LINE_TOO_LARGE);

	limits = default_limits();
	limits.max_header_line = 4;
	parser.init(limits);
	String header = "GET / HTTP/1.1\r\nHost: localhost";
	test::@error(parser.parse((char[])header), HEADER_LINE_TOO_LARGE);
}

fn void requires_host_for_http11() @test
{
	String wire = "GET / HTTP/1.1\r\nAccept: */*\r\n\r\n";
	RequestParser parser;
	parser.init();
	test::@error(parser.parse((char[])wire), MISSING_HOST);
}

fn void classifies_headers_case_insensitively() @test
{
	String wire = "GET / HTTP/1.1\r\nhOsT: localhost\r\ncontent-type: text/plain\r\n\r\n";
	RequestParser parser;
	parser.init();
	test::eq(ParseStatus.COMPLETE, parser.parse((char[])wire)!!);
	test::eq("text/plain", parser.request.header(CONTENT_TYPE)!!);
	test::eq("localhost", parser.request.header_name("HOST")!!);
}

fn void linux_io_uring_abi_layouts_are_stable() @test @feat(LINUX)
{
	test::eq((usz)64, (usz)IoUringSqe::size);
	test::eq((usz)16, (usz)IoUringCqe::size);
	test::eq((usz)120, (usz)IoUringParams::size);
}

fn void rejects_forbidden_chunk_trailer() @test
{
	String wire = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 10\r\n\r\n";
	RequestParser parser;
	parser.init();
	test::@error(parser.parse((char[])wire), INVALID_HEADER);
}

fn void rejects_simd_scanned_control_in_header_value() @test
{
	String wire = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Long: 01234567890123456789012345678901\u0001\r\n\r\n";
	RequestParser parser;
	parser.init();
	test::@error(parser.parse((char[])wire), INVALID_HEADER);
}

fn void response_framing_obeys_bodyless_status_rules() @test @feat(LINUX)
{
	HotConnection connection;
	connection.response = { .status = 204, .body = "must-not-be-sent" };
	connection.suppress_body = true;
	test::eq(true, build_response_header(&connection));
	String header = (String)connection.response_header[:connection.header_length];
	test::eq(false, header.contains("Content-Length"));
	test::eq(false, response_has_body(304, GET));
	test::eq(false, response_has_body(200, HEAD));
	test::eq(true, response_has_body(200, GET));
}
