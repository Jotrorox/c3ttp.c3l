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
const usz LARGE_BATCH_TEST_BODY_SIZE = 9000;

fn void? handle_large_body(Request* request, Response* response, void* context)
{
	DString body = dstring::new_with_capacity(response.allocator, LARGE_RESPONSE_BODY_SIZE);
	defer body.free();
	body.append_repeat('x', LARGE_RESPONSE_BODY_SIZE);
	response.status = 200;
	response.set_body(body.str_view());
	response.set_header("Content-Type", "text/plain");
}

fn ResourceLimits tiny_limits()
{
	ResourceLimits limits = default_resource_limits();
	limits.max_request_line_size = 16;
	limits.max_header_line_size = 16;
	limits.max_header_count = 2;
	limits.max_total_header_bytes = 24;
	limits.max_buffered_body_size = 4;
	limits.max_chunk_size = 3;
	limits.max_chunked_body_size = 5;
	return limits;
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

fn void init_reader(io::ByteReader* reader, String contents)
{
	reader.init((char[])contents);
}

struct CountingBuffer (InStream, OutStream)
{
	io::ByteBuffer buffer;
	usz write_calls;
}

fn CountingBuffer* init_counting_buffer(CountingBuffer* self, usz capacity = 128)
{
	self.buffer.tinit(capacity);
	self.write_calls = 0;
	return self;
}

fn void free_counting_buffer(CountingBuffer* self)
{
	self.buffer.free();
	*self = {};
}

fn sz? CountingBuffer.write(&self, char[] bytes) @dynamic
{
	self.write_calls++;
	return self.buffer.write(bytes)!;
}

fn void? CountingBuffer.write_byte(&self, char c) @dynamic
{
	self.write_calls++;
	self.buffer.write_byte(c)!;
}

fn sz? CountingBuffer.read(&self, char[] bytes) @dynamic
{
	return self.buffer.read(bytes)!;
}

fn char? CountingBuffer.read_byte(&self) @dynamic
{
	return self.buffer.read_byte()!;
}

fn void request_roundtrip() @test
{
	Request request;
	request.init(tmem, "POST", "/echo?x=1", "hello");
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
	test::eq("/echo?x=1", parsed.target);
	test::eq("hello", parsed.body);
	test::eq("text/plain", parsed.header("content-type")!!);
	test::eq("5", parsed.header("Content-Length")!!);
}

fn void absolute_form_request_roundtrip() @test
{
	Request request;
	request.init(tmem, "GET", "http://example.com:8080/path?q=1");
	defer request.free();
	request.set_header("Host", "example.com:8080");

	io::ByteBuffer buffer;
	buffer.tinit(96);
	defer buffer.free();

	write_request(&buffer, &request)!!;
	Request parsed = read_request(tmem, &buffer)!!;
	defer parsed.free();

	test::eq("http://example.com:8080/path?q=1", parsed.target);
	test::eq("example.com:8080", parsed.header("Host")!!);
}

fn void authority_form_connect_roundtrip() @test
{
	Request request;
	request.init(tmem, "CONNECT", "example.com:443");
	defer request.free();
	request.set_header("Host", "example.com:443");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	write_request(&buffer, &request)!!;
	Request parsed = read_request(tmem, &buffer)!!;
	defer parsed.free();

	test::eq("CONNECT", parsed.method);
	test::eq("example.com:443", parsed.target);
}

fn void asterisk_form_options_roundtrip() @test
{
	Request request;
	request.init(tmem, "OPTIONS", "*");
	defer request.free();
	request.set_header("Host", "example.com");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	write_request(&buffer, &request)!!;
	Request parsed = read_request(tmem, &buffer)!!;
	defer parsed.free();

	test::eq("*", parsed.target);
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

fn void chunked_request_trailers_are_preserved() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "POST /trailers HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-Trailer: done\r\n\r\n")!!;
	defer buffer.free();

	Request request = read_request(tmem, &buffer)!!;
	defer request.free();

	test::eq("hello", request.body);
	test::eq("done", get_header(&request.trailers, "X-Trailer")!!);
}

