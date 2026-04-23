module c3ttp @private;

import std::time;

const String HTTP_11 @private = "HTTP/1.1";

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

fn String request_query_impl(Request* self) @private
{
	if (try idx = self.target.index_of_char('?')) return self.target[idx + 1..];
	return "";
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
	return { .timeout = timeout, .tcp_no_delay = true };
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
