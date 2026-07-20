module c3ttp @private;

import std::core::env;
import std::core::mem;
import std::core::mem::alloc;
import std::collections::list;
import std::io;
import std::thread;
import std::thread::cpu;
import std::net;
import std::net::os;
import std::net::tcp;
import std::os::linux;
import std::os::posix;
import std::time;
import std::time::clock;
import libc;

extern fn CInt getsockname(os::NativeSocket socket, os::SockAddrPtr address, os::Socklen_t* address_len) @if(env::POSIX);
extern fn CInt fork() @if(env::POSIX);

const CInt TCP_NODELAY = 1;
const CInt IPPROTO_TCP = 6;
const int EPOLL_MAX_EVENTS = 256;
const usz TIMED_TCP_STREAM_BUFFER_SIZE = 8192;
const CInt MSG_NOSIGNAL @private @if(env::LINUX) = 0x4000;
const uint PREFORK_MAX_WORKERS @private @if(env::LINUX) = 1024;

bool prefork_shutdown_requested @private @if(env::LINUX);

fn void prefork_signal_handler(CInt signal) @private @if(env::LINUX)
{
	prefork_shutdown_requested = true;
}

fn void? set_tcp_no_delay(tcp::TcpSocket* socket, bool enabled) @private
{
	if (!enabled || socket.addrlen < 2) return;
	CInt flag = 1;
	if (os::setsockopt(socket.sock, IPPROTO_TCP, TCP_NODELAY, &flag, CInt::size) != 0)
	{
		return os::socket_error()~;
	}
}

fn tcp::TcpServerSocket? server_make_listener(Server* self, bool reuse_port) @private
{
	if (reuse_port)
	{
		return tcp::listen(self.host, (int)self.port, (int)self.backlog, REUSEADDR, REUSEPORT)!;
	}
	return tcp::listen(self.host, (int)self.port, (int)self.backlog, REUSEADDR)!;
}

struct TimedTcpStream (InStream, OutStream)
{
	tcp::TcpSocket* socket;
	Duration read_timeout;
	Duration body_read_timeout;
	Duration write_timeout;
	fault read_timeout_fault;
	char[TIMED_TCP_STREAM_BUFFER_SIZE] read_buffer_storage;
	usz read_buffer_start;
	usz read_buffer_end;
}

fn void? wait_for_socket_event(tcp::TcpSocket* socket, net::PollSubscribe events, Duration timeout, fault timeout_fault) @private
{
	if (timeout <= time::DURATION_ZERO) return;
	net::Poll[1] polls = {{ .socket = socket.sock, .events = events }};
	ulong ready = net::poll(polls[0:1], timeout)!;
	if (!ready) return timeout_fault~;
	if (polls[0].revents & (ERROR | INVALID | DISCONNECT))
	{
		return io::UNEXPECTED_EOF~;
	}
}

fn usz timed_tcp_stream_buffered_bytes(TimedTcpStream* stream) @private
{
	return stream.read_buffer_end - stream.read_buffer_start;
}

fn void timed_tcp_stream_reset_buffer(TimedTcpStream* stream) @private
{
	stream.read_buffer_start = 0;
	stream.read_buffer_end = 0;
}

fn sz? timed_tcp_stream_fill_buffer(TimedTcpStream* stream) @private
{
	if (timed_tcp_stream_buffered_bytes(stream)) return (sz)timed_tcp_stream_buffered_bytes(stream);
	timed_tcp_stream_reset_buffer(stream);
	wait_for_socket_event(stream.socket, ANY_READ, stream.read_timeout, stream.read_timeout_fault)!;
	sz read = (sz)stream.socket.read(stream.read_buffer_storage[..])!;
	if (read > 0)
	{
		stream.read_buffer_end = (usz)read;
	}
	return read;
}

