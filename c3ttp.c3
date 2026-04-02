module c3ttp @private;

import std::collections::list;
import std::core::env;
import std::io;
import std::net;
import std::net::os;
import std::net::tcp;
import std::time;

const String HTTP_11 @private = "HTTP/1.1";

extern fn CInt getsockname(os::NativeSocket socket, os::SockAddrPtr address, os::Socklen_t* address_len) @if(env::POSIX);

<*
 @require allocator != null : "allocator must be set"
 @require method.len > 0 : "method must not be empty"
 @require target.len > 0 : "target must not be empty"
 @require version.len > 0 : "version must not be empty"
*>
fn Request* request_init_impl(Request* self, Allocator allocator, String method, String target, String body = "", String version = HTTP_11) @private
{
	self.allocator = allocator;
	self.method = method.copy(allocator);
	self.target = target.copy(allocator);
	self.version = version.copy(allocator);
	self.body = body.copy(allocator);
	self.headers.init(allocator);
	self.trailers.init(allocator);
	return self;
}

fn void request_free_impl(Request* self) @private
{
	if (!self.allocator) return;
	foreach (&header : self.headers)
	{
		header.name.free(self.allocator);
		header.value.free(self.allocator);
	}
	foreach (&header : self.trailers)
	{
		header.name.free(self.allocator);
		header.value.free(self.allocator);
	}
	self.headers.free();
	self.trailers.free();
	self.method.free(self.allocator);
	self.target.free(self.allocator);
	self.version.free(self.allocator);
	self.body.free(self.allocator);
	*self = {};
}

fn void request_set_body_impl(Request* self, String body) @private
{
	self.body.free(self.allocator);
	self.body = body.copy(self.allocator);
}

fn String? request_header_impl(Request* self, String name) @private
{
	Header* h = find_header_ref(&self.headers, name)!;
	return h.value;
}

<*
 @require name.len > 0 : "header name must not be empty"
*>
fn void request_set_header_impl(Request* self, String name, String value) @private
{
	upsert_header(&self.headers, self.allocator, name, value);
}

<*
 @require name.len > 0 : "header name must not be empty"
*>
fn void request_add_header_impl(Request* self, String name, String value) @private
{
	self.headers.push({ .name = name.copy(self.allocator), .value = value.copy(self.allocator) });
}

<*
 @require allocator != null : "allocator must be set"
 @require status >= 100 && status <= 599 : "status must be in the HTTP range"
 @require reason.len > 0 : "reason must not be empty"
 @require version.len > 0 : "version must not be empty"
*>
fn Response* response_init_impl(Response* self, Allocator allocator, ushort status, String reason, String body = "", String version = HTTP_11) @private
{
	self.allocator = allocator;
	self.status = status;
	self.reason = reason.copy(allocator);
	self.version = version.copy(allocator);
	self.body = body.copy(allocator);
	self.headers.init(allocator);
	self.trailers.init(allocator);
	return self;
}

fn void response_free_impl(Response* self) @private
{
	if (!self.allocator) return;
	foreach (&header : self.headers)
	{
		header.name.free(self.allocator);
		header.value.free(self.allocator);
	}
	foreach (&header : self.trailers)
	{
		header.name.free(self.allocator);
		header.value.free(self.allocator);
	}
	self.headers.free();
	self.trailers.free();
	self.reason.free(self.allocator);
	self.version.free(self.allocator);
	self.body.free(self.allocator);
	*self = {};
}

fn void response_set_body_impl(Response* self, String body) @private
{
	self.body.free(self.allocator);
	self.body = body.copy(self.allocator);
}

fn String? response_header_impl(Response* self, String name) @private
{
	Header* h = find_header_ref(&self.headers, name)!;
	return h.value;
}

<*
 @require name.len > 0 : "header name must not be empty"
*>
fn void response_set_header_impl(Response* self, String name, String value) @private
{
	upsert_header(&self.headers, self.allocator, name, value);
}

<*
 @require name.len > 0 : "header name must not be empty"
*>
fn void response_add_header_impl(Response* self, String name, String value) @private
{
	self.headers.push({ .name = name.copy(self.allocator), .value = value.copy(self.allocator) });
}

fn Client new_client_impl(Duration timeout = time::DURATION_ZERO) @private
{
	return { .timeout = timeout };
}

fn ResourceLimits default_resource_limits_impl() @private
{
	return {
		.max_request_line_size = 8 * 1024,
		.max_header_line_size = 8 * 1024,
		.max_header_count = 100,
		.max_total_header_bytes = 64 * 1024,
		.max_buffered_body_size = 1024 * 1024,
		.max_chunk_size = 1024 * 1024,
		.max_chunked_body_size = 8 * 1024 * 1024
	};
}

fn ServerTimeouts default_server_timeouts_impl() @private
{
	return {
		.read_timeout = time::sec(30),
		.write_timeout = time::sec(30),
		.idle_timeout = time::sec(15),
		.header_timeout = time::sec(10)
	};
}

fn ServerOptions default_server_options_impl() @private
{
	return {
		.limits = default_resource_limits_impl(),
		.timeouts = default_server_timeouts_impl()
	};
}

struct TimedTcpStream (InStream, OutStream)
{
	tcp::TcpSocket* socket;
	Duration read_timeout;
	Duration body_read_timeout;
	Duration write_timeout;
	fault read_timeout_fault;
}

