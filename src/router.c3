module c3ttp;

const usz MAX_ROUTES = 64;
const usz MAX_MIDDLEWARES = 16;
const usz MAX_PARAMS = 16;

fn RouteContext* route_context_init_impl(RouteContext* self, Request* req, Response* res, void* handler_context)
{
	self.request = req;
	self.response = res;
	self.handler_context = handler_context;
	self.pattern = "";
	self.param_count = 0;
	self.context_count = 0;
	return self;
}

fn void route_context_free_impl(RouteContext* self)
{
	*self = {};
}

fn void route_context_set_param_impl(RouteContext* self, String name, String value)
{
	if (self.param_count < 16)
	{
		self.params[self.param_count].name = name;
		self.params[self.param_count].value = value;
		self.param_count++;
	}
}

fn String route_context_param_impl(RouteContext* self, String name)
{
	for (usz i = 0; i < self.param_count; i++)
	{
		if (self.params[i].name == name) return self.params[i].value;
	}
	return "";
}

fn void route_context_set_impl(RouteContext* self, String key, void* value)
{
	if (self.context_count >= 8) return;
	for (usz i = 0; i < self.context_count; i++)
	{
		if (self.context_keys[i] == key.ptr)
		{
			self.context_values[i] = value;
			return;
		}
	}
	self.context_keys[self.context_count] = key.ptr;
	self.context_values[self.context_count] = value;
	self.context_count++;
}

fn void* route_context_get_impl(RouteContext* self, String key)
{
	for (usz i = 0; i < self.context_count; i++)
	{
		if (self.context_keys[i] == key.ptr) return self.context_values[i];
	}
	return null;
}

fn Router* router_init_impl(Router* self, Allocator allocator)
{
	self.route_count = 0;
	self.middleware_count = 0;
	return self;
}

fn void router_free_impl(Router* self)
{
	for (usz i = 0; i < self.route_count; i++)
	{
		self.routes[i].method = "";
		self.routes[i].pattern = "";
	}
	self.route_count = 0;
}

fn void router_register_impl(Router* self, String method, String pattern, RouterHandler handler)
{
	if (self.route_count >= MAX_ROUTES) return;
	self.routes[self.route_count].method = method;
	self.routes[self.route_count].pattern = pattern;
	self.routes[self.route_count].path_pattern = pattern;
	self.routes[self.route_count].handler = handler;
	self.routes[self.route_count].has_wildcard = pattern.contains("{*");
	self.route_count++;
}

fn void router_get_impl(Router* self, String pattern, RouterHandler handler)
{
	router_register_impl(self, "GET", pattern, handler);
}

fn void router_post_impl(Router* self, String pattern, RouterHandler handler)
{
	router_register_impl(self, "POST", pattern, handler);
}

fn void router_put_impl(Router* self, String pattern, RouterHandler handler)
{
	router_register_impl(self, "PUT", pattern, handler);
}

fn void router_delete_impl(Router* self, String pattern, RouterHandler handler)
{
	router_register_impl(self, "DELETE", pattern, handler);
}

fn void router_patch_impl(Router* self, String pattern, RouterHandler handler)
{
	router_register_impl(self, "PATCH", pattern, handler);
}

fn void router_head_impl(Router* self, String pattern, RouterHandler handler)
{
	router_register_impl(self, "HEAD", pattern, handler);
}

fn void router_options_impl(Router* self, String pattern, RouterHandler handler)
{
	router_register_impl(self, "OPTIONS", pattern, handler);
}

fn void router_any_impl(Router* self, String pattern, RouterHandler handler)
{
	router_get_impl(self, pattern, handler);
	router_post_impl(self, pattern, handler);
	router_put_impl(self, pattern, handler);
	router_delete_impl(self, pattern, handler);
	router_patch_impl(self, pattern, handler);
	router_head_impl(self, pattern, handler);
	router_options_impl(self, pattern, handler);
}

fn void router_use_impl(Router* self, Middleware middleware)
{
	if (self.middleware_count < MAX_MIDDLEWARES)
	{
		self.middlewares[self.middleware_count] = middleware;
		self.middleware_count++;
	}
}