fn sz? TimedTcpStream.read(&self, char[] bytes) @dynamic
{
	if (!bytes.len) return 0;

	usz copied;
	usz buffered = timed_tcp_stream_buffered_bytes(self);
	if (buffered)
	{
		usz to_copy = min((usz)bytes.len, buffered);
		for (usz i = 0; i < to_copy; i++)
		{
			bytes[i] = self.read_buffer_storage[self.read_buffer_start + i];
		}
		self.read_buffer_start += to_copy;
		if (self.read_buffer_start == self.read_buffer_end)
		{
			timed_tcp_stream_reset_buffer(self);
		}
		copied = to_copy;
	}
	if (copied) return (sz)copied;
	if (bytes.len >= TIMED_TCP_STREAM_BUFFER_SIZE)
	{
		wait_for_socket_event(self.socket, ANY_READ, self.read_timeout, self.read_timeout_fault)!;
		return (sz)self.socket.read(bytes)!;
	}

	sz read = timed_tcp_stream_fill_buffer(self)!;
	if (read <= 0) return read;

	usz to_copy = min((usz)bytes.len, timed_tcp_stream_buffered_bytes(self));
	for (usz i = 0; i < to_copy; i++)
	{
		bytes[i] = self.read_buffer_storage[self.read_buffer_start + i];
	}
	self.read_buffer_start += to_copy;
	if (self.read_buffer_start == self.read_buffer_end)
	{
		timed_tcp_stream_reset_buffer(self);
	}
	return (sz)to_copy;
}

fn char? TimedTcpStream.read_byte(&self) @dynamic
{
	if (!timed_tcp_stream_buffered_bytes(self))
	{
		sz read = timed_tcp_stream_fill_buffer(self)!;
		if (!read) return io::EOF~;
	}
	char byte = self.read_buffer_storage[self.read_buffer_start];
	self.read_buffer_start++;
	if (self.read_buffer_start == self.read_buffer_end)
	{
		timed_tcp_stream_reset_buffer(self);
	}
	return byte;
}

fn sz? TimedTcpStream.write(&self, char[] bytes) @dynamic
{
	wait_for_socket_event(self.socket, ANY_WRITE, self.write_timeout, WRITE_TIMEOUT)!;
	$if env::LINUX:
		sz n = libc::send(self.socket.sock, bytes.ptr, bytes.len, MSG_NOSIGNAL);
		if (n < 0) return os::socket_error()~;
		return n;
	$else
		return (sz)self.socket.write(bytes)!;
	$endif
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
	tcp::TcpSocket socket = tcp::connect(host, (int)port, self.timeout)!;
	defer catch (void)socket.close();
	set_tcp_no_delay(&socket, self.tcp_no_delay)!!;
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
	request_set_header_impl(&request, "Host", parsed.host_header)!;
	request_set_header_impl(&request, "Connection", "close")!;
	return client_send_impl(self, allocator, parsed.connect_host, parsed.port, &request);
}

fn Connection? client_connect_impl(Client* self, String host, uint port) @private
{
	tcp::TcpSocket socket = tcp::connect(host, (int)port, self.timeout)!;
	set_tcp_no_delay(&socket, self.tcp_no_delay)!!;
	return { .socket = socket, .alive = true };
}

fn Response? connection_send_impl(Connection* self, Allocator allocator, Request* request) @private
{
	if (!self.alive) return CONNECTION_CLOSED~;

	write_request_impl{tcp::TcpSocket*}(&self.socket, request)!;
	Response response;
	for (uint informational = 0; ; informational++)
	{
		response = read_response_impl{tcp::TcpSocket*}(allocator, &self.socket, request.method)!;
		if (response.status < 100 || response.status >= 200 || response.status == 101) break;
		response_free_impl(&response);
		if (informational >= 15) return TOO_MANY_INFORMATIONAL_RESPONSES~;
	}

	bool protocol_switch = response.status == 101 || (request.method == "CONNECT" && response.status >= 200 && response.status < 300);
	HeaderInfo response_framing;
	analyze_headers(&response.headers, false, &response_framing)!;
	bool close_delimited = !response_has_no_message_body(response.status, request.method) && !response_framing.chunked && !response_framing.has_content_length;
	if (protocol_switch || close_delimited || should_close_connection(&request.headers) || should_close_connection(&response.headers))
	{
		(void)self.socket.close();
		self.alive = false;
	}

	return response;
}

