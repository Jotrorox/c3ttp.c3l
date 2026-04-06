module c3ttp @private;

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

fn void? validate_trailers(HeaderList* trailers, bool allow_trailers) @private
{
	if (!allow_trailers && trailers.len() > 0) return INVALID_TRAILER~;
	foreach (header : *trailers)
	{
		if (header_name_eq(header.name, "Transfer-Encoding")) return INVALID_TRAILER~;
		if (header_name_eq(header.name, "Content-Length")) return INVALID_TRAILER~;
		if (header_name_eq(header.name, "Host")) return INVALID_TRAILER~;
		if (header_name_eq(header.name, "Connection")) return INVALID_TRAILER~;
		if (header_name_eq(header.name, "Trailer")) return INVALID_TRAILER~;
	}
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
	if (te.trim().to_lower_tcopy() == "chunked") return true;
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
