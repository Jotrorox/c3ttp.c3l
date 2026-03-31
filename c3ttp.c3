module c3ttp @private;

import std::collections::list;
import std::core::env;
import std::io;
import std::net;
import std::net::os;
import std::net::tcp;
import std::net::url;
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
	self.headers.free();
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
	self.headers.free();
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
	url::Url parsed = url::parse(tmem, url_string)!;
	if (!parsed.host) return MISSING_HOST~;

	String target = parsed.path ? parsed.path : "/";
	if (parsed.query)
	{
		@pool()
		{
			DString combined = dstring::temp(target);
			combined.append_char('?');
			combined.append_string(parsed.query);
			target = combined.copy_str(allocator);
		};
	}
	else
	{
		target = target.copy(allocator);
	}
	defer target.free(allocator);

	Request request;
	request_init_impl(&request, allocator, method, target, body);
	defer request_free_impl(&request);
	request_set_header_impl(&request, "Host", parsed.port ? string::tformat("%s:%d", parsed.host, parsed.port) : parsed.host);
	request_set_header_impl(&request, "Connection", "close");
	return client_send_impl(self, allocator, parsed.host, parsed.port ? parsed.port : 80, &request);
}

<*
 @require allocator != null : "allocator must be set"
 @require host.len > 0 : "host must not be empty"
 @require backlog > 0 : "backlog must be greater than zero"
*>
fn Server* server_init_impl(Server* self, Allocator allocator, String host, uint port, uint backlog = 64) @private
{
	*self = {
		.allocator = allocator,
		.host = host.copy(allocator),
		.port = port,
		.backlog = backlog
	};
	return self;
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
	respond_once_impl{tcp::TcpSocket*}(self.allocator, &socket, handler, context)!;
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
fn Request? read_request_impl(Allocator allocator, Stream stream) <Stream> @private
{
	String line = io::readline(allocator, stream)!;
	defer line.free(allocator);

	Request request = parse_request_line(allocator, line)!;
	if (catch err = read_headers_and_body(allocator, stream, &request.headers, &request.body, true))
	{
		request_free_impl(&request);
		return err~;
	}
	return request;
}

<*
 @require allocator != null : "allocator must be set"
*>
fn Response? read_response_impl(Allocator allocator, Stream stream) <Stream> @private
{
	String line = io::readline(allocator, stream)!;
	defer line.free(allocator);

	Response response = parse_status_line(allocator, line)!;
	if (catch err = read_headers_and_body(allocator, stream, &response.headers, &response.body, false))
	{
		response_free_impl(&response);
		return err~;
	}
	return response;
}

fn void? write_request_impl(Stream stream, Request* request) <Stream> @private
{
	validate_version(request.version)!;
	validate_method(request.method)!;
	io::fprintf(stream, "%s %s %s\r\n", request.method, request.target, request.version)!;
	write_headers(stream, &request.headers, request.body)!;
	stream.write(request.body)!;
}

fn void? write_response_impl(Stream stream, Response* response) <Stream> @private
{
	validate_version(response.version)!;
	io::fprintf(stream, "%s %d %s\r\n", response.version, response.status, response.reason)!;
	write_headers(stream, &response.headers, response.body)!;
	stream.write(response.body)!;
}

fn Response? exchange_impl(Allocator allocator, Stream stream, Request* request) <Stream> @private
{
	write_request_impl{$typeof(stream)}(stream, request)!;
	return read_response_impl{$typeof(stream)}(allocator, stream);
}

fn void? respond_once_impl(Allocator allocator, Stream stream, Handler handler, void* context) <Stream> @private
{
	Request request = read_request_impl{$typeof(stream)}(allocator, stream)!;
	defer request_free_impl(&request);

	Response response;
	response_init_impl(&response, allocator, 200, "OK");
	defer response_free_impl(&response);
	response_set_header_impl(&response, "Connection", "close");

	handler(&request, &response, context)!;
	write_response_impl{$typeof(stream)}(stream, &response)!;
}

fn Request? parse_request_line(Allocator allocator, String line) @private
{
	@pool()
	{
		String[] parts = line.tsplit(" ", 3, true);
		if (parts.len != 3) return INVALID_REQUEST_LINE~;
		validate_version(parts[2])!;
		validate_method(parts[0])!;

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

fn void? read_headers_and_body(Allocator allocator, Stream stream, HeaderList* headers, String* body, bool require_host) <Stream> @private
{
	while (true)
	{
		String line = io::readline(allocator, stream)!;
		defer line.free(allocator);
		if (!line) break;
		Header header = parse_header(allocator, line)!;
		headers.push(header);
	}

	validate_headers(headers, require_host)!;

	String? transfer_encoding = get_header(headers, "Transfer-Encoding");
	if (try te = transfer_encoding)
	{
		if (te.to_lower_tcopy() != "identity") return UNSUPPORTED_TRANSFER_ENCODING~;
	}

	String? content_length_text = get_header(headers, "Content-Length");
	if (catch err = content_length_text)
	{
		(*body).free(allocator);
		*body = "".copy(allocator);
		return;
	}

	usz content_length = content_length_text.to_uint()!;
	if (!content_length)
	{
		(*body).free(allocator);
		*body = "".copy(allocator);
		return;
	}
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

fn void? write_headers(Stream stream, HeaderList* headers, String body) <Stream> @private
{
	foreach (header : *headers)
	{
		if (header_name_eq(header.name, "Content-Length")) continue;
		io::fprintf(stream, "%s: %s\r\n", header.name, header.value)!;
	}
	io::fprintf(stream, "Content-Length: %d\r\n", body.len)!;
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

fn bool header_name_eq(String left, String right) @private
{
	if (left.len != right.len) return false;
	foreach (i, c : left)
	{
		if (c.to_lower() != right[i].to_lower()) return false;
	}
	return true;
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
