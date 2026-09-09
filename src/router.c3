module c3ttp @private;

macro @route_entry(#entry) @private
{
	$if $Typeof(#entry)::kind == UNTYPEDLIST:
		// Keep the explicit { Method, path, &handler } API available too.
		return #entry;
	$else
		$assert $defined($reflect(#entry).has_tag("c3ttp:route")) : "Pass an annotated function name or { Method, path, &handler }";
		$assert $reflect(#entry).has_tag("c3ttp:route") : "Handler needs @Route({ method, path })";
		RouteConfig $config = $reflect(#entry).get_tag("c3ttp:route");
		return { $config.method, $config.path, &#entry };
	$endif
}

// Bind each function as an expression parameter in its original module.
// Indexing $vaarg directly resolves function names as values in C3 0.8.3;
// forwarding the remaining argument pack preserves the unevaluated names.
macro @collect_routes(#first, ...) @private
{
	var $entry = @route_entry(#first);
	$if $vaarg.len:
		var $rest = @collect_routes(...$vaarg);
		return { $entry, ...$rest };
	$else
		return { $entry };
	$endif
}

fn String request_path_impl(String target) @private @inline
{
	usz end = find_byte((char[])target, 0, '?');
	return target[:end];
}

fn String request_query_impl(String target) @private @inline
{
	usz end = find_byte((char[])target, 0, '?');
	return end < target.len ? target[end + 1..] : "";
}

// Keep exact targets on the shortest path. Query matching only checks the
// known route boundary, so even a long query requires no delimiter scan.
fn bool route_matches_impl(String target, String path) @private @inline
{
	return target == path || (target.len > path.len && target[path.len] == '?' && target[:path.len] == path);
}

macro @route_argument($type, Request* request, Response* response, void* context) @private
{
	$switch $type:
		$case Request*: return request;
		$case Response*: return response;
		$case void*: return context;
		$default: $error "Route parameters must be Request*, Response*, or void* (context)";
	$endswitch
}

macro @invoke_route($handler, Request* request, Response* response, void* context) @private
{
	var $params = $Typeof($handler)::params;
	$switch $params.len:
		$case 0: return $handler();
		$case 1: return $handler(@route_argument($params[0].type, request, response, context));
		$case 2: return $handler(
			@route_argument($params[0].type, request, response, context),
			@route_argument($params[1].type, request, response, context));
		$case 3: return $handler(
			@route_argument($params[0].type, request, response, context),
			@route_argument($params[1].type, request, response, context),
			@route_argument($params[2].type, request, response, context));
		$default: $error "Route handlers accept at most three parameters";
	$endswitch
}

macro void? @dispatch(Request* request, Response* response, void* context, $routes) @private
{
	$for var $i = 0; $i < $routes.len; $i++:
		var $route = $routes[$i];
		$assert $route.len == 3 : "Routes must be { Method, path, &handler }";
		$assert $Typeof($route[0]) == Method : "Route methods must use Method.GET, Method.POST, etc.";
		$assert $Typeof($route[1]) == String : "Route paths must be constant strings";
		$assert $Typeof($route[2])::kind == FUNC : "Route handlers must be constant function pointers";
		$assert $route[1].len > 0 : "Route paths must not be empty";
		$assert $route[1][0] == '/' || $route[1] == "*" : "Route paths must start with / (or be *)";
		$foreach $char : $route[1]:
			$assert $char > 32 && $char != 127 && $char != '?' && $char != '#' : "Route paths cannot contain whitespace, controls, a query, or a fragment";
		$endforeach
		$for var $j = 0; $j < $i; $j++:
			var $previous = $routes[$j];
			$assert $route[0] != $previous[0] || $route[1] != $previous[1] : "Duplicate route method and path";
		$endfor
		var $handler = $route[2];
		var $Return = $Typeof($handler)::returns;
		var $string_optional = $Return == String?;
		var $void_optional = $Return == void?;
		$assert $Return == String || $Return == String? || $Return == void || $Return == void? : "Route handlers must return String, String?, void, or void?";
		if (request.method_id == $route[0] && route_matches_impl(request.target, $route[1]))
		{
			$switch:
				$case $Return == String:
					response.text(@invoke_route($handler, request, response, context));
				$case $string_optional:
					response.text(@invoke_route($handler, request, response, context)!);
				$case $void_optional:
					@invoke_route($handler, request, response, context)!;
				$case $Return == void:
					@invoke_route($handler, request, response, context);
			$endswitch
			return;
		}
	$endfor
	response.text("Not Found", 404);
}
