module c3ttp @private;

import std::core::env;
import std::io;
import std::net;
import std::net::os;
import std::net::tcp;
import std::time;

extern fn CInt getsockname(os::NativeSocket socket, os::SockAddrPtr address, os::Socklen_t* address_len) @if(env::POSIX);

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

fn sz? TimedTcpStream.read(&self, char[] bytes) @dynamic
{
	wait_for_socket_event(self.socket, net::SUBSCRIBE_ANY_READ, self.read_timeout, self.read_timeout_fault)!;
	return (sz)self.socket.read(bytes)!;
}

fn char? TimedTcpStream.read_byte(&self) @dynamic
{
	char[1] buffer = {};
	sz read = self.read(buffer[..])!;
	if (!read) return io::EOF~;
	return buffer[0];
}

fn sz? TimedTcpStream.write(&self, char[] bytes) @dynamic
{
	wait_for_socket_event(self.socket, net::SUBSCRIBE_ANY_WRITE, self.write_timeout, WRITE_TIMEOUT)!;
	return (sz)self.socket.write(bytes)!;
}

fn void? TimedTcpStream.write_byte(&self, char byte) @dynamic
{
	char[1] buffer = { byte };
	sz written = self.write(buffer[..])!;
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

fn void? respond_socket_impl(Allocator allocator, tcp::TcpSocket* socket, Handler handler, uint max_requests, void* context, ServerOptions options) @private
{
	TimedTcpStream stream = {
		.socket = socket,
		.read_timeout = options.timeouts.header_timeout,
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