fn void buffered_chunked_request_reads_large_chunk_with_fixed_scratch_buffer() @test
{
	DString chunk_body = dstring::new_with_capacity(tmem, 5000);
	defer chunk_body.free();
	chunk_body.append_repeat('x', 5000);

	DString expected_body = dstring::new_with_capacity(tmem, 5005);
	defer expected_body.free();
	expected_body.append_string(chunk_body.str_view());
	expected_body.append_string("trail");

	DString encoded = dstring::new_with_capacity(tmem, 5200);
	defer encoded.free();
	encoded.append_string("POST /large HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n1388\r\n");
	encoded.append_string(chunk_body.str_view());
	encoded.append_string("\r\n5\r\ntrail\r\n0\r\nX-Trailer: done\r\n\r\n");

	io::ByteBuffer buffer;
	init_buffer(&buffer, encoded.str_view())!!;
	defer buffer.free();

	Request request = read_request(tmem, &buffer)!!;
	defer request.free();

	test::eq(expected_body.str_view(), request.body);
	test::eq("done", get_header(&request.trailers, "X-Trailer")!!);
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

fn void chunked_response_trailers_are_preserved() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\nExpires: soon\r\n\r\n")!!;
	defer buffer.free();

	Response response = read_response(tmem, &buffer)!!;
	defer response.free();

	test::eq("test", response.body);
	test::eq("soon", get_header(&response.trailers, "Expires")!!);
}

fn void write_chunked_response_emits_trailers() @test
{
	Response response;
	response.init(tmem, 200, "OK", "data");
	defer response.free();
	response.set_header("Transfer-Encoding", "chunked");
	response.trailers.push({ .name = "Expires".copy(tmem), .value = "soon".copy(tmem) });

	io::ByteBuffer buffer;
	buffer.tinit(96);
	defer buffer.free();

	write_response(&buffer, &response)!!;

	String encoded = (String)buffer.bytes[:buffer.write_idx];
	test::@check(encoded.contains("0\r\nExpires: soon\r\n\r\n"), "expected chunked trailers");
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

fn void get_asterisk_request_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET * HTTP/1.1\r\nHost: example.com\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), INVALID_TARGET);
}

fn void connect_with_origin_form_is_rejected() @test
{
	Request request;
	request.init(tmem, "CONNECT", "/proxy");
	defer request.free();
	request.set_header("Host", "example.com");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	test::@error(write_request(&buffer, &request), INVALID_HOST);
}

fn void origin_form_without_leading_slash_is_rejected() @test
{
	Request request;
	request.init(tmem, "GET", "relative");
	defer request.free();
	request.set_header("Host", "example.com");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	test::@error(write_request(&buffer, &request), INVALID_TARGET);
}

fn void request_with_invalid_host_port_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nHost: example.com:notaport\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), INVALID_HOST);
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

fn void invalid_chunked_body_missing_crlf_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello0\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_request(tmem, &buffer), INVALID_CHUNK);
}

fn void transfer_encoding_with_extra_tokens_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_response(tmem, &buffer), UNSUPPORTED_TRANSFER_ENCODING);
}

fn void mixed_case_chunked_transfer_encoding_is_accepted() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding: ChUnKeD\r\n\r\n4\r\ntest\r\n0\r\n\r\n")!!;
	defer buffer.free();

	Response response = read_response(tmem, &buffer)!!;
	defer response.free();

	test::eq("test", response.body);
	test::eq("ChUnKeD", response.header("Transfer-Encoding")!!);
}

fn void padded_mixed_case_chunked_transfer_encoding_is_accepted() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding:   ChUnKeD   \r\n\r\n4\r\ntest\r\n0\r\n\r\n")!!;
	defer buffer.free();

	Response response = read_response(tmem, &buffer)!!;
	defer response.free();

	test::eq("test", response.body);
	test::eq("ChUnKeD", response.header("Transfer-Encoding")!!);
}

fn void mixed_case_identity_transfer_encoding_is_accepted() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding: IdEnTiTy\r\n\r\n")!!;
	defer buffer.free();

	Response response = read_response(tmem, &buffer)!!;
	defer response.free();

	test::eq("", response.body);
	test::eq("IdEnTiTy", response.header("Transfer-Encoding")!!);
}

fn void forbidden_chunked_trailer_is_rejected() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\nContent-Length: 1\r\n\r\n")!!;
	defer buffer.free();

	test::@error(read_response(tmem, &buffer), INVALID_TRAILER);
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

fn void write_request_rejects_duplicate_host() @test
{
	Request request;
	request.init(tmem, "GET", "/");
	defer request.free();
	request.headers.push({ .name = "Host".copy(tmem), .value = "a".copy(tmem) });
	request.headers.push({ .name = "Host".copy(tmem), .value = "b".copy(tmem) });

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	test::@error(write_request(&buffer, &request), DUPLICATE_HEADER);
}

fn void write_request_requires_host() @test
{
	Request request;
	request.init(tmem, "GET", "/");
	defer request.free();

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	test::@error(write_request(&buffer, &request), MISSING_HOST);
}

fn void write_response_rejects_duplicate_transfer_encoding() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.headers.push({ .name = "Transfer-Encoding".copy(tmem), .value = "chunked".copy(tmem) });
	response.headers.push({ .name = "Transfer-Encoding".copy(tmem), .value = "identity".copy(tmem) });

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	test::@error(write_response(&buffer, &response), DUPLICATE_HEADER);
}

