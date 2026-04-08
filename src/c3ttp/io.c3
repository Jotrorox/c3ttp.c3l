module c3ttp @private;

import std::core::mem::alloc;
import std::io;
import std::time;

const usz HTTP_WRITE_BUFFER_SIZE = 8192;

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
	char[HTTP_WRITE_BUFFER_SIZE] scratch = {};
	io::WriteBuffer buffered;
	buffered.init(out_stream, scratch[..]);
	io::fprintf(&buffered, "%s %s %s\r\n", request.method, request.target, request.version)!;
	HeaderInfo info;
	write_headers(&buffered, &request.headers, true, request.body, &info)!;
	validate_trailers(&request.trailers, info.chunked)!;
	write_body(&buffered, info.chunked, &request.trailers, request.body)!;
	buffered.flush()!;
}

fn void? write_request_from_impl(OutStream out_stream, Request* request, InStream body_stream, usz content_length = 0) @private
{
	validate_version(request.version)!;
	validate_method(request.method)!;
	validate_request_target(request.method, request.target)!;
	char[HTTP_WRITE_BUFFER_SIZE] scratch = {};
	io::WriteBuffer buffered;
	buffered.init(out_stream, scratch[..]);
	io::fprintf(&buffered, "%s %s %s\r\n", request.method, request.target, request.version)!;
	HeaderInfo info;
	write_headers(&buffered, &request.headers, true, "", &info, true, content_length)!;
	validate_trailers(&request.trailers, info.chunked)!;
	write_stream_body(&buffered, body_stream, info.chunked, &request.trailers, content_length)!;
	buffered.flush()!;
}

fn void? write_response_impl(Stream stream, Response* response, String request_method = "") <Stream> @private
{
	OutStream out_stream = (OutStream)stream;
	validate_version(response.version)!;
	char[HTTP_WRITE_BUFFER_SIZE] scratch = {};
	io::WriteBuffer buffered;
	buffered.init(out_stream, scratch[..]);
	io::fprintf(&buffered, "%s %d %s\r\n", response.version, response.status, response.reason)!;
	HeaderInfo info;
	write_headers(&buffered, &response.headers, false, response.body, &info, response_should_emit_implicit_content_length(response.status, request_method))!;
	validate_trailers(&response.trailers, info.chunked)!;
	if (!response_has_no_message_body(response.status, request_method))
	{
		write_body(&buffered, info.chunked, &response.trailers, response.body)!;
	}
	buffered.flush()!;
}

