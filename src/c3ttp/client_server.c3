module c3ttp @private;

import std::core::env;
import std::io;
import std::thread::cpu;
import std::net;
import std::net::os;
import std::net::tcp;
import std::os::linux;
import std::time;
import libc;

extern fn CInt getsockname(os::NativeSocket socket, os::SockAddrPtr address, os::Socklen_t* address_len) @if(env::POSIX);
extern fn CInt fork() @if(env::POSIX);

const CInt TCP_NODELAY = 1;
const CInt IPPROTO_TCP = 6;
const int EPOLL_MAX_EVENTS = 256;
const usz TIMED_TCP_STREAM_BUFFER_SIZE = 8192;

fn void? set_tcp_no_delay(tcp::TcpSocket* socket, bool enabled) @private
{
	if (!enabled || socket.ai_addrlen < 2) return;
	CInt flag = 1;
	if (os::setsockopt(socket.sock, IPPROTO_TCP, TCP_NODELAY, &flag, CInt.sizeof) != 0)
	{
		return os::socket_error()~;
	}
}

fn tcp::TcpServerSocket? server_make_listener(Server* self, bool reuse_port) @private
{
	if (reuse_port)
	{
		return tcp::listen(self.host, self.port, (int)self.backlog, REUSEADDR, REUSEPORT)!;
	}
	return tcp::listen(self.host, self.port, (int)self.backlog, REUSEADDR)!;
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
	if (polls[0].revents & (net::POLL_EVENT_ERROR | net::POLL_EVENT_INVALID | net::POLL_EVENT_DISCONNECT))
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
	wait_for_socket_event(stream.socket, net::SUBSCRIBE_ANY_READ, stream.read_timeout, stream.read_timeout_fault)!;
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
		usz to_copy = min(bytes.len, buffered);
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
		wait_for_socket_event(self.socket, net::SUBSCRIBE_ANY_READ, self.read_timeout, self.read_timeout_fault)!;
		return (sz)self.socket.read(bytes)!;
	}

	sz read = timed_tcp_stream_fill_buffer(self)!;
	if (read <= 0) return read;

	usz to_copy = min(bytes.len, timed_tcp_stream_buffered_bytes(self));
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

fn void close_epoll_socket(int epfd, int fd) @private @if(env::LINUX)
{
	linux::epoll_ctl(epfd, (int)linux::EPOLL_CTL_DEL, fd, null);
	(void)libc::close(fd);
}

fn void? register_epoll_socket(int epfd, int fd, uint events) @private @if(env::LINUX)
{
	linux::EpollEvent event = { .events = events };
	event.data.fd = fd;
	if (linux::epoll_ctl(epfd, (int)linux::EPOLL_CTL_ADD, fd, &event) != 0) return io::GENERAL_ERROR~;
}

fn void? server_accept_new_clients(Server* self, tcp::TcpServerSocket* listener, int epfd) @private @if(env::LINUX)
{
	while (true)
	{
		tcp::TcpSocket socket;
		socket.ai_addrlen = socket.ai_addr_storage.len;
		socket.sock = os::accept(listener.sock, (os::SockAddrPtr)&socket.ai_addr_storage, &socket.ai_addrlen);
		if (!socket.sock.is_valid())
		{
			fault err = os::socket_error();
			if (err == io::WOULD_BLOCK || err == io::INTERRUPTED) return;
			return err~;
		}

		if (catch err = set_tcp_no_delay(&socket, true))
		{
			if (catch socket.close()) {}
			return err~;
		}
		if (catch err = register_epoll_socket(epfd, socket.sock, linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP))
		{
			if (catch socket.close()) {}
			return err~;
		}
	}
}

fn void? server_run_event_loop(Server* self, tcp::TcpServerSocket* listener, Handler handler, uint max_requests, void* context) @private @if(env::LINUX)
{
	listener.sock.set_non_blocking(true)!;

	int epfd = linux::epoll_create1(0);
	if (epfd < 0) return io::GENERAL_ERROR~;
	defer (void)libc::close(epfd);

	register_epoll_socket(epfd, listener.sock, linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP)!;

	linux::EpollEvent[EPOLL_MAX_EVENTS] events;
	uint served;
	bool stop;

	while (!stop && (!max_requests || served < max_requests))
	{
		int ready = linux::epoll_wait(epfd, &events[0], EPOLL_MAX_EVENTS, -1);
		if (ready < 0)
		{
			if (libc::errno() == EINTR) continue;
			return io::GENERAL_ERROR~;
		}

		for (int i = 0; i < ready; i++)
		{
			int fd = events[i].data.fd;
			uint event_mask = events[i].events;

			if (fd == listener.sock)
			{
				server_accept_new_clients(self, listener, epfd)!;
				continue;
			}

			if (event_mask & (linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP))
			{
				close_epoll_socket(epfd, fd);
				continue;
			}

			if (!(event_mask & linux::EPOLLIN)) continue;

			tcp::TcpSocket socket = { .sock = (os::NativeSocket)fd };
			bool keep_open = true;
			if (catch err = respond_socket_keepalive_impl(self.allocator, &socket, handler, 1, context, self.options, &keep_open))
			{
				close_epoll_socket(epfd, fd);
				continue;
			}

			served++;
			if (!keep_open) close_epoll_socket(epfd, fd);
			if (max_requests && served >= max_requests)
			{
				stop = true;
				break;
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

fn void? server_serve_prefork_impl(Server* self, Handler handler, uint workers = 0, void* context = null) @private
{
	$if env::LINUX:
		if (!workers) workers = (uint)cpu::native_cpu();
		if (workers <= 1 || !self.port || self.is_listening)
		{
			return server_serve_evented_impl(self, handler, 0, context);
		}

		for (uint i = 1; i < workers; i++)
		{
			CInt pid = fork();
			if (pid < 0) return io::GENERAL_ERROR~;
			if (!pid) break;
		}

		tcp::TcpServerSocket listener = server_make_listener(self, true)!;
		defer catch (void)listener.close();
		return server_run_event_loop(self, &listener, handler, 0, context);
	$else
		return server_serve_impl(self, handler, 0, context);
	$endif
}
