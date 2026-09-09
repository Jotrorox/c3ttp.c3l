module template_tests;
import c3ttp;
import std::core::test;

fn String? number(RouteParams* params) @Get("/get-number-back/{number}") => params.get("number");
fn String? second(RouteParams* params) @Route({ GET, "/users/{user}/posts/{post}" })
{
	test::eq("alice", params.get("user")!!);
	return params.get("post");
}
fn String literal() => "literal";
fn void all_arguments(Response* response, RouteParams* params, void* context, Request* request)
{
	test::eq("query", request.query());
	test::eq("context", *(String*)context);
	response.text(params.get("value")!!, 201);
}
fn String empty_params(RouteParams* params)
{
	test::eq((usz)0, params.count);
	test::@error(params.get("missing"), c3ttp::ROUTE_PARAM_NOT_FOUND);
	return "empty";
}
fn String? missing(RouteParams* params) => params.get("absent");
fn void? optional_void(RouteParams* params, Response* response) => response.text(params.get("value")!);
fn String eighth(RouteParams* params)
{
	test::eq((usz)8, params.count);
	String[8] names = { "a", "b", "c", "d", "e", "f", "g", "h" };
	String[8] values = { "1", "2", "3", "4", "5", "6", "7", "8" };
	foreach (i, name : names)
	{
		test::eq(name, params.names[i]);
		test::eq(values[i], params.get(name)!!);
	}
	return params.get("h")!!;
}

fn void captures_borrow_raw_segments_and_ignore_queries() @test
{
	Server server = c3ttp::@server(number);
	Request request = { .method_id = GET };
	Response response;
	String[7] values = { "5", "-42", "abc", "%2F", "%3F", "a+b", "0005" };
	String[7] targets = { "/get-number-back/5", "/get-number-back/-42", "/get-number-back/abc", "/get-number-back/%2F", "/get-number-back/%3F", "/get-number-back/a+b", "/get-number-back/0005?other=/x/y" };
	foreach (i, target : targets)
	{
		request.target = target;
		server.handler(&request, &response, null)!!;
		test::eq((ushort)200, response.status);
		test::eq(values[i], response.body);
		test::eq((uptr)(target.ptr + 17), (uptr)response.body.ptr);
	}
	String[9] misses = { "", "/", "/get-number-back", "/get-number-back/", "/get-number-back/?x=5", "/get-number-back/5/", "/get-number-back/5/6", "/Get-number-back/5", "/get-number-backx/5" };
	foreach (target : misses)
	{
		request.target = target;
		server.handler(&request, &response, null)!!;
		test::eq((ushort)404, response.status);
	}
	request.target = "/get-number-back/5";
	request.method_id = POST;
	server.handler(&request, &response, null)!!;
	test::eq((ushort)404, response.status);
}

fn void captures_match_multiple_segments_and_literal_suffixes() @test
{
	Server server = c3ttp::@server({
		c3ttp::@route(second),
		{ Method.GET, "/suffix/{value}/end/", &optional_void },
		{ Method.GET, "/{a}/{b}/{c}/{d}/{e}/{f}/{g}/{h}", &eighth },
	});
	Request request = { .method_id = GET, .target = "/users/alice/posts/42?x=y" };
	Response response;
	server.handler(&request, &response, null)!!;
	test::eq("42", response.body);
	request.target = "/suffix/raw/end/?query";
	server.handler(&request, &response, null)!!;
	test::eq("raw", response.body);
	String[5] misses = { "/users/alice/posts/", "/users/alice//42", "/users/alice/posts/42/more", "/suffix/raw/end", "/suffix/raw?x=/end/" };
	foreach (target : misses)
	{
		request.target = target;
		server.handler(&request, &response, null)!!;
		test::eq((ushort)404, response.status);
	}
	request.target = "/1/2/3/4/5/6/7/8";
	server.handler(&request, &response, null)!!;
	test::eq("8", response.body);
}

fn void overlaps_follow_registration_order_and_failed_matches_do_not_leak() @test
{
	Server first = c3ttp::@server({
		{ Method.GET, "/item/special", &literal },
		{ Method.GET, "/item/{number}", &number },
		{ Method.GET, "/pair/{unused}/bad", &literal },
		{ Method.GET, "/pair/{number}/good", &number },
		{ Method.GET, "/empty", &empty_params },
	});
	Server reverse = c3ttp::@server({
		{ Method.GET, "/item/{number}", &number },
		{ Method.GET, "/item/special", &literal },
	});
	Request request = { .method_id = GET, .target = "/item/special" };
	Response response;
	first.handler(&request, &response, null)!!;
	test::eq("literal", response.body);
	reverse.handler(&request, &response, null)!!;
	test::eq("special", response.body);
	request.target = "/pair/123/good";
	first.handler(&request, &response, null)!!;
	test::eq("123", response.body);
	request.target = "/empty";
	first.handler(&request, &response, null)!!;
	test::eq("empty", response.body);
}

fn void captures_support_all_handler_arguments_and_fault_propagation() @test
{
	Server server = c3ttp::@server({
		{ Method.GET, "/all/{value}", &all_arguments },
		{ Method.GET, "/missing/{value}", &missing },
	});
	String context = "context";
	Request request = { .method_id = GET, .target = "/all/yes?query" };
	Response response;
	server.handler(&request, &response, &context)!!;
	test::eq((ushort)201, response.status);
	test::eq("yes", response.body);
	request.target = "/missing/yes";
	test::@error(server.handler(&request, &response, null), c3ttp::ROUTE_PARAM_NOT_FOUND);
}

// Differential check against a segment-splitting oracle, including empty paths,
// repeated slashes, queries inside candidate matches, and encoded delimiters.
fn void generated_matching_agrees_with_segment_oracle() @test
{
	Server server = c3ttp::@server({
		{ Method.GET, "/a/{number}/tail", &number },
		{ Method.GET, "/{number}", &number },
	});
	String[14] pieces = { "", "/", "a", "/a", "/a/", "/tail", "?", "?x=/tail", "%2F", "x", "//", "/x", "/tail/", "/b/" };
	long state = 17;
	for (usz trial; trial < 10_000; trial++)
	{
		char[256] buffer;
		usz length;
		for (usz i; i < 6; i++)
		{
			state = (state * 48271) % 2147483647;
			foreach (ch : pieces[(usz)state % pieces.len]) buffer[length++] = ch;
		}
		Request request = { .method_id = GET, .target = (String)buffer[:length] };
		Response response;
		String[32] storage;
		String[] segments = request.path().split_to_buffer("/", &storage)!!;
		String expected;
		if (segments.len == 4 && segments[0] == "" && segments[1] == "a" && segments[3] == "tail") expected = segments[2];
		if (segments.len == 2 && segments[0] == "") expected = segments[1];
		server.handler(&request, &response, null)!!;
		test::eq(expected.len ? (ushort)200 : (ushort)404, response.status);
		test::eq(expected.len ? expected : "Not Found", response.body);
	}
}
