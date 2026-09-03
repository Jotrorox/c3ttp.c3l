module c3ttp @private;

import std::core::env;
import std::core::mem;
import std::io;
import std::net;
import std::net::os;
import std::net::tcp;
import std::thread::cpu;
import std::os::linux;
import std::os::posix;
import libc;

const int SERVER_MAX_EVENTS = 256;
const CInt SERVER_MSG_NOSIGNAL = 0x4000;
const CInt SERVER_TCP_NODELAY = 1;
const CInt SERVER_IPPROTO_TCP = 6;
const uint SERVER_MAX_WORKERS = 1024;

extern fn CInt fork() @feat(POSIX);
extern fn CInt sched_getaffinity(CInt pid, usz cpusetsize, void* mask) @feat(LINUX);
extern fn CInt sched_setaffinity(CInt pid, usz cpusetsize, void* mask) @feat(LINUX);

struct NativeIovec @feat(LINUX)
{
	void* base;
	usz length;
}

struct NativeMessage @feat(LINUX)
{
	void* name;
	uint name_length;
	NativeIovec* vectors;
	usz vector_count;
	void* control;
	usz control_length;
	CInt flags;
}

extern fn sz sendmsg(CInt fd, NativeMessage* message, CInt flags) @feat(LINUX);

enum ConnectionPhase : char @feat(LINUX)
{
	FREE,
	READING,
	WRITING,
}

struct HotConnection @align(64) @feat(LINUX)
{
	int fd;
	ConnectionPhase phase;
	char[] input;
	usz input_length;
	usz consumed;
	RequestParser parser;
	ResponseView response;
	char[512] response_header;
	usz header_length;
	usz header_sent;
	usz body_sent;
	bool suppress_body;
	bool close_after_write;
	bool peer_eof;
	NativeIovec[2] outbound_vectors;
	NativeMessage outbound_message;
}

fn ServerOptions default_server_options_impl() @private
{
	return {
		.backend = AUTO,
		.limits = default_limits_impl(),
		.workers = 1,
		.backlog = 1024,
		.connections_per_worker = 1024,
		.buffer_size = 32768,
		.pin_workers = true,
		.tcp_no_delay = true,
	};
}

fn usz append_text(char[] destination, usz offset, String text) @private @inline
{
	if (offset + text.len > destination.len) return destination.len + 1;
	destination[offset:text.len] = ((char[])text)[..];
	return offset + text.len;
}

