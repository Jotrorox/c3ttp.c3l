module c3ttp @private;

import std::core::mem;
import std::math::vector;
import std::bits;

const usz SIMD_WIDTH = 32;

fn Limits default_limits_impl() @private
{
	return {
		.max_request_line = 8192,
		.max_header_line = 8192,
		.max_header_bytes = 16384,
		.max_body_bytes = 1048576,
		.max_headers = MAX_VIEW_HEADERS,
	};
}

fn RequestParser* request_parser_init_impl(RequestParser* self, Limits limits) @private
{
	self.limits = limits;
	request_parser_reset_impl(self);
	return self;
}

fn void request_parser_reset_impl(RequestParser* self) @private
{
	Limits limits = self.limits;
	*self = { .limits = limits, .state = REQUEST_LINE };
}

// C3 0.8 vectors lower this loop to the selected target's SIMD width. The
// unaligned load is safe because it is only issued when 32 bytes remain.
fn usz find_byte(char[] input, usz start, char needle) @private @inline
{
	usz cursor = start;
	while (cursor + SIMD_WIDTH <= input.len)
	{
		char[<32>] block = mem::load((char[<32>]*)(input.ptr + cursor), 1);
		usz mask = (usz)block.comp_eq((char[<32>])needle).mask_to_int();
		if (@likely(mask != 0, 0.8)) return cursor + (usz)mask.ctz();
		cursor += SIMD_WIDTH;
	}
	while (cursor < input.len)
	{
		if (input[cursor] == needle) return cursor;
		cursor++;
	}
	return input.len;
}

fn bool ascii_ieq(String left, String right) @private @inline
{
	if (left.len != right.len) return false;
	foreach (i, char c : left)
	{
		char other = right[i];
		if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
		if (other >= 'A' && other <= 'Z') other += 'a' - 'A';
		if (c != other) return false;
	}
	return true;
}

fn bool is_token_char(char c) @private @inline
{
	if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return true;
	return c == '!' || c == '#' || c == '$' || c == '%' || c == '&' || c == '\'' ||
		c == '*' || c == '+' || c == '-' || c == '.' || c == '^' || c == '_' ||
		c == '`' || c == '|' || c == '~';
}

fn bool valid_header_value(String value) @private @inline
{
	usz cursor;
	while (cursor + SIMD_WIDTH <= value.len)
	{
		char[<32>] block = mem::load((char[<32>]*)(value.ptr + cursor), 1);
		usz controls = (usz)block.comp_lt((char[<32>])0x20).mask_to_int();
		usz tabs = (usz)block.comp_eq((char[<32>])'\t').mask_to_int();
		usz deletes = (usz)block.comp_eq((char[<32>])0x7f).mask_to_int();
		if (@unlikely((controls & ~tabs) | deletes != 0)) return false;
		cursor += SIMD_WIDTH;
	}
	while (cursor < value.len)
	{
		char c = value[cursor++];
		if (c != '\t' && (c < 0x20 || c == 0x7f)) return false;
	}
	return true;
}

fn Method classify_method(String method) @private @inline
{
	switch (method.len)
	{
		case 3:
			if (method == "GET") return GET;
			if (method == "PUT") return PUT;
		case 4:
			if (method == "POST") return POST;
			if (method == "HEAD") return HEAD;
		case 5:
			if (method == "PATCH") return PATCH;
			if (method == "TRACE") return TRACE;
		case 6:
			if (method == "DELETE") return DELETE;
		case 7:
			if (method == "OPTIONS") return OPTIONS;
			if (method == "CONNECT") return CONNECT;
		default:
	}
	return OTHER;
}

fn HeaderId classify_header(String name) @private @inline
{
	switch (name.len)
	{
		case 4: if (ascii_ieq(name, "Host")) return HOST;
		case 6:
			if (ascii_ieq(name, "Accept")) return ACCEPT;
			if (ascii_ieq(name, "Cookie")) return COOKIE;
		case 10:
			if (ascii_ieq(name, "Connection")) return CONNECTION;
			if (ascii_ieq(name, "User-Agent")) return USER_AGENT;
		case 12: if (ascii_ieq(name, "Content-Type")) return CONTENT_TYPE;
		case 13: if (ascii_ieq(name, "Authorization")) return AUTHORIZATION;
		case 14: if (ascii_ieq(name, "Content-Length")) return CONTENT_LENGTH;
		case 17: if (ascii_ieq(name, "Transfer-Encoding")) return TRANSFER_ENCODING;
		default:
	}
	return UNKNOWN;
}