fn bool match_pattern(String pattern, String path, RouteContext* ctx)
{
	if (pattern == path) return true;
	
	if (pattern == "{*}") return true;
	
	if (pattern.len >= 3 && pattern[0] == '{' && pattern[1] == '*' && pattern[2] == '}')
	{
		route_context_set_param_impl(ctx, "*", path);
		return true;
	}
	
	usz wildcard_idx = pattern.index_of("{*}") ?? pattern.len;
	if (wildcard_idx != pattern.len)
	{
		String prefix = pattern[:wildcard_idx];
		if (!path.starts_with(prefix)) return false;
		String suffix = pattern[wildcard_idx + 3..];
		String remaining = path[prefix.len..];
		if (suffix.len > 0)
		{
			if (!remaining.ends_with(suffix)) return false;
			remaining = remaining[:remaining.len - suffix.len];
		}
		route_context_set_param_impl(ctx, "*", remaining);
		return true;
	}
	
	usz param_start = pattern.index_of_char('{') ?? pattern.len;
	if (param_start == pattern.len) return pattern == path;
	
	String prefix = pattern[:param_start];
	if (!path.starts_with(prefix)) return false;
	
	String remaining_pattern = pattern[param_start..];
	String remaining_path = path[param_start..];
	
	while (remaining_pattern.len > 0 && remaining_path.len > 0)
	{
		if (remaining_pattern.len >= 3 && remaining_pattern[0] == '{' && remaining_pattern[1] == '*' && remaining_pattern[2] == '}')
		{
			route_context_set_param_impl(ctx, "*", remaining_path);
			return true;
		}
		
		if (remaining_pattern.len >= 4 && remaining_pattern[0] == '{' && remaining_pattern[1] == '*')
		{
			usz name_end = remaining_pattern.index_of_char('}') ?? 0;
			if (name_end == 0) return false;
			String wildcard_name = remaining_pattern[2..name_end - 1];
			route_context_set_param_impl(ctx, wildcard_name, remaining_path);
			return true;
		}
		
		if (remaining_pattern.len == 0 || remaining_pattern[0] != '{') return false;
		
		usz close_brace = remaining_pattern.index_of_char('}') ?? 0;
		if (close_brace == 0) return false;
		
		String param_name = remaining_pattern[1..close_brace - 1];
		remaining_pattern = remaining_pattern[close_brace + 1..];
		
		usz seg_end = remaining_path.index_of_char('/') ?? remaining_path.len;
		String param_value = remaining_path[:seg_end];
		route_context_set_param_impl(ctx, param_name, param_value);
		remaining_path = remaining_path[seg_end..];
	}
	
	return remaining_pattern.len == 0 && remaining_path.len == 0;
}

fn Route*? router_find_route(Router* self, String method, String path, RouteContext* ctx)
{
	for (usz i = 0; i < self.route_count; i++)
	{
		Route* route = &self.routes[i];
		if (route.method != method) continue;
		RouteContext temp_ctx = { .pattern = "" };
		if (match_pattern(route.pattern, path, &temp_ctx)) 
		{
			ctx.pattern = route.pattern;
			return route;
		}
	}
	return ROUTE_NOT_FOUND~;
}

fn void? router_route_internal(Router* self, Request* request, Response* response, void* handler_context)
{
	RouteContext ctx;
	route_context_init_impl(&ctx, request, response, handler_context);
	defer route_context_free_impl(&ctx);

	Route*? route = router_find_route(self, request.method, request.target, &ctx);
	if (catch err = route) return err~;
	
	match_pattern(route.pattern, request.target, &ctx);
	
	if (self.middleware_count > 0)
	{
		RouterHandler handler = route.handler;
		for (usz i = self.middleware_count; i > 0; i--)
		{
			Middleware mw = self.middlewares[i - 1];
			handler = mw(handler, &ctx)!;
		}
		handler(request, response, &ctx)!;
	}
	else
	{
		route.handler(request, response, &ctx)!;
	}
}

fn void? router_handler_fn(Request* request, Response* response, void* context)
{
	Router* router = (Router*)context;
	return router_route_internal(router, request, response, context);
}

fn Handler router_as_handler_impl(Router* self)
{
	return (Handler)&router_handler_fn;
}