fn void? wait_for_socket_event(tcp::TcpSocket* socket, net::PollSubscribe events, Duration timeout, fault timeout_fault) @private
{
	if (timeout <= time::DURATION_ZERO) return;
	net::Poll[1] polls = {{ .socket = socket.sock, .events = events }};
	ulong ready = net::poll(polls[0:1], timeout)!;
	if (!ready) return timeout_fault~;
	if (polls[0].revents & (net::POLL_EVENT_ERROR | net::POLL_EVENT_INVALID | net::POLL_EVENT_DISCONNECT))
	{
		return io::UNEXPECTED_EOF~;
	}
}

fn usz? TimedTcpStream.read(&self, char[] bytes) @dynamic
{
	wait_for_socket_event(self.socket, net::SUBSCRIBE_ANY_READ, self.read_timeout, self.read_timeout_fault)!;
	return self.socket.read(bytes);
}

fn char? TimedTcpStream.read_byte(&self) @dynamic
{
	char[1] buffer = {};
	usz read = self.read(buffer[..])!;
	if (!read) return io::EOF~;
	return buffer[0];
}

fn usz? TimedTcpStream.write(&self, char[] bytes) @dynamic
{
	wait_for_socket_event(self.socket, net::SUBSCRIBE_ANY_WRITE, self.write_timeout, WRITE_TIMEOUT)!;
	return self.socket.write(bytes);
}

fn void? TimedTcpStream.write_byte(&self, char byte) @dynamic
{
	char[1] buffer = { byte };
	usz written = self.write(buffer[..])!;
	if (written != 1) return io::INCOMPLETE_WRITE~;
}

<*
 @require allocator != null : "allocator must be set"
 @require host.len > 0 : "host must not be empty"
*>
fn Response? client_send_impl(Client* self, Allocator allocator, String host, uint port, Request* request) @private
{
	tcp::TcpSocket socket = tcp::connect(host, port, self.timeout)!;
	defer catch (void)socket.close();
	return exchange_impl{tcp::TcpSocket*}(allocator, &socket, request);
}

<*
 @require allocator != null : "allocator must be set"
 @require method.len > 0 : "method must not be empty"
 @require url_string.len > 0 : "url must not be empty"
*>
fn Response? client_send_url_impl(Client* self, Allocator allocator, String method, String url_string, String body = "") @private
{
	HttpUrlParts parsed = parse_http_url(url_string)!;
	String target = build_origin_form_target(allocator, parsed.path, parsed.query);
	defer target.free(allocator);

	Request request;
	request_init_impl(&request, allocator, method, target, body);
	defer request_free_impl(&request);
	request_set_header_impl(&request, "Host", parsed.host_header);
	request_set_header_impl(&request, "Connection", "close");
	return client_send_impl(self, allocator, parsed.connect_host, parsed.port, &request);
}

<*
 @require allocator != null : "allocator must be set"
 @require host.len > 0 : "host must not be empty"
 @require backlog > 0 : "backlog must be greater than zero"
*>
fn Server* server_init_impl(Server* self, Allocator allocator, String host, uint port, uint backlog = 64, ServerOptions options = default_server_options_impl()) @private
{
	*self = {
		.allocator = allocator,
		.host = host.copy(allocator),
		.port = port,
		.backlog = backlog,
		.options = options
	};
	return self;
}

fn void server_set_limits_impl(Server* self, ResourceLimits limits) @private
{
	self.options.limits = limits;
}

fn void server_set_timeouts_impl(Server* self, ServerTimeouts timeouts) @private
{
	self.options.timeouts = timeouts;
}

fn uint? server_bound_port(TcpServerSocket* listener) @private
{
	tcp::TcpSocket socket_info;
	socket_info.ai_addrlen = socket_info.ai_addr_storage.len;
	$if env::WIN32:
		int result = os::getsockname(listener.sock, (os::SockAddrPtr)&socket_info.ai_addr_storage, &socket_info.ai_addrlen);
	$else
		int result = getsockname(listener.sock, (os::SockAddrPtr)&socket_info.ai_addr_storage, &socket_info.ai_addrlen);
	$endif
	if (result < 0)
	{
		return os::socket_error()~;
	}

	char[] port_bytes = socket_info.ai_addr_storage[2:2];
	char msb = port_bytes[0];
	char lsb = port_bytes[1];
	return (uint)((msb << 8) | lsb);
}

fn void? server_listen_impl(Server* self) @private
{
	if (self.is_listening) return;
	self.listener = tcp::listen(self.host, self.port, self.backlog, REUSEADDR)!;
	self.port = server_bound_port(&self.listener)!;
	self.is_listening = true;
}

fn void? server_close_impl(Server* self) @private
{
	if (!self.is_listening) return;
	defer self.is_listening = false;
	self.listener.close()!;
}

fn void server_free_impl(Server* self) @private
{
	if (self.is_listening) server_close_impl(self)!!;
	if (self.allocator)
	{
		self.host.free(self.allocator);
	}
	*self = {};
}

<*
 @require handler != null : "handler must be set"
*>
fn void? server_serve_once_impl(Server* self, Handler handler, void* context = null) @private
{
	server_listen_impl(self)!;
	tcp::TcpSocket socket = tcp::accept(&self.listener)!;
	defer catch (void)socket.close();
	respond_socket_impl(self.allocator, &socket, handler, 0, context, self.options)!;
}

<*
 @require handler != null : "handler must be set"
*>
fn void? server_serve_impl(Server* self, Handler handler, uint max_requests = 0, void* context = null) @private
{
	uint served;
	while (!max_requests || served < max_requests)
	{
		server_serve_once_impl(self, handler, context)!;
		served++;
	}
}