fn bool contains_token(String value, String wanted) @private
{
	usz start;
	while (start < value.len)
	{
		while (start < value.len && (value[start] == ' ' || value[start] == '\t' || value[start] == ',')) start++;
		usz end = start;
		while (end < value.len && value[end] != ',') end++;
		usz trimmed = end;
		while (trimmed > start && (value[trimmed - 1] == ' ' || value[trimmed - 1] == '\t')) trimmed--;
		if (ascii_ieq(value[start:trimmed - start], wanted)) return true;
		start = end + 1;
	}
	return false;
}

fn usz? parse_decimal(String value) @private
{
	if (!value.len) return INVALID_CONTENT_LENGTH~;
	// Content lengths are usually short. Keep the common one- and two-digit
	// cases branch-light and let the general overflow-checked loop handle the
	// uncommon values.
	if (value.len == 1)
	{
		char a = value[0];
		if (a < '0' || a > '9') return INVALID_CONTENT_LENGTH~;
		return (usz)(a - '0');
	}
	if (value.len == 2)
	{
		char a = value[0];
		char b = value[1];
		if (a < '0' || a > '9' || b < '0' || b > '9') return INVALID_CONTENT_LENGTH~;
		return (usz)(a - '0') * 10 + (usz)(b - '0');
	}
	usz result;
	foreach (char c : value)
	{
		if (c < '0' || c > '9') return INVALID_CONTENT_LENGTH~;
		usz digit = (usz)(c - '0');
		if (result > ((usz)~0 - digit) / 10) return INVALID_CONTENT_LENGTH~;
		result = result * 10 + digit;
	}
	return result;
}

fn usz? parse_hex(String value) @private
{
	if (!value.len) return INVALID_HEADER~;
	usz result;
	foreach (char c : value)
	{
		usz digit;
		if (c >= '0' && c <= '9')
		{
			digit = (usz)(c - '0');
		}
		else if (c >= 'a' && c <= 'f')
		{
			digit = (usz)(c - 'a' + 10);
		}
		else if (c >= 'A' && c <= 'F')
		{
			digit = (usz)(c - 'A' + 10);
		}
		else
		{
			return INVALID_HEADER~;
		}
		if (result > ((usz)~0 - digit) / 16) return BODY_TOO_LARGE~;
		result = result * 16 + digit;
	}
	return result;
}

fn void? parse_request_line_view(RequestParser* self, char[] input, usz line_end) @private
{
	if (line_end > self.limits.max_request_line) return REQUEST_LINE_TOO_LARGE~;
	usz first = find_byte(input[:line_end], 0, ' ');
	if (!first || first == line_end) return INVALID_REQUEST_LINE~;
	usz second = find_byte(input[:line_end], first + 1, ' ');
	if (second == line_end || second == first + 1) return INVALID_REQUEST_LINE~;
	if (find_byte(input[:line_end], second + 1, ' ') != line_end) return INVALID_REQUEST_LINE~;

	String method = (String)input[:first];
	foreach (char c : method) if (!is_token_char(c)) return INVALID_METHOD~;
	String target = (String)input[first + 1:second - first - 1];
	if (!target.len) return INVALID_TARGET~;
	foreach (char c : target) if (c <= ' ' || c == 0x7f) return INVALID_TARGET~;
	String version = (String)input[second + 1:line_end - second - 1];
	if (version != "HTTP/1.1") return INVALID_VERSION~;

	self.request.method = method;
	self.request.target = target;
	self.request.version = version;
	self.request.method_id = classify_method(method);
}