fn void? router_serve_impl(Router* self, Server* server, uint max_requests, void* context)
{
	Handler h = router_as_handler_impl(self);
	void* ctx = (void*)self;
	return server.serve(h, max_requests, ctx);
}

fn void? router_serve_evented_impl(Router* self, Server* server, uint max_requests, void* context)
{
	Handler h = router_as_handler_impl(self);
	void* ctx = (void*)self;
	return server.serve_evented(h, max_requests, ctx);
}

fn void router_group_impl(Router* self, String prefix, RouterGroupCallback group_cb)
{
	Router sub;
	router_init_impl(&sub, mem);
	group_cb(&sub);
	for (usz i = 0; i < sub.route_count; i++)
	{
		DString combined = dstring::temp_with_capacity(prefix.len + sub.routes[i].pattern.len + 2);
		combined.append_string(prefix);
		if (!prefix.ends_with("/") && !sub.routes[i].pattern.starts_with("/"))
		{
			combined.append_char('/');
		}
		combined.append_string(sub.routes[i].pattern);
		String full_pattern = combined.str_view();
		router_register_impl(self, sub.routes[i].method, full_pattern, sub.routes[i].handler);
	}
	router_free_impl(&sub);
}

fn void response_ok_impl(Response* self, String body)
{
	self.status = 200;
	self.reason.free(self.allocator);
	self.reason = "OK".copy(self.allocator);
	if (body.len > 0) self.set_body(body);
}

fn void response_created_impl(Response* self, String body)
{
	self.status = 201;
	self.reason.free(self.allocator);
	self.reason = "Created".copy(self.allocator);
	if (body.len > 0) self.set_body(body);
}

fn void response_no_content_impl(Response* self)
{
	self.status = 204;
	self.reason.free(self.allocator);
	self.reason = "No Content".copy(self.allocator);
}

fn void response_moved_permanently_impl(Response* self, String location)
{
	self.status = 301;
	self.reason.free(self.allocator);
	self.reason = "Moved Permanently".copy(self.allocator);
	self.set_header("Location", location);
}

fn void response_found_impl(Response* self, String location)
{
	self.status = 302;
	self.reason.free(self.allocator);
	self.reason = "Found".copy(self.allocator);
	self.set_header("Location", location);
}

fn void response_not_modified_impl(Response* self)
{
	self.status = 304;
	self.reason.free(self.allocator);
	self.reason = "Not Modified".copy(self.allocator);
}

fn void response_bad_request_impl(Response* self, String message)
{
	self.status = 400;
	self.reason.free(self.allocator);
	self.reason = "Bad Request".copy(self.allocator);
	if (message.len > 0) self.set_body(message);
}

fn void response_unauthorized_impl(Response* self, String message)
{
	self.status = 401;
	self.reason.free(self.allocator);
	self.reason = "Unauthorized".copy(self.allocator);
	if (message.len > 0) self.set_body(message);
}

fn void response_forbidden_impl(Response* self, String message)
{
	self.status = 403;
	self.reason.free(self.allocator);
	self.reason = "Forbidden".copy(self.allocator);
	if (message.len > 0) self.set_body(message);
}

fn void response_not_found_impl(Response* self, String message)
{
	self.status = 404;
	self.reason.free(self.allocator);
	self.reason = "Not Found".copy(self.allocator);
	if (message.len > 0) self.set_body(message);
}

fn void response_method_not_allowed_impl(Response* self)
{
	self.status = 405;
	self.reason.free(self.allocator);
	self.reason = "Method Not Allowed".copy(self.allocator);
}

fn void response_conflict_impl(Response* self, String message)
{
	self.status = 409;
	self.reason.free(self.allocator);
	self.reason = "Conflict".copy(self.allocator);
	if (message.len > 0) self.set_body(message);
}

fn void response_internal_server_error_impl(Response* self, String message)
{
	self.status = 500;
	self.reason.free(self.allocator);
	self.reason = "Internal Server Error".copy(self.allocator);
	if (message.len > 0) self.set_body(message);
}

fn void response_not_implemented_impl(Response* self, String message)
{
	self.status = 501;
	self.reason.free(self.allocator);
	self.reason = "Not Implemented".copy(self.allocator);
	if (message.len > 0) self.set_body(message);
}