fn void connection_close_impl(Connection* self) @private
{
	if (self.alive)
	{
		(void)self.socket.close();
		self.alive = false;
	}
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
	socket_info.addrlen = socket_info.addr_storage.len;
	$if env::WIN32:
		int result = os::getsockname(listener.sock, (os::SockAddrPtr)&socket_info.addr_storage, &socket_info.addrlen);
	$else
		int result = getsockname(listener.sock, (os::SockAddrPtr)&socket_info.addr_storage, &socket_info.addrlen);
	$endif
	if (result < 0)
	{
		return os::socket_error()~;
	}

	char[] port_bytes = socket_info.addr_storage[2:2];
	char msb = port_bytes[0];
	char lsb = port_bytes[1];
	return (uint)((msb << 8) | lsb);
}

fn void? server_listen_impl(Server* self) @private
{
	if (self.is_listening) return;
	self.listener = server_make_listener(self, false)!;
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
	set_tcp_no_delay(&socket, true)!!;
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
	respond_socket_keepalive_impl(allocator, socket, handler, max_requests, context, options, null)!;
}

fn void? respond_socket_keepalive_impl(Allocator allocator, tcp::TcpSocket* socket, Handler handler, uint max_requests, void* context, ServerOptions options, bool* keep_open) @private
{
	TimedTcpStream stream = {
		.socket = socket,
		.read_timeout = options.timeouts.header_timeout,
		.body_read_timeout = options.timeouts.read_timeout,
		.write_timeout = options.timeouts.write_timeout,
		.read_timeout_fault = HEADER_TIMEOUT
	};

	if (keep_open) *keep_open = true;

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
		bool close_connection = should_close_connection(&request.headers) || should_close_connection(&response.headers);
		if (keep_open) *keep_open = !close_connection;
		if (close_connection) return;
	}
}

const usz EVENTED_ACCEPT_BUDGET = 64;
// Evented buffers are allocated on first use. Keep their initial footprint small;
// DString grows automatically for larger requests and responses.
const sz EVENTED_INPUT_INITIAL_CAPACITY = 1024;
const sz EVENTED_OUTPUT_INITIAL_CAPACITY = 256;
const usz EVENTED_READ_BUDGET = 64 * 1024;
const usz EVENTED_WRITE_BUDGET = 64 * 1024;
const uint EVENTED_PIPELINE_BUDGET = 16;

enum EventedPhase @if(env::LINUX)
{
	READING,
	WRITING,
	IDLE,
}

struct EventedInputStream (InStream) @if(env::LINUX)
{
	String bytes;
	usz offset;
}

fn sz? EventedInputStream.read(&self, char[] destination) @dynamic @if(env::LINUX)
{
	usz remaining = self.bytes.len - self.offset;
	if (!remaining) return io::EOF~;
	usz count = min(remaining, (usz)destination.len);
	destination[:count] = self.bytes[self.offset:count];
	self.offset += count;
	return (sz)count;
}

fn char? EventedInputStream.read_byte(&self) @dynamic @if(env::LINUX)
{
	if (self.offset == self.bytes.len) return io::EOF~;
	return self.bytes[self.offset++];
}

struct EventedOutputStream (InStream, OutStream) @if(env::LINUX)
{
	DString* bytes;
}

// The HTTP codec's generic stream specialization is shared by its read and
// write paths, so provide the unused input side as a closed stream.
fn sz? EventedOutputStream.read(&self, char[] destination) @dynamic @if(env::LINUX)
{
	return io::EOF~;
}

fn char? EventedOutputStream.read_byte(&self) @dynamic @if(env::LINUX)
{
	return io::EOF~;
}