fn void write_response_rejects_unsupported_transfer_encoding_tokens() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_header("Transfer-Encoding", "gzip, chunked");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	test::@error(write_response(&buffer, &response), UNSUPPORTED_TRANSFER_ENCODING);
}

fn void write_response_rejects_conflicting_chunked_and_content_length() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_header("Transfer-Encoding", "chunked");
	response.set_header("Content-Length", "4");

	io::ByteBuffer buffer;
	buffer.tinit(64);
	defer buffer.free();

	test::@error(write_response(&buffer, &response), CONFLICTING_BODY_HEADERS);
}

fn void send_url_rejects_unsupported_scheme() @test
{
	Client client = new_client();

	test::@error(client.send_url(tmem, "GET", "https://example.com/"), UNSUPPORTED_SCHEME);
	test::@error(client.send_url(tmem, "GET", "mailto:user@example.com"), UNSUPPORTED_SCHEME);
}

fn void read_request_to_streams_content_length_body() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "POST /upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 11\r\n\r\nhello worldtail")!!;
	defer buffer.free();

	io::ByteWriter body;
	body.tinit();
	defer body.destroy()!!;

	Request request = read_request_to(tmem, &buffer, &body)!!;
	defer request.free();

	test::eq("", request.body);
	test::eq("hello world", body.str_view());
	test::eq("tail", (String)buffer.bytes[buffer.read_idx:4]);
}

fn void read_response_to_streams_chunked_body_and_trailers() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: done\r\n\r\n")!!;
	defer buffer.free();

	io::ByteWriter body;
	body.tinit();
	defer body.destroy()!!;

	Response response = read_response_to(tmem, &buffer, &body)!!;
	defer response.free();

	test::eq("", response.body);
	test::eq("hello world", body.str_view());
	test::eq("done", get_header(&response.trailers, "X-Trailer")!!);
}

fn void write_request_from_streams_content_length_body() @test
{
	Request request;
	request.init(tmem, "POST", "/stream");
	defer request.free();
	request.set_header("Host", "example.com");

	io::ByteReader reader;
	init_reader(&reader, "stream-body");

	io::ByteBuffer buffer;
	buffer.tinit(96);
	defer buffer.free();

	write_request_from(&buffer, &request, &reader, 11)!!;

	String encoded = (String)buffer.bytes[:buffer.write_idx];
	test::@check(encoded.contains("Content-Length: 11\r\n"), "expected explicit content-length");
	test::@check(encoded.ends_with("stream-body"), "expected streamed request body");
}

fn void write_response_from_streams_chunked_body_and_trailers() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_header("Transfer-Encoding", "chunked");
	response.trailers.push({ .name = "X-Trailer".copy(tmem), .value = "done".copy(tmem) });

	io::ByteReader reader;
	init_reader(&reader, "streaming body");

	io::ByteBuffer buffer;
	buffer.tinit(128);
	defer buffer.free();

	write_response_from(&buffer, &response, &reader)!!;

	String encoded = (String)buffer.bytes[:buffer.write_idx];
	test::@check(encoded.contains("\r\ne\r\nstreaming body\r\n0\r\nX-Trailer: done\r\n\r\n"), "expected chunked streamed response with trailer");
}

fn void write_request_batches_small_message() @test
{
	Request request;
	request.init(tmem, "POST", "/batched", "hello");
	defer request.free();
	request.set_header("Host", "example.com");
	request.set_header("Content-Type", "text/plain");
	request.set_header("X-Test", "1");

	CountingBuffer buffer;
	init_counting_buffer(&buffer, 128);
	defer free_counting_buffer(&buffer);

	write_request(&buffer, &request)!!;

	String encoded = (String)buffer.buffer.bytes[:buffer.buffer.write_idx];
	test::eq("POST /batched HTTP/1.1\r\nHost: example.com\r\nContent-Type: text/plain\r\nX-Test: 1\r\nContent-Length: 5\r\n\r\nhello", encoded);
	test::eq(1, buffer.write_calls);
}

fn void write_response_batches_small_chunked_message() @test
{
	Response response;
	response.init(tmem, 200, "OK", "data");
	defer response.free();
	response.set_header("Transfer-Encoding", "chunked");
	response.trailers.push({ .name = "Expires".copy(tmem), .value = "soon".copy(tmem) });

	CountingBuffer buffer;
	init_counting_buffer(&buffer, 128);
	defer free_counting_buffer(&buffer);

	write_response(&buffer, &response)!!;

	String encoded = (String)buffer.buffer.bytes[:buffer.buffer.write_idx];
	test::eq("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ndata\r\n0\r\nExpires: soon\r\n\r\n", encoded);
	test::eq(1, buffer.write_calls);
}