fn void? write_response_from_impl(OutStream out_stream, Response* response, InStream body_stream, usz content_length = 0, String request_method = "") @private
{
	validate_version(response.version)!;
	char[HTTP_WRITE_BUFFER_SIZE] scratch = {};
	io::WriteBuffer buffered;
	buffered.init(out_stream, scratch[..]);
	io::fprintf(&buffered, "%s %d %s\r\n", response.version, response.status, response.reason)!;
	HeaderInfo info;
	write_headers(&buffered, &response.headers, false, "", &info, response_should_emit_implicit_content_length(response.status, request_method), content_length)!;
	validate_trailers(&response.trailers, info.chunked)!;
	if (!response_has_no_message_body(response.status, request_method))
	{
		write_stream_body(&buffered, body_stream, info.chunked, &response.trailers, content_length)!;
	}
	buffered.flush()!;
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

fn void? read_headers_and_body(Allocator allocator, Stream stream, HeaderList* headers, HeaderList* trailers, String* body, bool require_host, ResourceLimits limits = default_resource_limits_impl(), bool read_body = true) <Stream> @private
{
	set_stream_read_timeout{$typeof(stream)}(stream, get_stream_header_timeout{$typeof(stream)}(stream), HEADER_TIMEOUT);
	read_header_block(allocator, stream, headers, limits)!;

	HeaderInfo info;
	analyze_headers(headers, require_host, &info)!;
	if (!read_body)
	{
		set_empty_body(allocator, body);
		clear_headers(trailers);
		return;
	}

	if (info.chunked)
	{
		set_stream_read_timeout{$typeof(stream)}(stream, get_stream_body_timeout{$typeof(stream)}(stream), READ_TIMEOUT);
		read_chunked_body{$typeof(stream)}(allocator, stream, body, trailers, limits)!;
		return;
	}
	clear_headers(trailers);

	if (!info.has_content_length)
	{
		set_empty_body(allocator, body);
		return;
	}

	usz content_length = info.content_length_text.to_uint()!;
	if (content_length > limits.max_buffered_body_size) return BUFFERED_BODY_TOO_LARGE~;
	if (!content_length)
	{
		set_empty_body(allocator, body);
		return;
	}
	set_stream_read_timeout{$typeof(stream)}(stream, get_stream_body_timeout{$typeof(stream)}(stream), READ_TIMEOUT);
	char* buffer = alloc::alloc_array(allocator, char, content_length + 1);
	usz read;
	while (read < content_length)
	{
		usz? n_value = stream.read(buffer[read:content_length - read]);
		if (catch err = n_value)
		{
			alloc::free(allocator, buffer);
			return err~;
		}
		usz n = n_value;
		if (!n)
		{
			alloc::free(allocator, buffer);
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

	HeaderInfo info;
	analyze_headers(headers, require_host, &info)!;
	if (!read_body)
	{
		clear_headers(trailers);
		return;
	}

	if (info.chunked)
	{
		set_stream_read_timeout{$typeof(in_stream)}(in_stream, get_stream_body_timeout{$typeof(in_stream)}(in_stream), READ_TIMEOUT);
		read_chunked_body_to(allocator, in_stream, body_stream, trailers, limits)!;
		return;
	}
	clear_headers(trailers);

	if (!info.has_content_length) return;
	usz content_length = info.content_length_text.to_uint()!;
	if (!content_length) return;
	set_stream_read_timeout{$typeof(in_stream)}(in_stream, get_stream_body_timeout{$typeof(in_stream)}(in_stream), READ_TIMEOUT);
	copy_exact_to_stream(in_stream, body_stream, content_length)!;
}

fn void? read_chunked_body(Allocator allocator, Stream stream, String* body, HeaderList* trailers, ResourceLimits limits = default_resource_limits_impl()) <Stream> @private
{
	DString chunks = dstring::new_with_capacity(allocator, 32);
	defer chunks.free();
	char[4096] buffer = {};
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

		chunks.reserve(chunk_size);
		usz remaining = chunk_size;
		while (remaining)
		{
			usz slice_len = min(buffer.len, remaining);
			usz n = stream.read(buffer[:slice_len])!;
			if (!n) return io::UNEXPECTED_EOF~;
			chunks.append_bytes(buffer[:n]);
			remaining -= n;
		}

		char[2] chunk_crlf = {};
		read_exact(stream, chunk_crlf[..])!;
		if ((String)chunk_crlf[..] != "\r\n") return INVALID_CHUNK~;

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

fn void? write_headers(OutStream stream, HeaderList* headers, bool require_host, String body, HeaderInfo* info_out, bool include_implicit_content_length = true, usz explicit_content_length = 0) @private
{
	io::ByteWriter header_block;
	header_block.tinit();
	defer header_block.destroy()!!;

	HeaderInfo info = {};
	bool seen_transfer_encoding = false;
	bool seen_connection = false;

	foreach (header : *headers)
	{
		analyze_header(header, &info, &seen_transfer_encoding, &seen_connection)!;
		if (header_name_eq(header.name, "Content-Length")) continue;
		io::fprintf(&header_block, "%s: %s\r\n", header.name, header.value)!;
	}
	if (require_host && !info.has_host) return MISSING_HOST~;
	if (info.chunked && info.has_content_length) return CONFLICTING_BODY_HEADERS~;

	if (include_implicit_content_length && !info.chunked)
	{
		usz body_length = explicit_content_length;
		if (!explicit_content_length && body) body_length = body.len;
		io::fprintf(&header_block, "Content-Length: %d\r\n", body_length)!;
	}
	io::fprintf(&header_block, "\r\n")!;
	write_exact(stream, header_block.array_view())!;
	*info_out = info;
}

fn void? write_body(OutStream stream, bool use_chunked, HeaderList* trailers, String body) @private
{
	if (!use_chunked)
	{
		write_exact(stream, body)!;
		return;
	}
	write_chunked_body(stream, body, trailers)!;
}

fn void? write_stream_body(OutStream out_stream, InStream body_stream, bool use_chunked, HeaderList* trailers, usz content_length) @private
{
	if (!use_chunked)
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
		write_exact(stream, body)!;
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
		write_exact(out_stream, buffer[:read])!;
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
		DString line = dstring::temp_with_capacity(min(limit ? limit : (usz)256, (usz)256));
		$if Stream == TimedTcpStream*:
			while (true)
			{
				if (!timed_tcp_stream_buffered_bytes(stream))
				{
					sz read = timed_tcp_stream_fill_buffer(stream)!;
					if (!read)
					{
						if (!line.len()) return io::EOF~;
						return io::UNEXPECTED_EOF~;
					}
				}

				usz segment_start = stream.read_buffer_start;
				usz segment_end = stream.read_buffer_end;
				usz line_end = segment_end;
				bool has_newline = false;
				for (usz i = segment_start; i < segment_end; i++)
				{
					if (stream.read_buffer_storage[i] == '\n')
					{
						line_end = i;
						stream.read_buffer_start = i + 1;
						has_newline = true;
						break;
					}
				}

				for (usz i = segment_start; i < line_end; i++)
				{
					char c = stream.read_buffer_storage[i];
					if (c == '\r') continue;
					if (limit && line.len() >= limit) return too_long_fault~;
					line.append_char(c);
				}
				if (!has_newline)
				{
					stream.read_buffer_start = segment_end;
				}

				if (stream.read_buffer_start == stream.read_buffer_end)
				{
					timed_tcp_stream_reset_buffer(stream);
				}

				if (has_newline) return line.copy_str(allocator);
			}
		$else
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
		$endif
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
		write_exact(out_stream, buffer[:read])!;
		remaining -= read;
	}
}

fn void? write_exact(OutStream stream, char[] bytes) @private
{
	usz written = 0;
	while (written < bytes.len)
	{
		// Keep slices comfortably smaller than the HTTP write buffer so WriteBuffer
		// batches body bytes together with any buffered framing instead of bypassing
		// the buffer with a direct large write.
		usz chunk = min(bytes.len - written, HTTP_WRITE_BUFFER_SIZE / 2);
		sz? n_value = stream.write(bytes[written:chunk]);
		if (catch err = n_value) return err~;
		sz n = n_value;
		if (n <= 0) return io::INCOMPLETE_WRITE~;
		written += (usz)n;
	}
}