<*
 @require allocator != null : "allocator must be set"
*>
fn Request? read_request_impl(Allocator allocator, Stream stream, ResourceLimits limits = default_resource_limits_impl()) <Stream> @private
{
	String line = read_http_line{$typeof(stream)}(allocator, stream, limits.max_request_line_size, REQUEST_LINE_TOO_LARGE)!;
	defer line.free(allocator);

	Request request = parse_request_line(allocator, line)!;
	if (catch err = read_headers_and_body{$typeof(stream)}(allocator, stream, &request.headers, &request.trailers, &request.body, true, limits))
	{
		request_free_impl(&request);
		return err~;
	}
	return request;
}

<*
 @require allocator != null : "allocator must be set"
*>
fn Request? read_request_to_impl(Allocator allocator, InStream in_stream, OutStream body_stream, ResourceLimits limits = default_resource_limits_impl()) @private
{
	String line = read_http_line{$typeof(in_stream)}(allocator, in_stream, limits.max_request_line_size, REQUEST_LINE_TOO_LARGE)!;
	defer line.free(allocator);

	Request request = parse_request_line(allocator, line)!;
	if (catch err = read_headers_and_body_to(allocator, in_stream, body_stream, &request.headers, &request.trailers, true, limits))
	{
		request_free_impl(&request);
		return err~;
	}
	set_empty_body(allocator, &request.body);
	return request;
}

<*
 @require allocator != null : "allocator must be set"
*>
fn Response? read_response_impl(Allocator allocator, Stream stream, String request_method = "", ResourceLimits limits = default_resource_limits_impl()) <Stream> @private
{
	String line = read_http_line{$typeof(stream)}(allocator, stream, limits.max_request_line_size, REQUEST_LINE_TOO_LARGE)!;
	defer line.free(allocator);

	Response response = parse_status_line(allocator, line)!;
	if (catch err = read_headers_and_body{$typeof(stream)}(allocator, stream, &response.headers, &response.trailers, &response.body, false, limits, !response_has_no_message_body(response.status, request_method)))
	{
		response_free_impl(&response);
		return err~;
	}
	return response;
}

<*
 @require allocator != null : "allocator must be set"
*>
fn Response? read_response_to_impl(Allocator allocator, InStream in_stream, OutStream body_stream, String request_method = "", ResourceLimits limits = default_resource_limits_impl()) @private
{
	String line = read_http_line{$typeof(in_stream)}(allocator, in_stream, limits.max_request_line_size, REQUEST_LINE_TOO_LARGE)!;
	defer line.free(allocator);

	Response response = parse_status_line(allocator, line)!;
	if (catch err = read_headers_and_body_to(allocator, in_stream, body_stream, &response.headers, &response.trailers, false, limits, !response_has_no_message_body(response.status, request_method)))
	{
		response_free_impl(&response);
		return err~;
	}
	set_empty_body(allocator, &response.body);
	return response;
}

fn void? write_request_impl(Stream stream, Request* request) <Stream> @private
{
	OutStream out_stream = (OutStream)stream;
	validate_version(request.version)!;
	validate_method(request.method)!;
	validate_request_target(request.method, request.target)!;
	validate_headers(&request.headers, true)!;
	validate_body_headers(&request.headers)!;
	validate_trailers(&request.trailers, uses_chunked_transfer_encoding(&request.headers)!)!;
	io::fprintf(out_stream, "%s %s %s\r\n", request.method, request.target, request.version)!;
	write_headers(out_stream, &request.headers, request.body)!;
	write_body(out_stream, &request.headers, &request.trailers, request.body)!;
}

fn void? write_request_from_impl(OutStream out_stream, Request* request, InStream body_stream, usz content_length = 0) @private
{
	validate_version(request.version)!;
	validate_method(request.method)!;
	validate_request_target(request.method, request.target)!;
	validate_headers(&request.headers, true)!;
	validate_body_headers(&request.headers)!;

	bool use_chunked = uses_chunked_transfer_encoding(&request.headers)!;
	validate_trailers(&request.trailers, use_chunked)!;
	io::fprintf(out_stream, "%s %s %s\r\n", request.method, request.target, request.version)!;
	write_headers(out_stream, &request.headers, "", !use_chunked, content_length)!;
	write_stream_body(out_stream, body_stream, &request.headers, &request.trailers, content_length)!;
}

fn void? write_response_impl(Stream stream, Response* response, String request_method = "") <Stream> @private
{
	OutStream out_stream = (OutStream)stream;
	validate_version(response.version)!;
	bool use_chunked = uses_chunked_transfer_encoding(&response.headers)!;
	validate_trailers(&response.trailers, use_chunked)!;
	io::fprintf(out_stream, "%s %d %s\r\n", response.version, response.status, response.reason)!;
	write_headers(out_stream, &response.headers, response.body, response_should_emit_implicit_content_length(response.status, request_method))!;
	if (!response_has_no_message_body(response.status, request_method))
	{
		write_body(out_stream, &response.headers, &response.trailers, response.body)!;
	}
}

fn void? write_response_from_impl(OutStream out_stream, Response* response, InStream body_stream, usz content_length = 0, String request_method = "") @private
{
	validate_version(response.version)!;
	bool use_chunked = uses_chunked_transfer_encoding(&response.headers)!;
	validate_trailers(&response.trailers, use_chunked)!;
	io::fprintf(out_stream, "%s %d %s\r\n", response.version, response.status, response.reason)!;
	write_headers(out_stream, &response.headers, "", response_should_emit_implicit_content_length(response.status, request_method), content_length)!;
	if (!response_has_no_message_body(response.status, request_method))
	{
		write_stream_body(out_stream, body_stream, &response.headers, &response.trailers, content_length)!;
	}
}