fn sz? EventedOutputStream.write(&self, char[] bytes) @dynamic @if(env::LINUX)
{
	self.bytes.append(bytes);
	return (sz)bytes.len;
}

fn void? EventedOutputStream.write_byte(&self, char byte) @dynamic @if(env::LINUX)
{
	self.bytes.append(byte);
}

struct EventedConnection @if(env::LINUX)
{
	tcp::TcpSocket socket;
	DString input;
	DString output;
	usz write_offset;
	EventedPhase phase;
	time::Clock deadline;
	bool peer_eof;
	bool close_after_write;
	bool reserved_request;
}

fn void close_epoll_socket(int epfd, int fd) @private @if(env::LINUX)
{
	linux::epoll_ctl(epfd, (int)linux::EPOLL_CTL_DEL, fd, null);
	(void)libc::close(fd);
}

fn void? set_epoll_socket_events(int epfd, int operation, int fd, uint events) @private @if(env::LINUX)
{
	linux::EpollEvent event = { .events = events };
	event.data.fd = fd;
	if (linux::epoll_ctl(epfd, operation, fd, &event) != 0) return io::GENERAL_ERROR~;
}

fn void? register_epoll_socket(int epfd, int fd, uint events) @private @if(env::LINUX)
{
	set_epoll_socket_events(epfd, (int)linux::EPOLL_CTL_ADD, fd, events)!;
}

fn void? modify_epoll_socket(int epfd, int fd, uint events) @private @if(env::LINUX)
{
	set_epoll_socket_events(epfd, (int)linux::EPOLL_CTL_MOD, fd, events)!;
}

fn time::Clock evented_deadline(Duration timeout) @private @if(env::LINUX)
{
	if (timeout <= time::DURATION_ZERO) return (time::Clock)ulong::max;
	return clock::now() + timeout;
}

fn EventedConnection* find_evented_connection(List { EventedConnection* }* connections, int fd) @private @if(env::LINUX)
{
	foreach (connection : *connections) if (connection.socket.sock == fd) return connection;
	return null;
}

fn void ensure_evented_input(Server* server, EventedConnection* connection) @private @if(env::LINUX)
{
	if (!connection.input) connection.input = dstring::new_with_capacity(server.allocator, EVENTED_INPUT_INITIAL_CAPACITY);
}

fn void ensure_evented_output(Server* server, EventedConnection* connection) @private @if(env::LINUX)
{
	if (!connection.output) connection.output = dstring::new_with_capacity(server.allocator, EVENTED_OUTPUT_INITIAL_CAPACITY);
}

fn void destroy_evented_connection(Allocator allocator, int epfd, List { EventedConnection* }* connections, EventedConnection* connection) @private @if(env::LINUX)
{
	linux::epoll_ctl(epfd, (int)linux::EPOLL_CTL_DEL, connection.socket.sock, null);
	(void)connection.socket.close();
	connection.input.free();
	connection.output.free();
	for (usz i = 0; i < (usz)connections.len(); i++)
	{
		if ((*connections)[(sz)i] == connection)
		{
			connections.remove_at((sz)i);
			break;
		}
	}
	alloc::free(allocator, connection);
}

