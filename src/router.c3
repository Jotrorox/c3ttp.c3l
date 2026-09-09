module c3ttp @private;

macro @route_entries(#entry) @private
{
	$if $Typeof(#entry)::kind == UNTYPEDLIST:
		// A route inventory is a flat list of normalized triples. Passing it
		// as one argument avoids recursive collection per handler.
		$assert #entry.len > 0 : "Route inventories must contain at least one route";
		$if $Typeof(#entry[0])::kind == UNTYPEDLIST:
			return #entry;
		$endif
		return { #entry };
	$else
		$assert $defined($reflect(#entry).has_tag("c3ttp:route")) : "Pass an annotated function name or { Method, path, &handler }";
		var $entries = {};
		$if $reflect(#entry).has_tag("c3ttp:route"):
			RouteConfig $config = $reflect(#entry).get_tag("c3ttp:route");
			$entries = { { $config.method, $config.path, &#entry } };
		$endif
		var $methods = {
			{ "c3ttp:route:get", Method.GET },
			{ "c3ttp:route:post", Method.POST },
			{ "c3ttp:route:put", Method.PUT },
			{ "c3ttp:route:delete", Method.DELETE },
			{ "c3ttp:route:head", Method.HEAD },
			{ "c3ttp:route:options", Method.OPTIONS },
			{ "c3ttp:route:patch", Method.PATCH },
			{ "c3ttp:route:connect", Method.CONNECT },
			{ "c3ttp:route:trace", Method.TRACE },
		};
		$foreach $method : $methods:
			$if $reflect(#entry).has_tag($method[0]):
				var $route = { $method[1], $reflect(#entry).get_tag($method[0]), &#entry };
				$if $entries.len:
					$entries = { ...$entries, $route };
				$else
					$entries = { $route };
				$endif
			$endif
		$endforeach
		$assert $entries.len > 0 : "Handler needs a route annotation such as @Get(path) or @Route({ method, path })";
		return $entries;
	$endif
}

// Bind each function as an expression parameter in its original module.
// Indexing $vaarg directly resolves function names as values in C3 0.8.3;
// forwarding the remaining argument pack preserves the unevaluated names.
macro @collect_routes(#first, ...) @private
{
	var $entries = @route_entries(#first);
	$if $vaarg.len:
		var $rest = @collect_routes(...$vaarg);
		return { ...$entries, ...$rest };
	$else
		return $entries;
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

// Compile templates into alternating literal runs and whole-segment captures.
// Literal-only registrations keep the existing exact-target matcher.
macro @template_parts($path) @private
{
	var $parts = {};
	var $names = {};
	var $literal = 0;
	var $open = -1;
	$foreach $i, $char : $path:
		$if $char == '{':
			$assert $open < 0 : "Nested { in route template";
			$assert $i > 0 : "Route parameters must occupy a whole path segment";
			$assert $path[$i - 1] == '/' : "Route parameters must occupy a whole path segment";
			$open = $i;
		$endif
		$if $char == '}':
			$assert $open >= 0 : "Unmatched } in route template";
			$if $i + 1 < $path.len:
				$assert $path[$i + 1] == '/' : "Route parameters must occupy a whole path segment";
			$endif
			var $name = $path[$open + 1:$i - $open - 1];
			$assert $name.len > 0 : "Route parameter names must not be empty";
			$foreach $j, $letter : $name:
				$assert ($letter >= 'a' && $letter <= 'z') || ($letter >= 'A' && $letter <= 'Z') || $letter == '_' || ($j > 0 && $letter >= '0' && $letter <= '9') : "Route parameter names must be identifiers";
			$endforeach
			$foreach $previous : $names:
				$assert $name != $previous : "Duplicate route parameter name";
			$endforeach
			$assert $names.len < MAX_ROUTE_PARAMS : "Too many route parameters (maximum eight)";
			$if $names.len:
				$names = { ...$names, $name };
				$parts = { ...$parts, { false, $path[$literal:$open - $literal] }, { true, $name } };
			$else
				$names = { $name };
				$parts = { { false, $path[$literal:$open - $literal] }, { true, $name } };
			$endif
			$literal = $i + 1;
			$open = -1;
		$endif
	$endforeach
	$assert $open < 0 : "Unclosed { in route template";
	$if $literal < $path.len:
		$if $parts.len:
			$parts = { ...$parts, { false, $path[$literal..] } };
		$else
			$parts = { { false, $path } };
		$endif
	$endif
	return $parts;
}

// Equal literal runs and capture positions are ambiguous even if names differ.
macro bool @same_template_shape($left, $right) @private
{
	var $same = false;
	$if $left.len == $right.len:
		$same = true;
		$foreach $i, $part : $left:
			$if $part[0] != $right[$i][0]: $same = false; $endif
			$if !$part[0] && $part[1] != $right[$i][1]: $same = false; $endif
		$endforeach
	$endif
	return $same;
}

fn String? route_param_get_impl(RouteParams* params, String name) @private @inline
{
	for (usz i; i < params.count; i++)
	{
		if (params.names[i] == name) return params.values[i];
	}
	return ROUTE_PARAM_NOT_FOUND~;
}

macro bool @match_template(String target, RouteParams* params, $parts) @private
{
	usz cursor;
	usz start;
	var $capture = 0;
	$foreach $part : $parts:
		$if $part[0]:
			start = cursor;
			while (cursor < target.len && target[cursor] != '/' && target[cursor] != '?') cursor++;
			if (cursor == start) return false;
			params.names[$capture] = $part[1];
			params.values[$capture] = target[start:cursor - start];
			$capture++;
		$else
			if (target.len - cursor < $part[1].len || target[cursor:$part[1].len] != $part[1]) return false;
			cursor += $part[1].len;
		$endif
	$endforeach
	params.count = $capture;
	return cursor == target.len || target[cursor] == '?';
}

macro @route_argument($type, Request* request, Response* response, void* context, RouteParams* params) @private
{
	$switch $type:
		$case Request*: return request;
		$case Response*: return response;
		$case void*: return context;
		$case RouteParams*: return params;
		$default: $error "Route parameters must be Request*, Response*, void* (context), or RouteParams*";
	$endswitch
}

macro @invoke_route($handler, Request* request, Response* response, void* context, RouteParams* captures) @private
{
	var $params = $Typeof($handler)::params;
	$switch $params.len:
		$case 0: return $handler();
		$case 1: return $handler(@route_argument($params[0].type, request, response, context, captures));
		$case 2: return $handler(
			@route_argument($params[0].type, request, response, context, captures),
			@route_argument($params[1].type, request, response, context, captures));
		$case 3: return $handler(
			@route_argument($params[0].type, request, response, context, captures),
			@route_argument($params[1].type, request, response, context, captures),
			@route_argument($params[2].type, request, response, context, captures));
		$case 4: return $handler(
			@route_argument($params[0].type, request, response, context, captures),
			@route_argument($params[1].type, request, response, context, captures),
			@route_argument($params[2].type, request, response, context, captures),
			@route_argument($params[3].type, request, response, context, captures));
		$default: $error "Route handlers accept at most four parameters";
	$endswitch
}

macro void? @dispatch(Request* request, Response* response, void* context, $routes) @private
{
	var $templates = {};
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
		var $parts = @template_parts($route[1]);
		var $templated = $parts.len > 1;
		$if $templates.len:
			$templates = { ...$templates, $parts };
		$else
			$templates = { $parts };
		$endif
		$for var $j = 0; $j < $i; $j++:
			var $previous = $routes[$j];
			$assert $route[0] != $previous[0] || $route[1] != $previous[1] : "Duplicate route method and path";
			$if $templated && $route[0] == $previous[0]:
				$assert !@same_template_shape($parts, $templates[$j]) : "Duplicate route template shape";
			$endif
		$endfor
		var $handler = $route[2];
		var $Return = $Typeof($handler)::returns;
		var $string_optional = $Return == String?;
		var $void_optional = $Return == void?;
		$assert $Return == String || $Return == String? || $Return == void || $Return == void? : "Route handlers must return String, String?, void, or void?";
		{
			RouteParams* captures = null;
			$if $templated:
				// The matcher initializes every slot below count before invoking
				// the handler. Unused slots are never read by the public getter.
				RouteParams storage @noinit;
				captures = &storage;
				bool matches = request.method_id == $route[0] && @match_template(request.target, captures, $parts);
			$else
				// Supply an empty container only if a literal-route handler requests it.
				var $needs_params = false;
				$foreach $param : $Typeof($handler)::params:
					$if $param.type == RouteParams*:
						$needs_params = true;
					$endif
				$endforeach
				$if $needs_params:
					RouteParams empty;
					captures = &empty;
				$endif
				bool matches = request.method_id == $route[0] && route_matches_impl(request.target, $route[1]);
			$endif
			if (matches)
			{
				$switch:
					$case $Return == String:
						response.text(@invoke_route($handler, request, response, context, captures));
					$case $string_optional:
						response.text(@invoke_route($handler, request, response, context, captures)!);
					$case $void_optional:
						@invoke_route($handler, request, response, context, captures)!;
					$case $Return == void:
						@invoke_route($handler, request, response, context, captures);
				$endswitch
				return;
			}
		}
	$endfor
	response.text("Not Found", 404);
}