fn Response? exchange_impl(Allocator allocator, Stream stream, Request* request) <Stream> @private
{
	write_request_impl{$typeof(stream)}(stream, request)!;
	return read_response_impl{$typeof(stream)}(allocator, stream, request.method);
}

fn void? respond_once_impl(Allocator allocator, Stream stream, Handler handler, void* context) <Stream> @private
{
	respond_impl{$typeof(stream)}(allocator, stream, handler, 1, context)!;
}

fn void? respond_impl(Allocator allocator, Stream stream, Handler handler, uint max_requests, void* context) <Stream> @private
{
	uint handled;
	while (!max_requests || handled < max_requests)
	{
		Request request = read_request_impl{$typeof(stream)}(allocator, stream)!;
		defer request_free_impl(&request);

		Response response;
		response_init_impl(&response, allocator, 200, "OK");
		defer response_free_impl(&response);

		handler(&request, &response, context)!;
		apply_default_connection_policy(allocator, &request.headers, &response.headers);
		write_response_impl{$typeof(stream)}(stream, &response, request.method)!;
		handled++;
		if (should_close_connection(&request.headers) || should_close_connection(&response.headers)) return;
	}
}

fn void? respond_socket_impl(Allocator allocator, tcp::TcpSocket* socket, Handler handler, uint max_requests, void* context, ServerOptions options) @private
{
	TimedTcpStream stream = {
		.socket = socket,
		.body_read_timeout = options.timeouts.read_timeout,
		.write_timeout = options.timeouts.write_timeout,
		.read_timeout_fault = HEADER_TIMEOUT
	};

	uint handled;
	while (!max_requests || handled < max_requests)
	{
		stream.read_timeout = handled ? options.timeouts.idle_timeout : options.timeouts.header_timeout;
		stream.read_timeout_fault = handled ? IDLE_TIMEOUT : HEADER_TIMEOUT;

		Request request = read_request_impl{TimedTcpStream*}(allocator, &stream, options.limits)!;
		defer request_free_impl(&request);

		Response response;
		response_init_impl(&response, allocator, 200, "OK");
		defer response_free_impl(&response);

		handler(&request, &response, context)!;
		apply_default_connection_policy(allocator, &request.headers, &response.headers);
		write_response_impl{TimedTcpStream*}(&stream, &response, request.method)!;
		handled++;
		if (should_close_connection(&request.headers) || should_close_connection(&response.headers)) return;
	}
}

fn Request? parse_request_line(Allocator allocator, String line) @private
{
	@pool()
	{
		String[] parts = line.tsplit(" ", 3, true);
		if (parts.len != 3) return INVALID_REQUEST_LINE~;
		validate_version(parts[2])!;
		validate_method(parts[0])!;
		validate_request_target(parts[0], parts[1])!;

		Request request;
		request_init_impl(&request, allocator, parts[0], parts[1], "", parts[2]);
		request.body.free(allocator);
		request.body = {};
		return request;
	};
}

fn Response? parse_status_line(Allocator allocator, String line) @private
{
	@pool()
	{
		String[] parts = line.tsplit(" ", 3, true);
		if (parts.len != 3) return INVALID_STATUS_LINE~;
		validate_version(parts[0])!;
		ushort status = (ushort)parts[1].to_uint()!;

		Response response;
		response_init_impl(&response, allocator, status, parts[2], "", parts[0]);
		response.body.free(allocator);
		response.body = {};
		return response;
	};
}

fn void? read_headers_and_body(Allocator allocator, Stream stream, HeaderList* headers, HeaderList* trailers, String* body, bool require_host, ResourceLimits limits = default_resource_limits_impl(), bool read_body = true) <Stream> @private
{
	set_stream_read_timeout{$typeof(stream)}(stream, get_stream_header_timeout{$typeof(stream)}(stream), HEADER_TIMEOUT);
	read_header_block(allocator, stream, headers, limits)!;

	validate_headers(headers, require_host)!;
	validate_body_headers(headers)!;
	if (!read_body)
	{
		set_empty_body(allocator, body);
		clear_headers(trailers);
		return;
	}

	bool use_chunked = uses_chunked_transfer_encoding(headers)!;

	String? content_length_text = get_header(headers, "Content-Length");
	if (use_chunked)
	{
		set_stream_read_timeout{$typeof(stream)}(stream, get_stream_body_timeout{$typeof(stream)}(stream), READ_TIMEOUT);
		read_chunked_body{$typeof(stream)}(allocator, stream, body, trailers, limits)!;
		return;
	}
	clear_headers(trailers);

	if (catch err = content_length_text)
	{
		set_empty_body(allocator, body);
		return;
	}

	usz content_length = content_length_text.to_uint()!;
	if (content_length > limits.max_buffered_body_size) return BUFFERED_BODY_TOO_LARGE~;
	if (!content_length)
	{
		set_empty_body(allocator, body);
		return;
	}
	set_stream_read_timeout{$typeof(stream)}(stream, get_stream_body_timeout{$typeof(stream)}(stream), READ_TIMEOUT);
	char* buffer = allocator::alloc_array(allocator, char, content_length + 1);
	usz read;
	while (read < content_length)
	{
		usz? n_value = stream.read(buffer[read:content_length - read]);
		if (catch err = n_value)
		{
			allocator::free(allocator, buffer);
			return err~;
		}
		usz n = n_value;
		if (!n)
		{
			allocator::free(allocator, buffer);
			return io::UNEXPECTED_EOF~;
		}
		read += n;
	}
	buffer[content_length] = 0;
	*body = (String)buffer[:content_length];
}