fn void? server_accept_new_clients(Server* self, tcp::TcpServerSocket* listener, int epfd, List { EventedConnection* }* connections, usz capacity) @private @if(env::LINUX)
{
	usz accepted;
	while (accepted < EVENTED_ACCEPT_BUDGET && (!capacity || (usz)connections.len() < capacity))
	{
		tcp::TcpSocket? socket_result = tcp::accept(listener);
		if (catch err = socket_result)
		{
			fault socket_err = os::socket_error();
			if (socket_err == io::WOULD_BLOCK || socket_err == io::INTERRUPTED) return;
			return err~;
		}
		tcp::TcpSocket socket = socket_result;
		if (catch nonblocking_error = socket.sock.set_non_blocking(true))
		{
			(void)socket.close();
			return nonblocking_error~;
		}

		if (catch err = set_tcp_no_delay(&socket, true))
		{
			if (catch socket.close()) {}
			return err~;
		}
		EventedConnection* connection = alloc::new(self.allocator, EventedConnection);
		// Initialize the whole state object: alloc::new does not guarantee that
		// fields omitted by piecemeal assignment start as zero/false.
		*connection = {
			.socket = socket,
			// Input and output storage stays unallocated until the connection actually
			// receives a request or produces a response.
			.input = {},
			.output = {},
			.phase = READING,
			.deadline = evented_deadline(self.options.timeouts.header_timeout)
		};
		if (catch err = register_epoll_socket(epfd, socket.sock, linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP))
		{
			connection.input.free();
			connection.output.free();
			alloc::free(self.allocator, connection);
			if (catch socket.close()) {}
			return err~;
		}
		connections.push(connection);
		accepted++;
	}
}