fn void write_response_from_batches_small_chunked_stream() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_header("Transfer-Encoding", "chunked");
	response.trailers.push({ .name = "X-Trailer".copy(tmem), .value = "done".copy(tmem) });

	io::ByteReader reader;
	init_reader(&reader, "streaming body");

	CountingBuffer buffer;
	init_counting_buffer(&buffer, 128);
	defer free_counting_buffer(&buffer);

	write_response_from(&buffer, &response, &reader)!!;

	String encoded = (String)buffer.buffer.bytes[:buffer.buffer.write_idx];
	test::eq("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\ne\r\nstreaming body\r\n0\r\nX-Trailer: done\r\n\r\n", encoded);
	test::eq(1, buffer.write_calls);
}

fn void write_request_large_body_uses_header_flush_and_direct_write() @test
{
	DString body = dstring::temp_with_capacity(LARGE_BATCH_TEST_BODY_SIZE);
	body.append_repeat('x', LARGE_BATCH_TEST_BODY_SIZE);

	Request request;
	request.init(tmem, "POST", "/large", body.str_view());
	defer request.free();
	request.set_header("Host", "example.com");

	CountingBuffer buffer;
	init_counting_buffer(&buffer, LARGE_BATCH_TEST_BODY_SIZE + 128);
	defer free_counting_buffer(&buffer);

	write_request(&buffer, &request)!!;

	String encoded = (String)buffer.buffer.bytes[:buffer.buffer.write_idx];
	String expected_header = string::tformat("POST /large HTTP/1.1\r\nHost: example.com\r\nContent-Length: %d\r\n\r\n", LARGE_BATCH_TEST_BODY_SIZE);
	test::@check(encoded.starts_with(expected_header), "expected large request header");
	test::eq(expected_header.len + LARGE_BATCH_TEST_BODY_SIZE, encoded.len);
	test::eq(body.str_view(), encoded[expected_header.len:LARGE_BATCH_TEST_BODY_SIZE]);
	test::eq(2, buffer.write_calls);
}

fn void request_line_limit_is_enforced() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET /0123456789abcdef HTTP/1.1\r\nHost: example.com\r\n\r\n")!!;
	defer buffer.free();

	ResourceLimits limits = tiny_limits();
	test::@error(read_request(tmem, &buffer, limits), REQUEST_LINE_TOO_LARGE);
}

fn void header_line_limit_is_enforced() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nHost: example.com\r\nX-Long: abcdefghijklmnop\r\n\r\n")!!;
	defer buffer.free();

	ResourceLimits limits = tiny_limits();
	test::@error(read_request(tmem, &buffer, limits), HEADER_LINE_TOO_LARGE);
}

fn void header_count_limit_is_enforced() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nHost: a\r\nX-One: 1\r\nX-Two: 2\r\n\r\n")!!;
	defer buffer.free();

	ResourceLimits limits = tiny_limits();
	test::@error(read_request(tmem, &buffer, limits), TOO_MANY_HEADERS);
}

fn void total_header_bytes_limit_is_enforced() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "GET / HTTP/1.1\r\nHost: example.com\r\nX-Test: 1234\r\n\r\n")!!;
	defer buffer.free();

	ResourceLimits limits = tiny_limits();
	limits.max_header_line_size = 64;
	limits.max_header_count = 8;
	test::@error(read_request(tmem, &buffer, limits), HEADERS_TOO_LARGE);
}

fn void buffered_body_limit_is_enforced() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello")!!;
	defer buffer.free();

	ResourceLimits limits = tiny_limits();
	limits.max_header_line_size = 64;
	limits.max_total_header_bytes = 128;
	test::@error(read_request(tmem, &buffer, limits), BUFFERED_BODY_TOO_LARGE);
}

fn void chunk_size_limit_is_enforced() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n")!!;
	defer buffer.free();

	ResourceLimits limits = tiny_limits();
	limits.max_header_line_size = 64;
	limits.max_total_header_bytes = 128;
	test::@error(read_request(tmem, &buffer, limits), CHUNK_TOO_LARGE);
}

fn void chunked_body_total_limit_is_enforced() @test
{
	io::ByteBuffer buffer;
	init_buffer(&buffer, "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n")!!;
	defer buffer.free();

	ResourceLimits limits = tiny_limits();
	limits.max_header_line_size = 64;
	limits.max_total_header_bytes = 128;
	test::@error(read_request(tmem, &buffer, limits), CHUNKED_BODY_TOO_LARGE);
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