fn void? read_headers_and_body_to(Allocator allocator, InStream in_stream, OutStream body_stream, HeaderList* headers, HeaderList* trailers, bool require_host, ResourceLimits limits = default_resource_limits_impl(), bool read_body = true) @private
{
	set_stream_read_timeout{$typeof(in_stream)}(in_stream, get_stream_header_timeout{$typeof(in_stream)}(in_stream), HEADER_TIMEOUT);
	read_header_block(allocator, in_stream, headers, limits)!;

	validate_headers(headers, require_host)!;
	validate_body_headers(headers)!;
	if (!read_body)
	{
		clear_headers(trailers);
		return;
	}

	bool use_chunked = uses_chunked_transfer_encoding(headers)!;
	String? content_length_text = get_header(headers, "Content-Length");
	if (use_chunked)
	{
		set_stream_read_timeout{$typeof(in_stream)}(in_stream, get_stream_body_timeout{$typeof(in_stream)}(in_stream), READ_TIMEOUT);
		read_chunked_body_to(allocator, in_stream, body_stream, trailers, limits)!;
		return;
	}
	clear_headers(trailers);

	if (catch err = content_length_text) return;
	usz content_length = content_length_text.to_uint()!;
	if (!content_length) return;
	set_stream_read_timeout{$typeof(in_stream)}(in_stream, get_stream_body_timeout{$typeof(in_stream)}(in_stream), READ_TIMEOUT);
	copy_exact_to_stream(in_stream, body_stream, content_length)!;
}

fn void? read_chunked_body(Allocator allocator, Stream stream, String* body, HeaderList* trailers, ResourceLimits limits = default_resource_limits_impl()) <Stream> @private
{
	DString chunks = dstring::new_with_capacity(allocator, 32);
	defer chunks.free();
	usz total_size;

	while (true)
	{
		String line = read_http_line{$typeof(stream)}(allocator, stream, limits.max_header_line_size, HEADER_LINE_TOO_LARGE)!;
		defer line.free(allocator);

		usz extension = line.index_of_char(';') ?? line.len;
		String size_text = line[:extension].trim();
		if (!size_text) return INVALID_CHUNK~;
		usz? chunk_size_value = size_text.to_uint(16);
		if (catch err = chunk_size_value) return INVALID_CHUNK~;
		usz chunk_size = chunk_size_value;
		if (chunk_size > limits.max_chunk_size) return CHUNK_TOO_LARGE~;
		if (!chunk_size)
		{
			read_trailers(allocator, stream, trailers, limits)!;
			(*body).free(allocator);
			*body = chunks.copy_str(allocator);
			chunks.free();
			return;
		}
		if (total_size + chunk_size > limits.max_chunked_body_size) return CHUNKED_BODY_TOO_LARGE~;
		if (total_size + chunk_size > limits.max_buffered_body_size) return BUFFERED_BODY_TOO_LARGE~;

		char[] chunk = allocator::alloc_array(allocator, char, chunk_size);
		defer allocator::free(allocator, chunk);

		usz read;
		while (read < chunk_size)
		{
			usz n = stream.read(chunk[read:chunk_size - read])!;
			if (!n) return io::UNEXPECTED_EOF~;
			read += n;
		}

		char[2] chunk_crlf = {};
		read_exact(stream, chunk_crlf[..])!;
		if ((String)chunk_crlf[..] != "\r\n") return INVALID_CHUNK~;

		chunks.append_bytes(chunk);
		total_size += chunk_size;
	}
}

fn void? read_chunked_body_to(Allocator allocator, InStream in_stream, OutStream body_stream, HeaderList* trailers, ResourceLimits limits = default_resource_limits_impl()) @private
{
	char[4096] buffer = {};
	usz total_size;

	while (true)
	{
		String line = read_http_line{$typeof(in_stream)}(allocator, in_stream, limits.max_header_line_size, HEADER_LINE_TOO_LARGE)!;
		defer line.free(allocator);

		usz extension = line.index_of_char(';') ?? line.len;
		String size_text = line[:extension].trim();
		if (!size_text) return INVALID_CHUNK~;
		usz? chunk_size_value = size_text.to_uint(16);
		if (catch err = chunk_size_value) return INVALID_CHUNK~;
		usz chunk_size = chunk_size_value;
		if (chunk_size > limits.max_chunk_size) return CHUNK_TOO_LARGE~;
		if (!chunk_size)
		{
			read_trailers(allocator, in_stream, trailers, limits)!;
			return;
		}
		if (total_size + chunk_size > limits.max_chunked_body_size) return CHUNKED_BODY_TOO_LARGE~;

		copy_exact_chunk_to_stream(in_stream, body_stream, buffer[..], chunk_size)!;
		char[2] chunk_crlf = {};
		read_exact(in_stream, chunk_crlf[..])!;
		if ((String)chunk_crlf[..] != "\r\n") return INVALID_CHUNK~;
		total_size += chunk_size;
	}
}

fn Header? parse_header(Allocator allocator, String line) @private
{
	usz? split_value = line.index_of_char(':');
	if (catch err = split_value) return INVALID_HEADER~;
	usz split = split_value;
	String name = line[:split].trim();
	String value = line[split + 1 ..].trim();
	if (!name) return INVALID_HEADER~;
	return {
		.name = name.copy(allocator),
		.value = value.copy(allocator)
	};
}

