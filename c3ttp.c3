module c3ttp;

import std::collections::list;
import std::io;
import std::net;
import std::net::tcp;
import std::net::url;
import std::time;

const String HTTP_11 = "HTTP/1.1";

faultdef
	INVALID_REQUEST_LINE,
	INVALID_STATUS_LINE,
	INVALID_HEADER,
	INVALID_VERSION,
	INVALID_CONTENT_LENGTH,
	MISSING_HOST,
	MISSING_HANDLER,
	UNSUPPORTED_TRANSFER_ENCODING,
	UNSUPPORTED_METHOD,
	DUPLICATE_HEADER;

struct Header
{
	String name;
	String value;
}

alias HeaderList = List { Header };
alias Handler = fn void?(Request* request, Response* response, void* context);

struct Request
{
	Allocator allocator;
	String method;
	String target;
	String version;
	String body;
	HeaderList headers;
}

struct Response
{
	Allocator allocator;
	ushort status;
	String reason;
	String version;
	String body;
	HeaderList headers;
}

struct Client
{
	Duration timeout;
}

struct Server
{
	Allocator allocator;
	String host;
	uint port;
	uint backlog;
	tcp::TcpServerSocket listener;
	bool is_listening;
}

<*
 @require allocator != null : "allocator must be set"
 @require method.len > 0 : "method must not be empty"
 @require target.len > 0 : "target must not be empty"
 @require version.len > 0 : "version must not be empty"
*>
fn Request* Request.init(&self, Allocator allocator, String method, String target, String body = "", String version = HTTP_11)
{
	self.allocator = allocator;
	self.method = method.copy(allocator);
	self.target = target.copy(allocator);
	self.version = version.copy(allocator);
	self.body = body.copy(allocator);
	self.headers.init(allocator);
	return self;
}

fn void Request.free(&self)
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

fn void Request.set_body(&self, String body)
{
	self.body.free(self.allocator);
	self.body = body.copy(self.allocator);
}

<*
 @require allocator != null : "allocator must be set"
 @require status >= 100 && status <= 599 : "status must be in the HTTP range"
 @require reason.len > 0 : "reason must not be empty"
 @require version.len > 0 : "version must not be empty"
*>
fn Response* Response.init(&self, Allocator allocator, ushort status, String reason, String body = "", String version = HTTP_11)
{
	self.allocator = allocator;
	self.status = status;
	self.reason = reason.copy(allocator);
	self.version = version.copy(allocator);
	self.body = body.copy(allocator);
	self.headers.init(allocator);
	return self;
}

fn void Response.free(&self)
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

fn void Response.set_body(&self, String body)
{
	self.body.free(self.allocator);
	self.body = body.copy(self.allocator);
}

fn Header*? Request.header_ref(&self, String name)
{
	return find_header_ref(&self.headers, name);
}

fn Header*? Response.header_ref(&self, String name)
{
	return find_header_ref(&self.headers, name);
}

fn String? Request.header(&self, String name)
{
	Header* h = self.header_ref(name)!;
	return h.value;
}

fn String? Response.header(&self, String name)
{
	Header* h = self.header_ref(name)!;
	return h.value;
}

<*
 @require name.len > 0 : "header name must not be empty"
*>
fn void Request.set_header(&self, String name, String value)
{
	upsert_header(&self.headers, self.allocator, name, value);
}

<*
 @require name.len > 0 : "header name must not be empty"
*>
fn void Response.set_header(&self, String name, String value)
{
	upsert_header(&self.headers, self.allocator, name, value);
}

<*
 @require name.len > 0 : "header name must not be empty"
*>
fn void Request.add_header(&self, String name, String value)
{
	self.headers.push({ .name = name.copy(self.allocator), .value = value.copy(self.allocator) });
}

<*
 @require name.len > 0 : "header name must not be empty"
*>
fn void Response.add_header(&self, String name, String value)
{
	self.headers.push({ .name = name.copy(self.allocator), .value = value.copy(self.allocator) });
}

