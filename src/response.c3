module c3ttp @private;

fn void response_view_set_impl(ResponseView* self, ushort status, String body, String content_type) @private
{
	self.status = status;
	self.body = body;
	self.content_type = content_type;
}

fn String reason_phrase(ushort status) @private @inline
{
	switch (status)
	{
		case 100: return "Continue";
		case 101: return "Switching Protocols";
		case 200: return "OK";
		case 201: return "Created";
		case 202: return "Accepted";
		case 204: return "No Content";
		case 301: return "Moved Permanently";
		case 302: return "Found";
		case 304: return "Not Modified";
		case 400: return "Bad Request";
		case 401: return "Unauthorized";
		case 403: return "Forbidden";
		case 404: return "Not Found";
		case 405: return "Method Not Allowed";
		case 408: return "Request Timeout";
		case 409: return "Conflict";
		case 413: return "Content Too Large";
		case 414: return "URI Too Long";
		case 431: return "Request Header Fields Too Large";
		case 500: return "Internal Server Error";
		case 501: return "Not Implemented";
		case 503: return "Service Unavailable";
		default: return "Unknown";
	}
}

fn bool response_has_body(ushort status, Method method) @private @inline
{
	if (method == HEAD) return false;
	if (status >= 100 && status < 200) return false;
	return status != 204 && status != 304;
}