fn void? read_header_block(Allocator allocator, InStream stream, HeaderList* headers, ResourceLimits limits = default_resource_limits_impl()) @private
{
	clear_headers(headers);
	usz total_bytes;
	while (true)
	{
		String line = read_http_line{$typeof(stream)}(allocator, stream, limits.max_header_line_size, HEADER_LINE_TOO_LARGE)!;
		defer line.free(allocator);
		if (!line) break;
		if (headers.len() >= limits.max_header_count) return TOO_MANY_HEADERS~;
		if (total_bytes + line.len > limits.max_total_header_bytes) return HEADERS_TOO_LARGE~;
		headers.push(parse_header(allocator, line)!);
		total_bytes += line.len;
	}
}

fn void clear_headers(HeaderList* headers) @private
{
	foreach (&header : *headers)
	{
		header.name.free(headers.allocator);
		header.value.free(headers.allocator);
	}
	headers.clear();
}

fn void? write_headers(OutStream stream, HeaderList* headers, String body, bool include_implicit_content_length = true, usz explicit_content_length = 0) @private
{
	bool use_chunked = uses_chunked_transfer_encoding(headers)!;
	foreach (header : *headers)
	{
		if (header_name_eq(header.name, "Content-Length")) continue;
		io::fprintf(stream, "%s: %s\r\n", header.name, header.value)!;
	}
	if (include_implicit_content_length && !use_chunked)
	{
		usz body_length = explicit_content_length;
		if (!explicit_content_length && body) body_length = body.len;
		io::fprintf(stream, "Content-Length: %d\r\n", body_length)!;
	}
	io::fprintf(stream, "\r\n")!;
}

fn void? write_body(OutStream stream, HeaderList* headers, HeaderList* trailers, String body) @private
{
	if (!uses_chunked_transfer_encoding(headers)!)
	{
		stream.write(body)!;
		return;
	}
	write_chunked_body(stream, body, trailers)!;
}

fn void? write_stream_body(OutStream out_stream, InStream body_stream, HeaderList* headers, HeaderList* trailers, usz content_length) @private
{
	if (!uses_chunked_transfer_encoding(headers)!)
	{
		copy_exact_to_stream(body_stream, out_stream, content_length)!;
		return;
	}
	write_chunked_stream(out_stream, body_stream, trailers)!;
}

fn void? write_chunked_body(OutStream stream, String body, HeaderList* trailers) @private
{
	if (body)
	{
		io::fprintf(stream, "%x\r\n", body.len)!;
		stream.write(body)!;
		io::fprintf(stream, "\r\n")!;
	}
	io::fprintf(stream, "0\r\n")!;
	write_trailers(stream, trailers)!;
}

fn void? write_chunked_stream(OutStream out_stream, InStream body_stream, HeaderList* trailers) @private
{
	char[4096] buffer = {};
	while (true)
	{
		usz? read_value = body_stream.read(buffer[..]);
		if (catch err = read_value)
		{
			if (err == io::EOF) break;
			return err~;
		}
		usz read = read_value;
		if (!read) break;
		io::fprintf(out_stream, "%x\r\n", read)!;
		out_stream.write(buffer[:read])!;
		io::fprintf(out_stream, "\r\n")!;
	}
	io::fprintf(out_stream, "0\r\n")!;
	write_trailers(out_stream, trailers)!;
}

fn void? write_trailers(OutStream stream, HeaderList* trailers) @private
{
	foreach (trailer : *trailers)
	{
		io::fprintf(stream, "%s: %s\r\n", trailer.name, trailer.value)!;
	}
	io::fprintf(stream, "\r\n")!;
}

fn void upsert_header(HeaderList* headers, Allocator allocator, String name, String value) @private
{
	if (try header = find_header_ref(headers, name))
	{
		header.value.free(allocator);
		header.value = value.copy(allocator);
		return;
	}
	headers.push({ .name = name.copy(allocator), .value = value.copy(allocator) });
}

fn Header*? find_header_ref(HeaderList* headers, String name) @private
{
	foreach (&header : *headers)
	{
		if (header_name_eq(header.name, name)) return header;
	}
	return INVALID_HEADER~;
}

fn String? get_header(HeaderList* headers, String name) @private
{
	Header* header = find_header_ref(headers, name)!;
	return header.value;
}

fn void set_empty_body(Allocator allocator, String* body) @private
{
	(*body).free(allocator);
	*body = "".copy(allocator);
}

fn void? read_trailers(Allocator allocator, InStream stream, HeaderList* trailers, ResourceLimits limits = default_resource_limits_impl()) @private
{
	read_header_block(allocator, stream, trailers, limits)!;
	validate_trailers(trailers, true)!;
}

fn String? read_http_line(Allocator allocator, Stream stream, usz limit, fault too_long_fault) <Stream> @private
{
	@pool()
	{
		DString line = dstring::temp_with_capacity(min(limit ? limit : 256, 256));
		while (true)
		{
			char? c_value = stream.read_byte();
			if (catch err = c_value)
			{
				if (err == io::EOF)
				{
					if (!line.len()) return io::EOF~;
					return io::UNEXPECTED_EOF~;
				}
				return err~;
			}

			char c = c_value;
			if (c == '\n') return line.copy_str(allocator);
			if (c == '\r') continue;
			if (limit && line.len() >= limit) return too_long_fault~;
			line.append_char(c);
		}
	};
}