fn Client new_client(Duration timeout = time::DURATION_ZERO)
{
	return { .timeout = timeout };
}

<*
 @require allocator != null : "allocator must be set"
 @require host.len > 0 : "host must not be empty"
*>
fn Response? Client.send(&self, Allocator allocator, String host, uint port, Request* request)
{
	tcp::TcpSocket socket = tcp::connect(host, port, self.timeout)!;
	defer catch (void)socket.close();
	return exchange(allocator, &socket, request);
}

<*
 @require allocator != null : "allocator must be set"
 @require method.len > 0 : "method must not be empty"
 @require url_string.len > 0 : "url must not be empty"
*>
fn Response? Client.send_url(&self, Allocator allocator, String method, String url_string, String body = "")
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
	request.init(allocator, method, target, body);
	defer request.free();
	request.set_header("Host", parsed.port ? string::tformat("%s:%d", parsed.host, parsed.port) : parsed.host);
	request.set_header("Connection", "close");
	return self.send(allocator, parsed.host, parsed.port ? parsed.port : 80, &request);
}

<*
 @require allocator != null : "allocator must be set"
 @require host.len > 0 : "host must not be empty"
 @require backlog > 0 : "backlog must be greater than zero"
*>
fn Server* Server.init(&self, Allocator allocator, String host, uint port, uint backlog = 64)
{
	*self = {
		.allocator = allocator,
		.host = host.copy(allocator),
		.port = port,
		.backlog = backlog
	};
	return self;
}

fn void? Server.listen(&self)
{
	if (self.is_listening) return;
	self.listener = tcp::listen(self.host, self.port, self.backlog, REUSEADDR)!;
	self.is_listening = true;
}

fn void? Server.close(&self)
{
	if (!self.is_listening) return;
	defer self.is_listening = false;
	self.listener.close()!;
}

fn void Server.free(&self)
{
	if (self.is_listening) self.close()!!;
	if (self.allocator)
	{
		self.host.free(self.allocator);
	}
	*self = {};
}

<*
 @require handler != null : "handler must be set"
*>
fn void? Server.serve_once(&self, Handler handler, void* context = null)
{
	self.listen()!;
	tcp::TcpSocket socket = tcp::accept(&self.listener)!;
	defer catch (void)socket.close();
	respond_once(self.allocator, &socket, handler, context)!;
}

<*
 @require handler != null : "handler must be set"
*>
fn void? Server.serve(&self, Handler handler, uint max_requests = 0, void* context = null)
{
	self.listen()!;
	uint served;
	while (!max_requests || served < max_requests)
	{
		self.serve_once(handler, context)!;
		served++;
	}
}

macro Request? read_request(Allocator allocator, stream)
{
	return read_request_impl{$typeof(stream)}(allocator, stream);
}

macro Response? read_response(Allocator allocator, stream)
{
	return read_response_impl{$typeof(stream)}(allocator, stream);
}

macro void? write_request(stream, Request* request)
{
	return write_request_impl{$typeof(stream)}(stream, request);
}

macro void? write_response(stream, Response* response)
{
	return write_response_impl{$typeof(stream)}(stream, response);
}

macro Response? exchange(Allocator allocator, stream, Request* request)
{
	return exchange_impl{$typeof(stream)}(allocator, stream, request);
}

macro void? respond_once(Allocator allocator, stream, Handler handler, void* context = null)
{
	return respond_once_impl{$typeof(stream)}(allocator, stream, handler, context);
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
		request.free();
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
		response.free();
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
	write_request(stream, request)!;
	return read_response(allocator, stream);
}

fn void? respond_once_impl(Allocator allocator, Stream stream, Handler handler, void* context) <Stream> @private
{
	Request request = read_request(allocator, stream)!;
	defer request.free();

	Response response;
	response.init(allocator, 200, "OK");
	defer response.free();
	response.set_header("Connection", "close");

	handler(&request, &response, context)!;
	write_response(stream, &response)!;
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
		request.init(allocator, parts[0], parts[1], "", parts[2]);
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
		response.init(allocator, status, parts[2], "", parts[0]);
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
