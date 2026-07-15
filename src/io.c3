module c3ttp @private;

import std::core::mem::alloc;
import std::io;
import std::time;

const usz HTTP_WRITE_BUFFER_SIZE = 8192;

struct HttpLineBuffer
{
	Allocator allocator;
	char* storage;
	usz capacity;
	usz length;
}

<*
 @require allocator != null : "allocator must be set"
*>
fn Request? read_request_impl(Allocator allocator, Stream stream, ResourceLimits limits = default_resource_limits_impl()) <Stream> @private
{
	HttpLineBuffer line_buffer;
	init_http_line_buffer(&line_buffer, allocator, (usz)max((sz)limits.max_request_line_size, (sz)limits.max_header_line_size));
	defer free_http_line_buffer(&line_buffer);

	String line = read_http_line{$Typeof(stream)}(&line_buffer, stream, limits.max_request_line_size, REQUEST_LINE_TOO_LARGE)!;
	Request request = parse_request_line(allocator, line)!;
	if (catch err = read_headers_and_body{$Typeof(stream)}(allocator, &line_buffer, stream, &request.headers, &request.trailers, &request.body, true, limits))
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
	HttpLineBuffer line_buffer;
	init_http_line_buffer(&line_buffer, allocator, (usz)max((sz)limits.max_request_line_size, (sz)limits.max_header_line_size));
	defer free_http_line_buffer(&line_buffer);

	String line = read_http_line{$Typeof(in_stream)}(&line_buffer, in_stream, limits.max_request_line_size, REQUEST_LINE_TOO_LARGE)!;
	Request request = parse_request_line(allocator, line)!;
	if (catch err = read_headers_and_body_to(allocator, &line_buffer, in_stream, body_stream, &request.headers, &request.trailers, true, limits))
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
	HttpLineBuffer line_buffer;
	init_http_line_buffer(&line_buffer, allocator, (usz)max((sz)limits.max_request_line_size, (sz)limits.max_header_line_size));
	defer free_http_line_buffer(&line_buffer);

	String line = read_http_line{$Typeof(stream)}(&line_buffer, stream, limits.max_request_line_size, REQUEST_LINE_TOO_LARGE)!;
	Response response = parse_status_line(allocator, line)!;
	if (catch err = read_headers_and_body{$Typeof(stream)}(allocator, &line_buffer, stream, &response.headers, &response.trailers, &response.body, false, limits, !response_has_no_message_body(response.status, request_method)))
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
	HttpLineBuffer line_buffer;
	init_http_line_buffer(&line_buffer, allocator, (usz)max((sz)limits.max_request_line_size, (sz)limits.max_header_line_size));
	defer free_http_line_buffer(&line_buffer);

	String line = read_http_line{$Typeof(in_stream)}(&line_buffer, in_stream, limits.max_request_line_size, REQUEST_LINE_TOO_LARGE)!;
	Response response = parse_status_line(allocator, line)!;
	if (catch err = read_headers_and_body_to(allocator, &line_buffer, in_stream, body_stream, &response.headers, &response.trailers, false, limits, !response_has_no_message_body(response.status, request_method)))
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
	HeaderInfo preflight;
	analyze_headers(&request.headers, true, &preflight)!;
	validate_trailers(&request.trailers, preflight.chunked)!;
	validate_outbound_length(&preflight, request.body.len, true)!;
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
	HeaderInfo preflight;
	analyze_headers(&request.headers, true, &preflight)!;
	validate_trailers(&request.trailers, preflight.chunked)!;
	validate_outbound_length(&preflight, content_length, true)!;
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
	validate_status_and_reason(response.status, response.reason)!;
	HeaderInfo preflight;
	analyze_headers(&response.headers, false, &preflight)!;
	validate_trailers(&response.trailers, preflight.chunked)!;
	validate_outbound_length(&preflight, response.body.len, !response_has_no_message_body(response.status, request_method))!;
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
	validate_status_and_reason(response.status, response.reason)!;
	HeaderInfo preflight;
	analyze_headers(&response.headers, false, &preflight)!;
	validate_trailers(&response.trailers, preflight.chunked)!;
	validate_outbound_length(&preflight, content_length, !response_has_no_message_body(response.status, request_method))!;
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
	write_request_impl{$Typeof(stream)}(stream, request)!;
	for (uint informational = 0; ; informational++)
	{
		Response response = read_response_impl{$Typeof(stream)}(allocator, stream, request.method)!;
		if (response.status < 100 || response.status >= 200 || response.status == 101) return response;
		response_free_impl(&response);
		if (informational >= 15) return TOO_MANY_INFORMATIONAL_RESPONSES~;
	}
}