fn usz append_decimal(char[] destination, usz offset, usz value) @private @inline
{
	char[32] reversed;
	usz count;
	do
	{
		reversed[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value);
	if (offset + count > destination.len) return destination.len + 1;
	while (count) destination[offset++] = reversed[--count];
	return offset;
}

fn bool build_response_header(HotConnection* connection) @private @feat(LINUX)
{
	ResponseView* response = &connection.response;
	if (!response.status) response.status = 200;
	String reason = reason_phrase(response.status);
	usz offset;
	offset = append_text(connection.response_header[..], offset, "HTTP/1.1 ");
	offset = append_decimal(connection.response_header[..], offset, response.status);
	offset = append_text(connection.response_header[..], offset, " ");
	offset = append_text(connection.response_header[..], offset, reason);
	offset = append_text(connection.response_header[..], offset, "\r\n");
	if (!((response.status >= 100 && response.status < 200) || response.status == 204))
	{
		offset = append_text(connection.response_header[..], offset, "Content-Length: ");
		offset = append_decimal(connection.response_header[..], offset, (usz)response.body.len);
		offset = append_text(connection.response_header[..], offset, "\r\n");
	}
	if (response.content_type.len)
	{
		offset = append_text(connection.response_header[..], offset, "Content-Type: ");
		offset = append_text(connection.response_header[..], offset, response.content_type);
		offset = append_text(connection.response_header[..], offset, "\r\n");
	}
	offset = append_text(connection.response_header[..], offset,
		connection.close_after_write ? "Connection: close\r\n\r\n" : "Connection: keep-alive\r\n\r\n");
	if (offset > connection.response_header.len) return false;
	connection.header_length = offset;
	return true;
}

fn void epoll_set(int epoll_fd, int operation, int fd, uint events, void* data) @private @feat(LINUX)
{
	linux::EpollEvent event = { .events = events };
	event.data.ptr = data;
	(void)linux::epoll_ctl(epoll_fd, operation, fd, &event);
}

fn void close_connection(int epoll_fd, HotConnection* connection) @private @feat(LINUX)
{
	if (connection.phase == FREE) return;
	(void)linux::epoll_ctl(epoll_fd, (int)linux::EPOLL_CTL_DEL, connection.fd, null);
	(void)libc::close(connection.fd);
	char[] input = connection.input;
	*connection = { .fd = -1, .phase = FREE, .input = input };
}

fn HotConnection* free_connection(HotConnection[] connections) @private @feat(LINUX)
{
	foreach (&connection : connections) if (connection.phase == FREE) return connection;
	return null;
}

fn bool transient_socket_error() @private @feat(LINUX)
{
	Errno error = libc::errno();
	return error == EAGAIN || error == EWOULDBLOCK || error == EINTR;
}

fn void prepare_error_response(HotConnection* connection, ushort status) @private @feat(LINUX)
{
	connection.response = { .status = status, .content_type = "text/plain; charset=utf-8", .body = reason_phrase(status), .close = true };
	connection.close_after_write = true;
	connection.suppress_body = false;
	connection.consumed = connection.input_length;
	(void)build_response_header(connection);
	connection.phase = WRITING;
}

fn void process_request(HotConnection* connection, ViewHandler handler, void* context) @private @feat(LINUX)
{
	ParseStatus? parsed = connection.parser.parse(connection.input[:connection.input_length]);
	if (catch parse_error = parsed)
	{
		prepare_error_response(connection,
			parse_error == BODY_TOO_LARGE ? 413 :
			(parse_error == REQUEST_LINE_TOO_LARGE ? 414 :
			(parse_error == HEADER_LINE_TOO_LARGE || parse_error == HEADERS_TOO_LARGE || parse_error == TOO_MANY_HEADERS ? 431 : 400)));
		return;
	}
	if (parsed != ParseStatus.COMPLETE) return;

	connection.response = { .status = 200, .content_type = "text/plain; charset=utf-8" };
	if (catch handler_error = handler(&connection.parser.request, &connection.response, context))
	{
		connection.response = { .status = 500, .content_type = "text/plain; charset=utf-8", .body = "Internal Server Error", .close = true };
	}
	connection.consumed = connection.parser.request.message_length;
	connection.close_after_write = connection.response.close || !connection.parser.request.keep_alive;
	connection.suppress_body = !response_has_body(connection.response.status, connection.parser.request.method_id);
	if (!build_response_header(connection))
	{
		connection.response = { .status = 500, .body = "Internal Server Error", .close = true };
		connection.close_after_write = true;
		(void)build_response_header(connection);
	}
	connection.phase = WRITING;
}

fn void finish_response(int epoll_fd, HotConnection* connection, ViewHandler handler, void* context) @private @feat(LINUX)
{
	if (connection.close_after_write)
	{
		close_connection(epoll_fd, connection);
		return;
	}
	usz remaining = connection.input_length - connection.consumed;
	if (remaining) mem::move(connection.input.ptr, connection.input.ptr + connection.consumed, (sz)remaining);
	connection.input_length = remaining;
	connection.consumed = 0;
	connection.header_length = 0;
	connection.header_sent = 0;
	connection.body_sent = 0;
	connection.response = {};
	connection.parser.init(connection.parser.limits);
	connection.phase = READING;
	if (!remaining && connection.peer_eof)
	{
		close_connection(epoll_fd, connection);
		return;
	}
	epoll_set(epoll_fd, (int)linux::EPOLL_CTL_MOD, connection.fd,
		linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP, connection);
	if (remaining)
	{
		process_request(connection, handler, context);
		if (connection.phase == WRITING)
		{
			epoll_set(epoll_fd, (int)linux::EPOLL_CTL_MOD, connection.fd,
				linux::EPOLLOUT | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP, connection);
		}
	}
}

fn void handle_write(int epoll_fd, HotConnection* connection, ViewHandler handler, void* context) @private @feat(LINUX)
{
	usz body_length = connection.suppress_body ? 0 : (usz)connection.response.body.len;
	while (connection.header_sent < connection.header_length || connection.body_sent < body_length)
	{
		NativeIovec[2] vectors;
		usz vector_count;
		usz header_remaining = connection.header_length - connection.header_sent;
		if (header_remaining)
		{
			vectors[vector_count++] = {
				.base = connection.response_header[connection.header_sent..].ptr,
				.length = header_remaining,
			};
		}
		if (connection.body_sent < body_length)
		{
			vectors[vector_count++] = {
				.base = connection.response.body[connection.body_sent..].ptr,
				.length = body_length - connection.body_sent,
			};
		}
		NativeMessage message = { .vectors = &vectors[0], .vector_count = vector_count };
		sz sent = sendmsg(connection.fd, &message, SERVER_MSG_NOSIGNAL);
		if (sent > 0)
		{
			usz written = (usz)sent;
			usz from_header = min(written, header_remaining);
			connection.header_sent += from_header;
			written -= from_header;
			connection.body_sent += written;
			continue;
		}
		if (sent < 0 && transient_socket_error()) return;
		close_connection(epoll_fd, connection);
		return;
	}
	finish_response(epoll_fd, connection, handler, context);
}

fn void accept_connections(tcp::TcpServerSocket* listener, int epoll_fd, HotConnection[] connections, bool tcp_no_delay) @private @feat(LINUX)
{
	while (true)
	{
		HotConnection* connection = free_connection(connections);
		if (!connection) return;
		tcp::TcpSocket? accepted = tcp::accept(listener);
		if (catch accept_error = accepted)
		{
			if (transient_socket_error()) return;
			return;
		}
		tcp::TcpSocket socket = accepted;
		if (catch nonblocking_error = socket.sock.set_non_blocking(true))
		{
			(void)socket.close();
			continue;
		}
		if (tcp_no_delay)
		{
			CInt enabled = 1;
			(void)os::setsockopt(socket.sock, SERVER_IPPROTO_TCP, SERVER_TCP_NODELAY, &enabled, CInt::size);
		}
		char[] input = connection.input;
		*connection = { .fd = (int)socket.sock, .phase = READING, .input = input };
		connection.parser.init();
		epoll_set(epoll_fd, (int)linux::EPOLL_CTL_ADD, connection.fd,
			linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP, connection);
	}
}

fn void handle_read(int epoll_fd, HotConnection* connection, ViewHandler handler, void* context) @private @feat(LINUX)
{
	while (connection.input_length < connection.input.len)
	{
		char[] available = connection.input[connection.input_length..];
		sz received = libc::recv(connection.fd, available.ptr, available.len, 0);
		if (received > 0)
		{
			connection.input_length += (usz)received;
			continue;
		}
		if (!received)
		{
			connection.peer_eof = true;
			break;
		}
		if (transient_socket_error()) break;
		close_connection(epoll_fd, connection);
		return;
	}
	process_request(connection, handler, context);
	if (connection.phase == READING && connection.input_length == connection.input.len)
	{
		prepare_error_response(connection, 413);
	}
	if (connection.phase == WRITING)
	{
		epoll_set(epoll_fd, (int)linux::EPOLL_CTL_MOD, connection.fd,
			linux::EPOLLOUT | linux::EPOLLERR | linux::EPOLLHUP | linux::EPOLLRDHUP, connection);
	}
	else if (connection.peer_eof)
	{
		close_connection(epoll_fd, connection);
	}
}

fn uint available_cpu_count() @private @feat(LINUX)
{
	ulong[16] mask = {};
	if (sched_getaffinity(0, mask.len * ulong::size, &mask)) return (uint)cpu::native_cpu();
	uint count;
	foreach (ulong word : mask) count += (uint)word.popcount();
	return count ? count : 1;
}

fn void pin_to_cpu(uint worker_index) @private @feat(LINUX)
{
	ulong[16] allowed = {};
	if (sched_getaffinity(0, allowed.len * ulong::size, &allowed)) return;
	uint available;
	foreach (ulong word : allowed) available += (uint)word.popcount();
	if (!available) return;
	uint wanted = worker_index % available;
	foreach (word_index, ulong word : allowed)
	{
		while (word)
		{
			usz bit = (usz)word.ctz();
			if (!wanted)
			{
				ulong[16] selected = {};
				selected[(usz)word_index] = 1UL << bit;
				(void)sched_setaffinity(0, selected.len * ulong::size, &selected);
				return;
			}
			wanted--;
			word &= word - 1;
		}
	}
}

fn void terminate_children(CInt[] children, uint live) @private @feat(LINUX)
{
	foreach (CInt child : children) if (child > 0) (void)posix::kill(child, libc::SIGTERM);
	while (live)
	{
		CInt status;
		CInt child = posix::waitpid(-1, &status, 0);
		if (child > 0)
		{
			live--;
			continue;
		}
		if (libc::errno() != EINTR) return;
	}
}

fn bool valid_worker_pool_size(usz capacity, usz buffer_size, Limits limits) @private @inline @feat(LINUX)
{
	if (!buffer_size || capacity > (usz)~0 / buffer_size) return false;
	if (limits.max_request_line > buffer_size) return false;
	usz remaining = buffer_size - limits.max_request_line;
	if (limits.max_header_bytes > remaining) return false;
	return remaining - limits.max_header_bytes >= 4;
}

fn void? run_epoll_worker(String host, uint port, ViewHandler handler, void* context, ServerOptions options, uint worker_index) @private @feat(LINUX)
{
	if (options.pin_workers) pin_to_cpu(worker_index);
	tcp::TcpServerSocket listener = tcp::listen(host, (int)port, (int)options.backlog, REUSEADDR, REUSEPORT)!;
	defer catch (void)listener.close();
	listener.sock.set_non_blocking(true)!;

	usz capacity = options.connections_per_worker ? options.connections_per_worker : 1024;
	usz buffer_size = options.buffer_size;
	if (!valid_worker_pool_size(capacity, buffer_size, options.limits)) return BUFFER_TOO_SMALL~;
	HotConnection[] connections = mem::new_array_aligned(HotConnection, (sz)capacity);
	defer mem::free_aligned(connections.ptr);
	char[] buffers = mem::new_array(char, (sz)(capacity * buffer_size));
	defer mem::free(buffers.ptr);
	foreach (index, &connection : connections)
	{
		connection.fd = -1;
		connection.phase = FREE;
		connection.input = buffers[(usz)index * buffer_size:buffer_size];
		connection.parser.init(options.limits);
	}

	int epoll_fd = linux::epoll_create1(0);
	if (epoll_fd < 0) return io::GENERAL_ERROR~;
	defer (void)libc::close(epoll_fd);
	epoll_set(epoll_fd, (int)linux::EPOLL_CTL_ADD, (int)listener.sock,
		linux::EPOLLIN | linux::EPOLLERR | linux::EPOLLHUP, null);

	linux::EpollEvent[SERVER_MAX_EVENTS] events;
	while (true)
	{
		int ready = linux::epoll_wait(epoll_fd, &events[0], SERVER_MAX_EVENTS, -1);
		if (ready < 0)
		{
			if (libc::errno() == EINTR) continue;
			return io::GENERAL_ERROR~;
		}
		for (int index = 0; index < ready; index++)
		{
			linux::EpollEvent* event = &events[index];
			if (!event.data.ptr)
			{
				accept_connections(&listener, epoll_fd, connections, options.tcp_no_delay);
				continue;
			}
			HotConnection* connection = (HotConnection*)event.data.ptr;
			if (event.events & linux::EPOLLERR)
			{
				close_connection(epoll_fd, connection);
				continue;
			}
			if (event.events & (linux::EPOLLHUP | linux::EPOLLRDHUP)) connection.peer_eof = true;
			if (connection.phase == READING && event.events & (linux::EPOLLIN | linux::EPOLLHUP | linux::EPOLLRDHUP))
			{
				handle_read(epoll_fd, connection, handler, context);
			}
			if (connection.phase == WRITING && event.events & linux::EPOLLOUT)
			{
				handle_write(epoll_fd, connection, handler, context);
			}
		}
	}
}

const char IORING_OP_SENDMSG = 9;
const char IORING_OP_ACCEPT = 13;
const char IORING_OP_RECV = 27;
const ushort IORING_ACCEPT_MULTISHOT = 1;
const uint IORING_CQE_F_MORE = 1 << 1;
const uint LINUX_SOCK_NONBLOCK = 0x800;
const uint LINUX_SOCK_CLOEXEC = 0x80000;
const ulong URING_ACCEPT_TAG = 1;
const ulong URING_RECV_TAG = 2;
const ulong URING_SEND_TAG = 3;
const ulong URING_TAG_MASK = 3;

fn bool uring_submit_accept(IoUring* ring, int listener_fd) @private @feat(LINUX)
{
	IoUringSqe* sqe = uring_get_sqe(ring);
	if (!sqe) return false;
	sqe.opcode = IORING_OP_ACCEPT;
	sqe.fd = listener_fd;
	sqe.ioprio = IORING_ACCEPT_MULTISHOT;
	sqe.operation_flags = LINUX_SOCK_NONBLOCK | LINUX_SOCK_CLOEXEC;
	sqe.user_data = URING_ACCEPT_TAG;
	return true;
}

fn bool uring_submit_recv(IoUring* ring, HotConnection* connection) @private @feat(LINUX)
{
	if (connection.input_length == connection.input.len) return false;
	IoUringSqe* sqe = uring_get_sqe(ring);
	if (!sqe) return false;
	sqe.opcode = IORING_OP_RECV;
	sqe.fd = connection.fd;
	sqe.address = (ulong)(uptr)(connection.input.ptr + connection.input_length);
	sqe.length = (uint)(connection.input.len - connection.input_length);
	sqe.user_data = (ulong)(uptr)connection | URING_RECV_TAG;
	return true;
}

fn bool uring_submit_send(IoUring* ring, HotConnection* connection) @private @feat(LINUX)
{
	usz body_length = connection.suppress_body ? 0 : (usz)connection.response.body.len;
	usz vector_count;
	usz header_remaining = connection.header_length - connection.header_sent;
	if (header_remaining)
	{
		connection.outbound_vectors[vector_count++] = {
			.base = connection.response_header[connection.header_sent..].ptr,
			.length = header_remaining,
		};
	}
	if (connection.body_sent < body_length)
	{
		connection.outbound_vectors[vector_count++] = {
			.base = connection.response.body[connection.body_sent..].ptr,
			.length = body_length - connection.body_sent,
		};
	}
	if (!vector_count) return false;
	connection.outbound_message = {
		.vectors = &connection.outbound_vectors[0],
		.vector_count = vector_count,
	};
	IoUringSqe* sqe = uring_get_sqe(ring);
	if (!sqe) return false;
	sqe.opcode = IORING_OP_SENDMSG;
	sqe.fd = connection.fd;
	sqe.address = (ulong)(uptr)&connection.outbound_message;
	sqe.length = 1;
	sqe.operation_flags = SERVER_MSG_NOSIGNAL;
	sqe.user_data = (ulong)(uptr)connection | URING_SEND_TAG;
	return true;
}

fn bool transient_uring_result(int result) @private @inline @feat(LINUX)
{
	return result == -4 || result == -11; // -EINTR or -EAGAIN from the raw syscall ABI.
}

fn void close_uring_connection(HotConnection* connection) @private @feat(LINUX)
{
	if (connection.phase == FREE) return;
	(void)libc::close(connection.fd);
	char[] input = connection.input;
	*connection = { .fd = -1, .phase = FREE, .input = input };
}

fn bool finish_uring_response(IoUring* ring, HotConnection* connection, ViewHandler handler, void* context) @private @feat(LINUX)
{
	if (connection.close_after_write)
	{
		close_uring_connection(connection);
		return true;
	}
	usz remaining = connection.input_length - connection.consumed;
	if (remaining) mem::move(connection.input.ptr, connection.input.ptr + connection.consumed, (sz)remaining);
	connection.input_length = remaining;
	connection.consumed = 0;
	connection.header_length = 0;
	connection.header_sent = 0;
	connection.body_sent = 0;
	connection.response = {};
	connection.parser.init(connection.parser.limits);
	connection.phase = READING;
	if (remaining)
	{
		process_request(connection, handler, context);
		if (connection.phase == WRITING) return uring_submit_send(ring, connection);
	}
	return uring_submit_recv(ring, connection);
}

fn void handle_uring_recv(IoUring* ring, HotConnection* connection, int result, ViewHandler handler, void* context) @private @feat(LINUX)
{
	if (result <= 0)
	{
		if (result < 0 && transient_uring_result(result) && uring_submit_recv(ring, connection)) return;
		close_uring_connection(connection);
		return;
	}
	connection.input_length += (usz)result;
	process_request(connection, handler, context);
	if (connection.phase == READING && connection.input_length == connection.input.len)
	{
		prepare_error_response(connection, 413);
	}
	bool submitted = connection.phase == WRITING
		? uring_submit_send(ring, connection)
		: uring_submit_recv(ring, connection);
	if (!submitted) close_uring_connection(connection);
}

fn void handle_uring_send(IoUring* ring, HotConnection* connection, int result, ViewHandler handler, void* context) @private @feat(LINUX)
{
	if (result <= 0)
	{
		if (result < 0 && transient_uring_result(result) && uring_submit_send(ring, connection)) return;
		close_uring_connection(connection);
		return;
	}
	usz written = (usz)result;
	usz header_remaining = connection.header_length - connection.header_sent;
	usz from_header = min(written, header_remaining);
	connection.header_sent += from_header;
	written -= from_header;
	connection.body_sent += written;
	usz body_length = connection.suppress_body ? 0 : (usz)connection.response.body.len;
	if (connection.header_sent == connection.header_length && connection.body_sent == body_length)
	{
		if (!finish_uring_response(ring, connection, handler, context) && connection.phase != FREE)
		{
			close_uring_connection(connection);
		}
		return;
	}
	if (!uring_submit_send(ring, connection)) close_uring_connection(connection);
}

fn void accept_uring_connection(IoUring* ring, int accepted_fd, HotConnection[] connections, ServerOptions options) @private @feat(LINUX)
{
	HotConnection* connection = free_connection(connections);
	if (!connection)
	{
		(void)libc::close(accepted_fd);
		return;
	}
	if (options.tcp_no_delay)
	{
		CInt enabled = 1;
		(void)os::setsockopt((os::NativeSocket)accepted_fd, SERVER_IPPROTO_TCP, SERVER_TCP_NODELAY, &enabled, CInt::size);
	}
	char[] input = connection.input;
	*connection = { .fd = accepted_fd, .phase = READING, .input = input };
	connection.parser.init(options.limits);
	if (!uring_submit_recv(ring, connection)) close_uring_connection(connection);
}

fn void? run_uring_worker(String host, uint port, ViewHandler handler, void* context, ServerOptions options, uint worker_index) @private @feat(LINUX)
{
	if (options.pin_workers) pin_to_cpu(worker_index);
	IoUring ring;
	usz capacity = options.connections_per_worker ? options.connections_per_worker : 1024;
	uint ring_entries = (uint)min((usz)32768, max((usz)256, capacity * 2 + 64));
	if (!uring_init(&ring, ring_entries)) return BACKEND_UNAVAILABLE~;
	defer uring_destroy(&ring);

	tcp::TcpServerSocket listener = tcp::listen(host, (int)port, (int)options.backlog, REUSEADDR, REUSEPORT)!;
	defer catch (void)listener.close();
	usz buffer_size = options.buffer_size;
	if (!valid_worker_pool_size(capacity, buffer_size, options.limits)) return BUFFER_TOO_SMALL~;
	HotConnection[] connections = mem::new_array_aligned(HotConnection, (sz)capacity);
	defer mem::free_aligned(connections.ptr);
	defer foreach (&connection : connections) close_uring_connection(connection);
	char[] buffers = mem::new_array(char, (sz)(capacity * buffer_size));
	defer mem::free(buffers.ptr);
	foreach (index, &connection : connections)
	{
		connection.fd = -1;
		connection.phase = FREE;
		connection.input = buffers[(usz)index * buffer_size:buffer_size];
		connection.parser.init(options.limits);
	}
	if (!uring_submit_accept(&ring, (int)listener.sock)) return BACKEND_UNAVAILABLE~;
	if (!uring_submit_retry(&ring, 0)) return BACKEND_UNAVAILABLE~;

	while (true)
	{
		if (!uring_ready(&ring) && !uring_submit_retry(&ring, 1)) return io::GENERAL_ERROR~;
		uint ready = uring_ready(&ring);
		for (uint index = 0; index < ready; index++)
		{
			IoUringCqe completion = *uring_cqe(&ring, index);
			ulong tag = completion.user_data & URING_TAG_MASK;
			if (tag == URING_ACCEPT_TAG)
			{
				if (completion.result >= 0) accept_uring_connection(&ring, completion.result, connections, options);
				if (!(completion.flags & IORING_CQE_F_MORE))
				{
					if (!uring_submit_accept(&ring, (int)listener.sock)) return io::GENERAL_ERROR~;
				}
				continue;
			}
			HotConnection* connection = (HotConnection*)(uptr)(completion.user_data & ~URING_TAG_MASK);
			if (!connection || connection.phase == FREE) continue;
			if (tag == URING_RECV_TAG)
			{
				handle_uring_recv(&ring, connection, completion.result, handler, context);
			}
			else if (tag == URING_SEND_TAG)
			{
				handle_uring_send(&ring, connection, completion.result, handler, context);
			}
		}
		uring_advance(&ring, ready);
		if (!uring_submit_retry(&ring, 0)) return io::GENERAL_ERROR~;
	}
}

fn void? run_linux_worker(bool use_uring, String host, uint port, ViewHandler handler, void* context, ServerOptions options, uint worker_index) @private @feat(LINUX)
{
	if (use_uring) return run_uring_worker(host, port, handler, context, options, worker_index);
	return run_epoll_worker(host, port, handler, context, options, worker_index);
}

fn void? serve_linux(String host, uint port, ViewHandler handler, void* context, ServerOptions options) @private @feat(LINUX)
{
	bool use_uring = options.backend != POLL && io_uring_available_impl();
	if (options.backend == IO_URING && !use_uring) return BACKEND_UNAVAILABLE~;
	uint workers = options.workers;
	if (!workers) workers = available_cpu_count();
	if (workers <= 1) return run_linux_worker(use_uring, host, port, handler, context, options, 0);
	if (workers > SERVER_MAX_WORKERS) workers = SERVER_MAX_WORKERS;

	CInt[SERVER_MAX_WORKERS] children;
	uint started;
	for (uint index = 0; index < workers; index++)
	{
		CInt child = fork();
		if (child < 0)
		{
			terminate_children(children[:started], started);
			return io::GENERAL_ERROR~;
		}
		if (!child)
		{
			if (catch worker_error = run_linux_worker(use_uring, host, port, handler, context, options, index)) libc::exit(1);
			libc::exit(0);
		}
		children[started++] = child;
	}
	while (started)
	{
		CInt status;
		CInt child = posix::waitpid(-1, &status, 0);
		if (child < 0)
		{
			if (libc::errno() == EINTR) continue;
			return io::GENERAL_ERROR~;
		}
		started--;
		foreach (&worker : children[:workers]) if (*worker == child) { *worker = 0; break; }
		terminate_children(children[:workers], started);
		return io::GENERAL_ERROR~;
	}
}

fn void? serve_impl(String host, uint port, ViewHandler handler, void* context, ServerOptions options) @private
{
	$if env::LINUX:
		return serve_linux(host, port, handler, context, options);
	$else
		return BACKEND_UNAVAILABLE~;
	$endif
}