fn void? server_run_event_loop(Server* self, tcp::TcpServerSocket* listener, Handler handler, uint max_requests, void* context) @private @if(env::LINUX)
{
	listener.sock.set_non_blocking(true)!;
	defer catch (void)listener.sock.set_non_blocking(false);

	int epfd = linux::epoll_create1(0);
	if (epfd < 0) return io::GENERAL_ERROR~;
	defer (void)libc::close(epfd);

	register_epoll_socket(epfd, listener.sock, linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP)!;
	bool listener_enabled = true;
	List { EventedConnection* } connections;
	connections.init(self.allocator);
	defer
	{
		while (connections.len()) destroy_evented_connection(self.allocator, epfd, &connections, connections[connections.len() - 1]);
		connections.free();
	};

	linux::EpollEvent[EPOLL_MAX_EVENTS] events;
	uint served;
	uint reserved;

	while (!max_requests || served < max_requests)
	{
		bool capacity_available = !self.options.max_connections || (usz)connections.len() < self.options.max_connections;
		bool request_slots_available = !max_requests || served + reserved < max_requests;
		bool should_listen = capacity_available && request_slots_available;
		if (should_listen != listener_enabled)
		{
			if (should_listen)
			{
				register_epoll_socket(epfd, listener.sock, linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP)!;
			}
			else
			{
				linux::epoll_ctl(epfd, (int)linux::EPOLL_CTL_DEL, listener.sock, null);
			}
			listener_enabled = should_listen;
		}

		int timeout_ms = 50;
		time::Clock now = clock::now();
		foreach (connection : connections)
		{
			if (connection.phase != WRITING && connection.input.len()) timeout_ms = 0;
			if (connection.deadline == (time::Clock)ulong::max) continue;
			if (connection.deadline <= now) { timeout_ms = 0; break; }
			long remaining_ms = (connection.deadline - now).to_ms();
			if (remaining_ms < timeout_ms) timeout_ms = (int)max(1L, remaining_ms);
		}
		int ready = linux::epoll_wait(epfd, &events[0], EPOLL_MAX_EVENTS, timeout_ms);
		if (ready < 0)
		{
			if (libc::errno() == EINTR) continue;
			return io::GENERAL_ERROR~;
		}
		// Retained pipelined bytes need no new kernel readiness edge. Schedule
		// those connections explicitly, still bounded by the event array.
		foreach (connection : connections)
		{
			if (ready == EPOLL_MAX_EVENTS) break;
			if (connection.phase == WRITING || !connection.input.len()) continue;
			bool already_scheduled = false;
			for (int event_index = 0; event_index < ready; event_index++)
			{
				if (events[event_index].data.fd == connection.socket.sock) { already_scheduled = true; break; }
			}
			if (!already_scheduled)
			{
				events[ready] = {};
				events[ready].data.fd = connection.socket.sock;
				ready++;
			}
		}

		for (int i = 0; i < ready; i++)
		{
			int fd = events[i].data.fd;
			uint event_mask = events[i].events;

			if (fd == listener.sock)
			{
				if (listener_enabled) server_accept_new_clients(self, listener, epfd, &connections, self.options.max_connections)!;
				continue;
			}

			EventedConnection* connection = find_evented_connection(&connections, fd);
			if (!connection) continue;
			bool destroy = false;
			if (event_mask & linux::EPOLLERR) destroy = true;
			if (event_mask & (linux::EPOLLHUP | linux::EPOLLRDHUP)) connection.peer_eof = true;

			if (!destroy && connection.phase != WRITING && event_mask & (linux::EPOLLIN | linux::EPOLLHUP | linux::EPOLLRDHUP))
			{
				usz budget = EVENTED_READ_BUDGET;
				char[8192] buffer;
				while (budget)
				{
					usz wanted = min(budget, (usz)buffer.len);
					sz count = libc::recv(fd, &buffer[0], wanted, 0);
					if (count > 0)
					{
						if (connection.phase == IDLE)
						{
							connection.phase = READING;
							connection.deadline = evented_deadline(self.options.timeouts.header_timeout);
						}
						ensure_evented_input(self, connection);
						connection.input.append(buffer[:count]);
						budget -= (usz)count;
						continue;
					}
					if (!count)
					{
						connection.peer_eof = true;
					}
					else if (libc::errno() != EAGAIN && libc::errno() != EWOULDBLOCK && libc::errno() != EINTR)
					{
						destroy = true;
					}
					break;
				}
			}

			uint pipelined;
			while (!destroy && connection.phase != WRITING && connection.input.len() && pipelined < EVENTED_PIPELINE_BUDGET)
			{
				if (max_requests && served + reserved >= max_requests) break;
				EventedInputStream input = { .bytes = connection.input.str_view() };
				Request? request_result = read_request_impl{EventedInputStream*}(self.allocator, &input, self.options.limits);
				if (catch parse_error = request_result)
				{
					if (parse_error == io::EOF || parse_error == io::UNEXPECTED_EOF)
					{
						if (connection.peer_eof) destroy = true;
						break;
					}
					destroy = true;
					break;
				}
				Request request = request_result;
				connection.input.delete(0, (sz)input.offset);
				Response response;
				response_init_impl(&response, self.allocator, 200, "OK");
				if (catch handler_error = handler(&request, &response, context))
				{
					response_free_impl(&response);
					request_free_impl(&request);
					destroy = true;
					break;
				}
				apply_default_connection_policy(self.allocator, &request.headers, &response.headers);
				connection.close_after_write = connection.peer_eof || should_close_connection(&request.headers) || should_close_connection(&response.headers);
				ensure_evented_output(self, connection);
				EventedOutputStream output = { .bytes = &connection.output };
				if (catch write_error = write_response_impl{EventedOutputStream*}(&output, &response, request.method)) destroy = true;
				response_free_impl(&response);
				request_free_impl(&request);
				if (destroy) break;
				connection.phase = WRITING;
				connection.deadline = evented_deadline(self.options.timeouts.write_timeout);
				connection.reserved_request = true;
				reserved++;
				modify_epoll_socket(epfd, fd, linux::EPOLLOUT | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP)!;
				pipelined++;
			}

			if (!destroy && connection.phase == WRITING && event_mask & linux::EPOLLOUT)
			{
				usz budget = EVENTED_WRITE_BUDGET;
				while (budget && connection.write_offset < (usz)connection.output.len())
				{
					usz wanted = min(budget, (usz)connection.output.len() - connection.write_offset);
					sz count = libc::send(fd, connection.output.str_view()[connection.write_offset..].ptr, wanted, MSG_NOSIGNAL);
					if (count > 0)
					{
						connection.write_offset += (usz)count;
						budget -= (usz)count;
						connection.deadline = evented_deadline(self.options.timeouts.write_timeout);
						continue;
					}
					if (count < 0 && libc::errno() != EAGAIN && libc::errno() != EWOULDBLOCK && libc::errno() != EINTR) destroy = true;
					break;
				}
				if (!destroy && connection.write_offset == (usz)connection.output.len())
				{
					connection.output.clear();
					connection.write_offset = 0;
					if (connection.reserved_request) { connection.reserved_request = false; reserved--; served++; }
					if (connection.close_after_write || (max_requests && served >= max_requests))
					{
						destroy = true;
					}
					else
					{
						connection.phase = connection.input.len() ? READING : IDLE;
						connection.deadline = evented_deadline(connection.input.len() ? self.options.timeouts.header_timeout : self.options.timeouts.idle_timeout);
						modify_epoll_socket(epfd, fd, linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP)!;
					}
				}
			}
			if (destroy)
			{
				if (connection.reserved_request) reserved--;
				destroy_evented_connection(self.allocator, epfd, &connections, connection);
			}
		}

		now = clock::now();
		for (usz index = (usz)connections.len(); index > 0; index--)
		{
			EventedConnection* connection = connections[(sz)(index - 1)];
			if (connection.deadline != (time::Clock)ulong::max && connection.deadline <= now)
			{
				if (connection.reserved_request) reserved--;
				destroy_evented_connection(self.allocator, epfd, &connections, connection);
			}
		}
	}
}