fn Duration get_stream_header_timeout(Stream stream) <Stream> @private
{
	$if Stream == TimedTcpStream*:
		return stream.read_timeout;
	$else
		return time::DURATION_ZERO;
	$endif
}

fn Duration get_stream_body_timeout(Stream stream) <Stream> @private
{
	$if Stream == TimedTcpStream*:
		return stream.body_read_timeout;
	$else
		return time::DURATION_ZERO;
	$endif
}

fn void set_stream_read_timeout(Stream stream, Duration timeout, fault timeout_fault) <Stream> @private
{
	$if Stream == TimedTcpStream*:
		stream.read_timeout = timeout;
		stream.read_timeout_fault = timeout_fault;
	$endif
}

fn void? validate_trailers(HeaderList* trailers, bool allow_trailers) @private
{
	if (!allow_trailers && trailers.len() > 0) return INVALID_TRAILER~;
	foreach (header : *trailers)
	{
		if (header_name_eq(header.name, "Transfer-Encoding")) return INVALID_TRAILER~;
		if (header_name_eq(header.name, "Content-Length")) return INVALID_TRAILER~;
		if (header_name_eq(header.name, "Host")) return INVALID_TRAILER~;
		if (header_name_eq(header.name, "Connection")) return INVALID_TRAILER~;
		if (header_name_eq(header.name, "Trailer")) return INVALID_TRAILER~;
	}
}

fn void? validate_body_headers(HeaderList* headers) @private
{
	bool use_chunked = uses_chunked_transfer_encoding(headers)!;
	String? content_length_text = get_header(headers, "Content-Length");
	if (use_chunked)
	{
		if (try content_length_text) return CONFLICTING_BODY_HEADERS~;
	}
}

fn void? validate_headers(HeaderList* headers, bool require_host) @private
{
	bool seen_host = false;
	bool seen_content_length = false;
	bool seen_transfer_encoding = false;
	bool seen_connection = false;

	foreach (header : *headers)
	{
		if (header_name_eq(header.name, "Host"))
		{
			if (seen_host) return DUPLICATE_HEADER~;
			validate_host_header_value(header.value)!;
			seen_host = true;
			continue;
		}
		if (header_name_eq(header.name, "Content-Length"))
		{
			if (seen_content_length) return DUPLICATE_HEADER~;
			seen_content_length = true;
			continue;
		}
		if (header_name_eq(header.name, "Transfer-Encoding"))
		{
			if (seen_transfer_encoding) return DUPLICATE_HEADER~;
			seen_transfer_encoding = true;
			continue;
		}
		if (header_name_eq(header.name, "Connection"))
		{
			if (seen_connection) return DUPLICATE_HEADER~;
			seen_connection = true;
		}
	}

	if (require_host && !seen_host) return MISSING_HOST~;
}

struct HttpUrlParts
{
	String connect_host;
	String host_header;
	String path;
	String query;
	uint port;
}

fn HttpUrlParts? parse_http_url(String url_string) @private
{
	usz? scheme_end_value = url_string.index_of("://");
	if (catch err = scheme_end_value)
	{
		if (try url_string.index_of_char(':')) return UNSUPPORTED_SCHEME~;
		return INVALID_TARGET~;
	}
	usz scheme_end = scheme_end_value;
	String scheme = url_string[:scheme_end];
	if (!scheme) return INVALID_TARGET~;
	if (scheme != "http") return UNSUPPORTED_SCHEME~;

	String rest = url_string[scheme_end + 3 ..];
	usz authority_end = rest.index_of_chars("/?#") ?? rest.len;
	String authority = rest[:authority_end];
	if (!authority) return MISSING_HOST~;

	HttpUrlParts parts = { .port = 80 };
	parse_authority(authority, false, &parts.host_header, &parts.connect_host, &parts.port)!;

	String path_and_query = rest[authority_end ..];
	parts.path = path_and_query;
	if (try query_index = path_and_query.index_of_char('?'))
	{
		parts.path = path_and_query[:query_index];
		parts.query = path_and_query[query_index + 1 ..];
	}
	if (path_and_query.contains("#")) return INVALID_TARGET~;
	if (!parts.path) parts.path = "/";
	return parts;
}

fn void? validate_request_target(String method, String target) @private
{
	if (target == "*")
	{
		if (method != "OPTIONS") return INVALID_TARGET~;
		return;
	}

	if (method == "CONNECT")
	{
		String host_header;
		String connect_host;
		uint port;
		parse_authority(target, true, &host_header, &connect_host, &port)!;
		return;
	}

	if (target.contains("://"))
	{
		parse_http_url(target)!;
		return;
	}

	validate_origin_form_target(target)!;
}

fn void? validate_origin_form_target(String target) @private
{
	if (!target.starts_with("/")) return INVALID_TARGET~;
	if (target.contains("#")) return INVALID_TARGET~;
	foreach (c : target)
	{
		if (c <= 0x20 || c == 0x7f) return INVALID_TARGET~;
	}
}

fn String build_origin_form_target(Allocator allocator, String path, String query) @private
{
	String normalized_path = path ? path : "/";
	if (!query) return normalized_path.copy(allocator);
	@pool()
	{
		DString combined = dstring::temp(normalized_path);
		combined.append_char('?');
		combined.append_string(query);
		return combined.copy_str(allocator);
	};
}

fn void? validate_host_header_value(String value) @private
{
	String host_header;
	String connect_host;
	uint port;
	parse_authority(value, false, &host_header, &connect_host, &port)!;
}