fn void? respond_once_impl(Allocator allocator, Stream stream, Handler handler, void* context) <Stream> @private
{
	respond_impl{$Typeof(stream)}(allocator, stream, handler, 1, context)!;
}

fn void? respond_impl(Allocator allocator, Stream stream, Handler handler, uint max_requests, void* context) <Stream> @private
{
	uint handled;
	while (!max_requests || handled < max_requests)
	{
		Request request = read_request_impl{$Typeof(stream)}(allocator, stream)!;
		defer request_free_impl(&request);

		Response response;
		response_init_impl(&response, allocator, 200, "OK");
		defer response_free_impl(&response);

		handler(&request, &response, context)!;
		apply_default_connection_policy(allocator, &request.headers, &response.headers);
		write_response_impl{$Typeof(stream)}(stream, &response, request.method)!;
		handled++;
		if (should_close_connection(&request.headers) || should_close_connection(&response.headers)) return;
	}
}

fn Request? parse_request_line(Allocator allocator, String line) @private
{
	String method;
	String target;
	String version;
	parse_request_line_parts(line, &method, &target, &version)!;
	validate_version(version)!;
	validate_method(method)!;
	validate_request_target(method, target)!;

	Request request;
	request_init_impl(&request, allocator, method, target, "", version);
	request.body.free(allocator);
	request.body = {};
	return request;
}

fn Response? parse_status_line(Allocator allocator, String line) @private
{
	String version;
	String status_text;
	String reason;
	parse_status_line_parts(line, &version, &status_text, &reason)!;
	validate_version(version)!;
	if (status_text.len != 3) return INVALID_STATUS_LINE~;
	foreach (c : status_text) if (c < '0' || c > '9') return INVALID_STATUS_LINE~;
	ushort status = (ushort)((status_text[0] - '0') * 100 + (status_text[1] - '0') * 10 + status_text[2] - '0');
	validate_status_and_reason(status, reason)!;

	Response response;
	response_init_impl(&response, allocator, status, reason, "", version);
	response.body.free(allocator);
	response.body = {};
	return response;
}