fn void? server_serve_evented_impl(Server* self, Handler handler, uint max_requests = 0, void* context = null) @private
{
	$if env::LINUX:
		server_listen_impl(self)!;
		return server_run_event_loop(self, &self.listener, handler, max_requests, context);
	$else
		return server_serve_impl(self, handler, max_requests, context);
	$endif
}

fn void prefork_stop_workers(CInt[] pids, uint count, CInt signal) @private @if(env::LINUX)
{
	for (uint i = 0; i < count; i++)
	{
		if (pids[i] > 0) (void)posix::kill(pids[i], signal);
	}
}

fn void? server_serve_prefork_impl(Server* self, Handler handler, uint workers = 0, void* context = null) @private
{
	$if env::LINUX:
		if (!workers) workers = (uint)cpu::native_cpu();
		if (workers <= 1 || !self.port || self.is_listening)
		{
			return server_serve_evented_impl(self, handler, 0, context);
		}
		if (workers > PREFORK_MAX_WORKERS) workers = PREFORK_MAX_WORKERS;

		prefork_shutdown_requested = false;
		libc::signal(libc::SIGINT, &prefork_signal_handler);
		libc::signal(libc::SIGTERM, &prefork_signal_handler);

		CInt[PREFORK_MAX_WORKERS] pids;
		uint started;
		for (uint i = 0; i < workers; i++)
		{
			CInt pid = fork();
			if (pid < 0)
			{
				prefork_stop_workers(pids[..], started, libc::SIGTERM);
				return io::GENERAL_ERROR~;
			}
			if (!pid)
			{
				libc::signal(libc::SIGINT, null);
				libc::signal(libc::SIGTERM, null);
				tcp::TcpServerSocket listener = server_make_listener(self, true)!;
				defer catch (void)listener.close();
				return server_run_event_loop(self, &listener, handler, 0, context);
			}
			pids[started++] = pid;
		}

		while (started)
		{
			if (prefork_shutdown_requested)
			{
				prefork_stop_workers(pids[..], started, libc::SIGTERM);
			}

			CInt status;
			CInt pid = posix::waitpid(-1, &status, posix::WNOHANG);
			if (pid < 0)
			{
				if (libc::errno() == EINTR) continue;
				prefork_stop_workers(pids[..], started, libc::SIGTERM);
				return io::GENERAL_ERROR~;
			}
			if (!pid)
			{
				if (catch thread::sleep_ms(100)) {}
				continue;
			}

			for (uint i = 0; i < started; i++)
			{
				if (pids[i] == pid)
				{
					pids[i] = pids[started - 1];
					started--;
					break;
				}
			}
		}
		return;
	$else
		return server_serve_impl(self, handler, 0, context);
	$endif
}