fn void? parse_authority(String authority, bool require_port, String* host_header, String* connect_host, uint* port_out) @private
{
	if (!authority) return INVALID_HOST~;
	if (try authority.index_of_chars("/?#@")) return INVALID_HOST~;

	String host;
	String port_text = "";
	if (authority[0] == '[')
	{
		usz? closing_value = authority.index_of_char(']');
		if (catch err = closing_value) return INVALID_HOST~;
		usz closing = closing_value;
		if (closing + 1 == authority.len)
		{
			host = authority;
			*connect_host = authority[1 .. closing - 1];
		}
		else
		{
			if (authority[closing + 1] != ':') return INVALID_HOST~;
			host = authority[:closing + 1];
			port_text = authority[closing + 2 ..];
			*connect_host = authority[1 .. closing - 1];
		}
		if (host.len <= 2) return INVALID_HOST~;
	}
	else
	{
		usz? first_colon = authority.index_of_char(':');
		if (catch err = first_colon)
		{
			host = authority;
			*connect_host = authority;
		}
		else
		{
			usz colon = first_colon;
			if (authority[colon + 1 ..].contains(":")) return INVALID_HOST~;
			host = authority[:colon];
			port_text = authority[colon + 1 ..];
			*connect_host = host;
		}
	}

	if (!host) return INVALID_HOST~;
	if (!is_valid_reg_name(host) && !(host.starts_with("[") && host.ends_with("]"))) return INVALID_HOST~;

	if (!port_text)
	{
		if (require_port) return INVALID_HOST~;
		*host_header = authority;
		return;
	}

	usz? parsed_port_value = port_text.to_uint();
	if (catch err = parsed_port_value) return INVALID_HOST~;
	usz parsed_port = parsed_port_value;
	if (!parsed_port || parsed_port > 65535) return INVALID_HOST~;
	*host_header = authority;
	*port_out = (uint)parsed_port;
}

fn bool is_valid_reg_name(String host) @private
{
	foreach (c : host)
	{
		if (char_is_alpha_num(c)) continue;
		if (c == '.' || c == '-' || c == '_') continue;
		return false;
	}
	return true;
}

fn bool char_is_alpha_num(char c) @private
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

fn bool should_close_connection(HeaderList* headers) @private
{
	String? connection = get_header(headers, "Connection");
	if (catch err = connection) return false;
	return header_contains_token(connection, "close");
}

fn void apply_default_connection_policy(Allocator allocator, HeaderList* request_headers, HeaderList* response_headers) @private
{
	if (should_close_connection(request_headers))
	{
		upsert_header(response_headers, allocator, "Connection", "close");
		return;
	}
}

fn bool? uses_chunked_transfer_encoding(HeaderList* headers) @private
{
	String? transfer_encoding = get_header(headers, "Transfer-Encoding");
	if (catch err = transfer_encoding) return false;
	String te = transfer_encoding;
	if (te.to_lower_tcopy() == "identity") return false;
	if (te.trim().to_lower_tcopy() == "chunked") return true;
	return UNSUPPORTED_TRANSFER_ENCODING~;
}

fn bool header_contains_token(String header_value, String token) @private
{
	Splitter splitter = header_value.tokenize(",");
	while (try part = splitter.next())
	{
		if (part.trim().to_lower_tcopy() == token) return true;
	}
	return false;
}

fn void? read_exact(InStream stream, char[] buffer) @private
{
	usz read;
	while (read < buffer.len)
	{
		usz n = stream.read(buffer[read:buffer.len - read])!;
		if (!n) return io::UNEXPECTED_EOF~;
		read += n;
	}
}

fn void? copy_exact_to_stream(InStream in_stream, OutStream out_stream, usz length) @private
{
	char[4096] buffer = {};
	copy_exact_chunk_to_stream(in_stream, out_stream, buffer[..], length)!;
}

fn void? copy_exact_chunk_to_stream(InStream in_stream, OutStream out_stream, char[] buffer, usz length) @private
{
	usz remaining = length;
	while (remaining)
	{
		usz chunk = min(buffer.len, remaining);
		usz read = in_stream.read(buffer[:chunk])!;
		if (!read) return io::UNEXPECTED_EOF~;
		out_stream.write(buffer[:read])!;
		remaining -= read;
	}
}

fn bool header_name_eq(String left, String right) @private
{
	if (left.len != right.len) return false;
	foreach (i, c : left)
	{
		if (c.to_lower() != right[i].to_lower()) return false;
	}
	return true;
}

fn bool response_status_disallows_body(ushort status) @private
{
	if (status >= 100 && status < 200) return true;
	if (status == 204) return true;
	if (status == 304) return true;
	return false;
}

fn bool response_has_no_message_body(ushort status, String request_method = "") @private
{
	if (request_method == "HEAD") return true;
	return response_status_disallows_body(status);
}

fn bool response_should_emit_implicit_content_length(ushort status, String request_method = "") @private
{
	if (request_method == "HEAD") return true;
	return !response_status_disallows_body(status);
}

fn void? validate_version(String version) @private
{
	if (version != HTTP_11) return INVALID_VERSION~;
}

fn void? validate_method(String method) @private
{
	if (method == "GET") return;
	if (method == "HEAD") return;
	if (method == "POST") return;
	if (method == "PUT") return;
	if (method == "DELETE") return;
	if (method == "OPTIONS") return;
	if (method == "PATCH") return;
	if (method == "TRACE") return;
	if (method == "CONNECT") return;
	return UNSUPPORTED_METHOD~;
}