fn void? read_headers_and_body(Allocator allocator, HttpLineBuffer* line_buffer, Stream stream, HeaderList* headers, HeaderList* trailers, String* body, bool require_host, ResourceLimits limits = default_resource_limits_impl(), bool read_body = true) <Stream> @private
{
	set_stream_read_timeout{$Typeof(stream)}(stream, get_stream_header_timeout{$Typeof(stream)}(stream), HEADER_TIMEOUT);
	read_header_block(allocator, line_buffer, stream, headers, limits)!;

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
		set_stream_read_timeout{$Typeof(stream)}(stream, get_stream_body_timeout{$Typeof(stream)}(stream), READ_TIMEOUT);
		read_chunked_body{$Typeof(stream)}(allocator, line_buffer, stream, body, trailers, limits)!;
		return;
	}
	clear_headers(trailers);

	if (!info.has_content_length)
	{
		if (require_host)
		{
			set_empty_body(allocator, body);
			return;
		}
		read_close_delimited_body(allocator, stream, body, limits)!;
		return;
	}

	usz content_length = parse_content_length(info.content_length_text)!;
	if (content_length > limits.max_buffered_body_size) return BUFFERED_BODY_TOO_LARGE~;
	if (!content_length)
	{
		set_empty_body(allocator, body);
		return;
	}
	set_stream_read_timeout{$Typeof(stream)}(stream, get_stream_body_timeout{$Typeof(stream)}(stream), READ_TIMEOUT);
	char* buffer = alloc::alloc_array(allocator, char, (sz)(content_length + 1));
	usz read;
	while (read < content_length)
	{
		sz? n_value = stream.read(buffer[read:content_length - read]);
		if (catch err = n_value)
		{
			alloc::free(allocator, buffer);
			return err~;
		}
		usz n = (usz)n_value;
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

fn void? read_headers_and_body_to(Allocator allocator, HttpLineBuffer* line_buffer, InStream in_stream, OutStream body_stream, HeaderList* headers, HeaderList* trailers, bool require_host, ResourceLimits limits = default_resource_limits_impl(), bool read_body = true) @private
{
	set_stream_read_timeout{$Typeof(in_stream)}(in_stream, get_stream_header_timeout{$Typeof(in_stream)}(in_stream), HEADER_TIMEOUT);
	read_header_block(allocator, line_buffer, in_stream, headers, limits)!;

	HeaderInfo info;
	analyze_headers(headers, require_host, &info)!;
	if (!read_body)
	{
		clear_headers(trailers);
		return;
	}

	if (info.chunked)
	{
		set_stream_read_timeout{$Typeof(in_stream)}(in_stream, get_stream_body_timeout{$Typeof(in_stream)}(in_stream), READ_TIMEOUT);
		read_chunked_body_to(allocator, line_buffer, in_stream, body_stream, trailers, limits)!;
		return;
	}
	clear_headers(trailers);

	if (!info.has_content_length)
	{
		if (!require_host) copy_to_eof(in_stream, body_stream)!;
		return;
	}
	usz content_length = parse_content_length(info.content_length_text)!;
	if (!content_length) return;
	set_stream_read_timeout{$Typeof(in_stream)}(in_stream, get_stream_body_timeout{$Typeof(in_stream)}(in_stream), READ_TIMEOUT);
	copy_exact_to_stream(in_stream, body_stream, content_length)!;
}

fn void? read_chunked_body(Allocator allocator, HttpLineBuffer* line_buffer, Stream stream, String* body, HeaderList* trailers, ResourceLimits limits = default_resource_limits_impl()) <Stream> @private
{
	DString chunks = dstring::new_with_capacity(allocator, 32);
	defer chunks.free();
	char[4096] buffer = {};
	usz total_size;

	while (true)
	{
		String line = read_http_line{$Typeof(stream)}(line_buffer, stream, limits.max_header_line_size, HEADER_LINE_TOO_LARGE)!;

		usz chunk_size = parse_chunk_size_line(line)!;
		if (chunk_size > limits.max_chunk_size) return CHUNK_TOO_LARGE~;
		if (!chunk_size)
		{
			read_trailers(allocator, line_buffer, stream, trailers, limits)!;
			(*body).free(allocator);
			*body = chunks.copy_str(allocator);
			chunks.free();
			return;
		}
		if (total_size > limits.max_chunked_body_size || chunk_size > limits.max_chunked_body_size - total_size) return CHUNKED_BODY_TOO_LARGE~;
		if (total_size > limits.max_buffered_body_size || chunk_size > limits.max_buffered_body_size - total_size) return BUFFERED_BODY_TOO_LARGE~;

		chunks.reserve((sz)chunk_size);
		usz remaining = chunk_size;
		while (remaining)
		{
			usz slice_len = min((usz)buffer.len, remaining);
			usz n = (usz)stream.read(buffer[:slice_len])!;
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

fn void? read_chunked_body_to(Allocator allocator, HttpLineBuffer* line_buffer, InStream in_stream, OutStream body_stream, HeaderList* trailers, ResourceLimits limits = default_resource_limits_impl()) @private
{
	char[4096] buffer = {};
	usz total_size;

	while (true)
	{
		String line = read_http_line{$Typeof(in_stream)}(line_buffer, in_stream, limits.max_header_line_size, HEADER_LINE_TOO_LARGE)!;

		usz chunk_size = parse_chunk_size_line(line)!;
		if (chunk_size > limits.max_chunk_size) return CHUNK_TOO_LARGE~;
		if (!chunk_size)
		{
			read_trailers(allocator, line_buffer, in_stream, trailers, limits)!;
			return;
		}
		if (total_size > limits.max_chunked_body_size || chunk_size > limits.max_chunked_body_size - total_size) return CHUNKED_BODY_TOO_LARGE~;

		copy_exact_chunk_to_stream(in_stream, body_stream, buffer[..], chunk_size)!;
		char[2] chunk_crlf = {};
		read_exact(in_stream, chunk_crlf[..])!;
		if ((String)chunk_crlf[..] != "\r\n") return INVALID_CHUNK~;
		total_size += chunk_size;
	}
}

fn usz? parse_chunk_size_line(String line) @private
{
	if (!line) return INVALID_CHUNK~;
	usz end = (usz)(line.index_of_char(';') ?? (sz)line.len);
	if (!end) return INVALID_CHUNK~;
	usz value;
	usz max_value = ~0;
	foreach (c : line[:end])
	{
		usz digit;
		if (c >= '0' && c <= '9') { digit = (usz)(c - '0'); }
		else if (c >= 'a' && c <= 'f') { digit = (usz)(c - 'a' + 10); }
		else if (c >= 'A' && c <= 'F') { digit = (usz)(c - 'A' + 10); }
		else { return INVALID_CHUNK~; }
		if (value > (max_value - digit) / 16) return INVALID_CHUNK~;
		value = value * 16 + digit;
	}
	if (end < line.len) validate_chunk_extensions(line[end ..])!;
	return value;
}

fn void? validate_chunk_extensions(String extensions) @private
{
	usz i;
	while (i < extensions.len)
	{
		if (extensions[i++] != ';') return INVALID_CHUNK~;
		usz name_start = i;
		while (i < extensions.len && is_tchar(extensions[i])) i++;
		if (i == name_start) return INVALID_CHUNK~;
		if (i == extensions.len || extensions[i] == ';') continue;
		if (extensions[i++] != '=' || i == extensions.len) return INVALID_CHUNK~;
		if (extensions[i] == '"')
		{
			i++;
			bool closed;
			while (i < extensions.len)
			{
				char c = extensions[i++];
				if (c == '"') { closed = true; break; }
				if (c == '\\')
				{
					if (i == extensions.len) return INVALID_CHUNK~;
					c = extensions[i++];
					if (c == 0x7f || (c < 0x20 && c != '\t')) return INVALID_CHUNK~;
				}
				else if (c == 0x7f || (c < 0x20 && c != '\t')) return INVALID_CHUNK~;
			}
			if (!closed) return INVALID_CHUNK~;
		}
		else
		{
			usz value_start = i;
			while (i < extensions.len && is_tchar(extensions[i])) i++;
			if (i == value_start) return INVALID_CHUNK~;
		}
		if (i < extensions.len && extensions[i] != ';') return INVALID_CHUNK~;
	}
}

fn Header? parse_header(Allocator allocator, String line) @private
{
	if (!line || line[0] == ' ' || line[0] == '\t') return INVALID_HEADER~;
	sz? split_value = line.index_of_char(':');
	if (catch err = split_value) return INVALID_HEADER~;
	usz split = (usz)split_value;
	String name = line[:split];
	String value = line[split + 1 ..].trim();
	validate_field_name(name)!;
	validate_field_value(value)!;
	return {
		.name = name.copy(allocator),
		.value = value.copy(allocator)
	};
}

fn void? read_header_block(Allocator allocator, HttpLineBuffer* line_buffer, InStream stream, HeaderList* headers, ResourceLimits limits = default_resource_limits_impl()) @private
{
	clear_headers(headers);
	usz total_bytes;
	while (true)
	{
		String line = read_http_line{$Typeof(stream)}(line_buffer, stream, limits.max_header_line_size, HEADER_LINE_TOO_LARGE)!;
		if (!line)
		{
			if (total_bytes > limits.max_total_header_bytes || 2 > limits.max_total_header_bytes - total_bytes) return HEADERS_TOO_LARGE~;
			break;
		}
		if ((usz)headers.len() >= limits.max_header_count) return TOO_MANY_HEADERS~;
		if (total_bytes > limits.max_total_header_bytes || line.len > limits.max_total_header_bytes - total_bytes ||
			line.len + 2 > limits.max_total_header_bytes - total_bytes) return HEADERS_TOO_LARGE~;
		headers.push(parse_header(allocator, line)!);
		total_bytes += line.len + 2;
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
		if (header_name_eq(header.name, "Content-Length"))
		{
			if (!include_implicit_content_length) io::fprintf(&header_block, "%s: %s\r\n", header.name, header.value)!;
			continue;
		}
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
		sz? read_value = body_stream.read(buffer[..]);
		if (catch err = read_value)
		{
			if (err == io::EOF) break;
			return err~;
		}
		usz read = (usz)read_value;
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

fn void? read_trailers(Allocator allocator, HttpLineBuffer* line_buffer, InStream stream, HeaderList* trailers, ResourceLimits limits = default_resource_limits_impl()) @private
{
	read_header_block(allocator, line_buffer, stream, trailers, limits)!;
	validate_trailers(trailers, true)!;
}

fn void init_http_line_buffer(HttpLineBuffer* self, Allocator allocator, usz initial_capacity = 0) @private
{
	self.allocator = allocator;
	self.capacity = max(initial_capacity, (usz)256);
	self.storage = alloc::alloc_array(allocator, char, (sz)(self.capacity + 1));
	self.storage[0] = 0;
	self.length = 0;
}

fn void free_http_line_buffer(HttpLineBuffer* self) @private
{
	if (!self.storage) return;
	alloc::free(self.allocator, self.storage);
	*self = {};
}

fn void reset_http_line_buffer(HttpLineBuffer* self) @private
{
	self.length = 0;
	self.storage[0] = 0;
}

fn void ensure_http_line_capacity(HttpLineBuffer* self, usz needed_length) @private
{
	if (needed_length <= self.capacity) return;
	usz new_capacity = max(self.capacity * 2, needed_length);
	char* resized = alloc::alloc_array(self.allocator, char, (sz)(new_capacity + 1));
	usz copied = 0;
	while (copied < self.length)
	{
		resized[copied] = self.storage[copied];
		copied++;
	}
	resized[self.length] = 0;
	alloc::free(self.allocator, self.storage);
	self.storage = resized;
	self.capacity = new_capacity;
}

fn void? append_http_line_char(HttpLineBuffer* self, char c, usz limit, fault too_long_fault) @private
{
	if (limit && self.length >= limit) return too_long_fault~;
	ensure_http_line_capacity(self, self.length + 1);
	self.storage[self.length++] = c;
	self.storage[self.length] = 0;
}

fn String http_line_view(HttpLineBuffer* self) @private
{
	return (String)self.storage[:self.length];
}

fn String? read_http_line(HttpLineBuffer* line_buffer, Stream stream, usz limit, fault too_long_fault) <Stream> @private
{
	reset_http_line_buffer(line_buffer);
	bool saw_cr;
	while (true)
	{
		char? c_value = stream.read_byte();
		if (catch err = c_value)
		{
			if (err == io::EOF && !line_buffer.length && !saw_cr) return io::EOF~;
			if (err == io::EOF) return io::UNEXPECTED_EOF~;
			return err~;
		}

		char c = c_value;
		if (saw_cr)
		{
			if (c != '\n') return INVALID_LINE_ENDING~;
			return http_line_view(line_buffer);
		}
		if (c == '\n') return INVALID_LINE_ENDING~;
		if (c == '\r')
		{
			saw_cr = true;
			continue;
		}
		// Include the mandatory CRLF in the configured wire-size limit.
		if (limit && line_buffer.length + 2 >= limit) return too_long_fault~;
		append_http_line_char(line_buffer, c, 0, too_long_fault)!;
	}
}

fn usz skip_http_spaces(String text, usz index) @private
{
	while (index < text.len && text[index] == ' ')
	{
		index++;
	}
	return index;
}

fn void? parse_request_line_parts(String line, String* method, String* target, String* version) @private
{
	sz? first_value = line.index_of_char(' ');
	if (catch err = first_value) return INVALID_REQUEST_LINE~;
	usz first = (usz)first_value;
	if (!first || first + 1 >= line.len) return INVALID_REQUEST_LINE~;
	sz? second_relative = line[first + 1 ..].index_of_char(' ');
	if (catch err = second_relative) return INVALID_REQUEST_LINE~;
	usz second = first + 1 + (usz)second_relative;
	if (second == first + 1 || second + 1 >= line.len) return INVALID_REQUEST_LINE~;
	if (line[second + 1 ..].contains(" ")) return INVALID_REQUEST_LINE~;
	*method = line[:first];
	*target = line[first + 1:second - first - 1];
	*version = line[second + 1 ..];
}

fn void? parse_status_line_parts(String line, String* version, String* status_text, String* reason) @private
{
	// The second SP is required, even when the reason phrase is empty.
	if (line.len < 13 || line[8] != ' ' || line[12] != ' ') return INVALID_STATUS_LINE~;
	*version = line[:8];
	*status_text = line[9:3];
	*reason = line[13 ..];
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
		usz n = (usz)stream.read(buffer[read:buffer.len - read])!;
		if (!n) return io::UNEXPECTED_EOF~;
		read += n;
	}
}

fn void? copy_exact_to_stream(InStream in_stream, OutStream out_stream, usz length) @private
{
	char[4096] buffer = {};
	copy_exact_chunk_to_stream(in_stream, out_stream, buffer[..], length)!;
}

fn void? copy_to_eof(InStream in_stream, OutStream out_stream) @private
{
	char[4096] buffer = {};
	while (true)
	{
		sz? read_value = in_stream.read(buffer[..]);
		if (catch err = read_value)
		{
			if (err == io::EOF) return;
			return err~;
		}
		usz read = (usz)read_value;
		if (!read) return;
		write_exact(out_stream, buffer[:read])!;
	}
}

fn void? read_close_delimited_body(Allocator allocator, InStream stream, String* body, ResourceLimits limits) @private
{
	DString result = dstring::new_with_capacity(allocator, 256);
	defer result.free();
	char[4096] buffer = {};
	while (true)
	{
		sz? read_value = stream.read(buffer[..]);
		if (catch err = read_value)
		{
			if (err == io::EOF) break;
			return err~;
		}
		usz read = (usz)read_value;
		if (!read) break;
		usz accumulated = result.str_view().len;
		if (accumulated > limits.max_buffered_body_size || read > limits.max_buffered_body_size - accumulated) return BUFFERED_BODY_TOO_LARGE~;
		result.append_bytes(buffer[:read]);
	}
	(*body).free(allocator);
	*body = result.copy_str(allocator);
}

fn void? validate_status_and_reason(ushort status, String reason) @private
{
	if (status < 100 || status > 599) return INVALID_STATUS_LINE~;
	foreach (c : reason)
	{
		if (c == '\t' || c == ' ') continue;
		if (c >= 0x21 && c <= 0x7e) continue;
		if (c >= 0x80) continue;
		return INVALID_STATUS_LINE~;
	}
}

fn void? validate_outbound_length(HeaderInfo* info, usz body_length, bool emits_body) @private
{
	if (!info.has_content_length || !emits_body || info.chunked) return;
	if (parse_content_length(info.content_length_text)! != body_length) return INVALID_CONTENT_LENGTH~;
}

fn void? copy_exact_chunk_to_stream(InStream in_stream, OutStream out_stream, char[] buffer, usz length) @private
{
	usz remaining = length;
	while (remaining)
	{
		usz chunk = min((usz)buffer.len, remaining);
		usz read = (usz)in_stream.read(buffer[:chunk])!;
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