fn void? parse_header_view(RequestParser* self, char[] input, usz start, usz end) @private
{
	if (end - start > self.limits.max_header_line) return HEADER_LINE_TOO_LARGE~;
	usz colon = find_byte(input[:end], start, ':');
	if (colon == end || colon == start) return INVALID_HEADER~;
	String name = (String)input[start:colon - start];
	foreach (char c : name) if (!is_token_char(c)) return INVALID_HEADER~;

	usz value_start = colon + 1;
	while (value_start < end && (input[value_start] == ' ' || input[value_start] == '\t')) value_start++;
	usz value_end = end;
	while (value_end > value_start && (input[value_end - 1] == ' ' || input[value_end - 1] == '\t')) value_end--;
	String value = (String)input[value_start:value_end - value_start];
	if (!valid_header_value(value)) return INVALID_HEADER~;

	if (self.request.header_count >= self.limits.max_headers || self.request.header_count >= MAX_VIEW_HEADERS)
	{
		return TOO_MANY_HEADERS~;
	}
	HeaderId id = classify_header(name);
	self.request.header_storage[self.request.header_count++] = { .name = name, .value = value, .id = id };

	switch (id)
	{
		case HOST:
			if (self.saw_host) return DUPLICATE_HEADER~;
			if (!value.len) return INVALID_HEADER~;
			self.saw_host = true;
		case CONTENT_LENGTH:
			if (self.request.has_content_length) return DUPLICATE_HEADER~;
			self.request.content_length = parse_decimal(value)!;
			self.request.has_content_length = true;
			if (self.request.content_length > self.limits.max_body_bytes) return BODY_TOO_LARGE~;
		case TRANSFER_ENCODING:
			if (self.saw_transfer_encoding) return DUPLICATE_HEADER~;
			self.saw_transfer_encoding = true;
			if (!ascii_ieq(value, "chunked")) return UNSUPPORTED_TRANSFER_ENCODING~;
			self.request.chunked = true;
		case CONNECTION:
			if (contains_token(value, "close")) self.request.keep_alive = false;
		default:
	}
}

