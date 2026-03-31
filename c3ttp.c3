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
	respond_impl{tcp::TcpSocket*}(self.allocator, &socket, handler, 0, context)!;
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
fn Response? read_response_impl(Allocator allocator, Stream stream, String request_method = "") <Stream> @private
{
	String line = io::readline(allocator, stream)!;
	defer line.free(allocator);

	Response response = parse_status_line(allocator, line)!;
	if (catch err = read_headers_and_body(allocator, stream, &response.headers, &response.body, false, !response_has_no_message_body(response.status, request_method)))
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
	validate_request_target(request.method, request.target)!;
	validate_headers(&request.headers, true)!;
	validate_body_headers(&request.headers)!;
	io::fprintf(stream, "%s %s %s\r\n", request.method, request.target, request.version)!;
	write_headers(stream, &request.headers, request.body)!;
	write_body(stream, &request.headers, request.body)!;
}

fn void? write_response_impl(Stream stream, Response* response, String request_method = "") <Stream> @private
{
	validate_version(response.version)!;
	io::fprintf(stream, "%s %d %s\r\n", response.version, response.status, response.reason)!;
	write_headers(stream, &response.headers, response.body, response_should_emit_implicit_content_length(response.status, request_method))!;
	if (!response_has_no_message_body(response.status, request_method))
	{
		write_body(stream, &response.headers, response.body)!;
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

fn void? read_headers_and_body(Allocator allocator, Stream stream, HeaderList* headers, String* body, bool require_host, bool read_body = true) <Stream> @private
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
	validate_body_headers(headers)!;
	if (!read_body)
	{
		set_empty_body(allocator, body);
		return;
	}

	bool use_chunked = uses_chunked_transfer_encoding(headers)!;

	String? content_length_text = get_header(headers, "Content-Length");
	if (use_chunked)
	{
		read_chunked_body{$typeof(stream)}(allocator, stream, body)!;
		return;
	}

	if (catch err = content_length_text)
	{
		set_empty_body(allocator, body);
		return;
	}

	usz content_length = content_length_text.to_uint()!;
	if (!content_length)
	{
		set_empty_body(allocator, body);
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

fn void? read_chunked_body(Allocator allocator, Stream stream, String* body) <Stream> @private
{
	DString chunks = dstring::new_with_capacity(allocator, 32);
	defer chunks.free();

	while (true)
	{
		String line = io::readline(allocator, stream)!;
		defer line.free(allocator);

		usz extension = line.index_of_char(';') ?? line.len;
		usz? chunk_size_value = line[:extension].trim().to_uint(16);
		if (catch err = chunk_size_value) return INVALID_CHUNK~;
		usz chunk_size = chunk_size_value;
		if (!chunk_size)
		{
			while (true)
			{
				String trailer = io::readline(allocator, stream)!;
				defer trailer.free(allocator);
				if (!trailer) break;
				parse_header(allocator, trailer)!;
			}
			(*body).free(allocator);
			*body = chunks.copy_str(allocator);
			chunks.free();
			return;
		}

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
		read_exact{$typeof(stream)}(stream, chunk_crlf[..])!;
		if ((String)chunk_crlf[..] != "\r\n") return INVALID_CHUNK~;

		chunks.append_bytes(chunk);
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

fn void? write_headers(Stream stream, HeaderList* headers, String body, bool include_implicit_content_length = true) <Stream> @private
{
	bool use_chunked = uses_chunked_transfer_encoding(headers)!;
	foreach (header : *headers)
	{
		if (header_name_eq(header.name, "Content-Length")) continue;
		io::fprintf(stream, "%s: %s\r\n", header.name, header.value)!;
	}
	if (include_implicit_content_length && !use_chunked) io::fprintf(stream, "Content-Length: %d\r\n", body.len)!;
	io::fprintf(stream, "\r\n")!;
}

fn void? write_body(Stream stream, HeaderList* headers, String body) <Stream> @private
{
	if (!uses_chunked_transfer_encoding(headers)!)
	{
		stream.write(body)!;
		return;
	}
	write_chunked_body{$typeof(stream)}(stream, body)!;
}

fn void? write_chunked_body(Stream stream, String body) <Stream> @private
{
	if (body)
	{
		io::fprintf(stream, "%x\r\n", body.len)!;
		stream.write(body)!;
		io::fprintf(stream, "\r\n")!;
	}
	io::fprintf(stream, "0\r\n\r\n")!;
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
	if (header_contains_token(te, "chunked")) return true;
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

fn void? read_exact(Stream stream, char[] buffer) <Stream> @private
{
	usz read;
	while (read < buffer.len)
	{
		usz n = stream.read(buffer[read:buffer.len - read])!;
		if (!n) return io::UNEXPECTED_EOF~;
		read += n;
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