fn ParseStatus? request_parser_parse_impl(RequestParser* self, char[] input) @private
{
	// Parsed fields are views into the caller's storage. Incremental calls must
	// therefore extend the same allocation rather than replace or shrink it.
	if (self.observed_length)
	{
		if ((uptr)input.ptr != self.buffer_address || input.len < self.observed_length)
		{
			return INVALID_INPUT_BUFFER~;
		}
	}
	else if (input.len)
	{
		self.buffer_address = (uptr)input.ptr;
	}
	self.observed_length = input.len;
	if (self.state == COMPLETE) return COMPLETE;
	if (self.state == REQUEST_LINE)
	{
		usz lf = find_byte(input, self.cursor, '\n');
		if (lf == input.len)
		{
			if (input.len > self.limits.max_request_line + 1) return REQUEST_LINE_TOO_LARGE~;
			self.cursor = input.len > 0 ? input.len - 1 : 0;
			return NEED_MORE;
		}
		if (!lf || input[lf - 1] != '\r') return INVALID_REQUEST_LINE~;
		parse_request_line_view(self, input, lf - 1)!;
		self.cursor = lf + 1;
		self.line_start = self.cursor;
		self.request.keep_alive = true;
		self.state = HEADERS;
	}

	while (self.state == HEADERS)
	{
		usz lf = find_byte(input, self.cursor, '\n');
		if (lf == input.len)
		{
			if (input.len - self.line_start > self.limits.max_header_line + 1) return HEADER_LINE_TOO_LARGE~;
			if (input.len > self.limits.max_header_bytes + self.limits.max_request_line) return HEADERS_TOO_LARGE~;
			self.cursor = input.len > self.line_start ? input.len - 1 : self.line_start;
			return NEED_MORE;
		}
		if (lf == self.line_start || input[lf - 1] != '\r') return INVALID_HEADER~;
		usz line_end = lf - 1;
		self.header_bytes += lf + 1 - self.line_start;
		if (self.header_bytes > self.limits.max_header_bytes) return HEADERS_TOO_LARGE~;
		if (line_end == self.line_start)
		{
			if (!self.saw_host) return MISSING_HOST~;
			if (self.saw_transfer_encoding && self.request.has_content_length) return CONFLICTING_BODY_HEADERS~;
			self.cursor = lf + 1;
			self.line_start = self.cursor;
			if (self.request.chunked)
			{
				self.state = CHUNK_SIZE;
				break;
			}
			if (self.request.content_length)
			{
				self.state = BODY_FIXED;
				break;
			}
			self.request.body = (String)input[self.cursor:0];
			self.request.message_length = self.cursor;
			self.state = COMPLETE;
			return COMPLETE;
		}
		parse_header_view(self, input, self.line_start, line_end)!;
		self.cursor = lf + 1;
		self.line_start = self.cursor;
	}

	if (self.state == BODY_FIXED)
	{
		if (input.len - self.line_start < self.request.content_length) return NEED_MORE;
		usz end = self.line_start + self.request.content_length;
		self.request.body = (String)input[self.line_start:end - self.line_start];
		self.request.body_length = self.request.content_length;
		self.request.message_length = end;
		self.cursor = end;
		self.state = COMPLETE;
		return COMPLETE;
	}

	while (self.state == CHUNK_SIZE || self.state == CHUNK_DATA || self.state == TRAILERS)
	{
		if (self.state == CHUNK_SIZE)
		{
			usz lf = find_byte(input, self.cursor, '\n');
			if (lf == input.len)
			{
				if (input.len - self.cursor > self.limits.max_header_line + 1) return HEADER_LINE_TOO_LARGE~;
				return NEED_MORE;
			}
			if (lf == self.cursor || input[lf - 1] != '\r') return INVALID_HEADER~;
			usz size_end = lf - 1;
			if (size_end - self.cursor > self.limits.max_header_line) return HEADER_LINE_TOO_LARGE~;
			usz semicolon = find_byte(input[:size_end], self.cursor, ';');
			String size_text = (String)input[self.cursor:semicolon - self.cursor];
			self.chunk_remaining = parse_hex(size_text)!;
			if (semicolon < size_end)
			{
				String extension = (String)input[semicolon + 1:size_end - semicolon - 1];
				if (!valid_header_value(extension)) return INVALID_HEADER~;
			}
			if (self.chunk_remaining > self.limits.max_body_bytes - self.request.body_length) return BODY_TOO_LARGE~;
			self.cursor = lf + 1;
			self.line_start = self.cursor;
			if (!self.chunk_remaining)
			{
				self.state = TRAILERS;
				continue;
			}
			if (self.request.chunk_count >= MAX_BODY_CHUNKS) return BODY_TOO_LARGE~;
			self.state = CHUNK_DATA;
		}
		if (self.state == CHUNK_DATA)
		{
			if (input.len - self.cursor < self.chunk_remaining + 2) return NEED_MORE;
			usz end = self.cursor + self.chunk_remaining;
			if (input[end] != '\r' || input[end + 1] != '\n') return INVALID_HEADER~;
			self.request.chunk_storage[self.request.chunk_count++] = (String)input[self.cursor:end - self.cursor];
			self.request.body_length += self.chunk_remaining;
			self.cursor = end + 2;
			self.line_start = self.cursor;
			self.state = CHUNK_SIZE;
			continue;
		}
		if (self.state == TRAILERS)
		{
			usz lf = find_byte(input, self.cursor, '\n');
			if (lf == input.len)
			{
				if (input.len - self.cursor > self.limits.max_header_line + 1) return HEADER_LINE_TOO_LARGE~;
				return NEED_MORE;
			}
			if (lf == self.cursor || input[lf - 1] != '\r') return INVALID_HEADER~;
			usz line_end = lf - 1;
			self.header_bytes += lf + 1 - self.cursor;
			if (line_end - self.cursor > self.limits.max_header_line) return HEADER_LINE_TOO_LARGE~;
			if (self.header_bytes > self.limits.max_header_bytes) return HEADERS_TOO_LARGE~;
			if (line_end == self.cursor)
			{
				self.cursor = lf + 1;
				self.request.message_length = self.cursor;
				self.state = COMPLETE;
				return COMPLETE;
			}
			// Validate trailer syntax without adding it to the regular header set.
			usz colon = find_byte(input[:line_end], self.cursor, ':');
			if (colon == line_end || colon == self.cursor) return INVALID_HEADER~;
			String trailer_name = (String)input[self.cursor:colon - self.cursor];
			foreach (char c : trailer_name) if (!is_token_char(c)) return INVALID_HEADER~;
			HeaderId trailer_id = classify_header(trailer_name);
			if (trailer_id == CONTENT_LENGTH || trailer_id == TRANSFER_ENCODING || trailer_id == HOST || trailer_id == CONNECTION)
			{
				return INVALID_HEADER~;
			}
			String trailer_value = (String)input[colon + 1:line_end - colon - 1];
			if (!valid_header_value(trailer_value)) return INVALID_HEADER~;
			self.cursor = lf + 1;
			self.line_start = self.cursor;
		}
	}
	return NEED_MORE;
}

fn String? request_view_header_impl(RequestView* self, HeaderId id) @private
{
	foreach (HeaderView header : self.header_storage[:self.header_count])
		if (header.id == id) return header.value;
	return INVALID_HEADER~;
}

fn String? request_view_header_name_impl(RequestView* self, String name) @private
{
	foreach (HeaderView header : self.header_storage[:self.header_count])
		if (ascii_ieq(header.name, name)) return header.value;
	return INVALID_HEADER~;
}
