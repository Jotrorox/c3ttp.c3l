// A consumer module exercises the public API, including macro visibility.
module router_tests;
import c3ttp;
import std::core::test;

faultdef HANDLER_FAILED;

fn String hello() => "hello";
fn String echo(Request* request) => request.body;
fn void status(Response* response) => response.json("{\"ok\":true}", 201);
fn String? fallible(Request* request)
{
	if (request.query() == "fail") return HANDLER_FAILED~;
	return "success";
}
fn void? with_context(Response* response, void* context, Request* request)
{
	if (!context) return HANDLER_FAILED~;
	response.text(*(String*)context, 202);
}
fn void? legacy(RequestView* request, ResponseView* response, void* context)
{
	response.ok("legacy");
}

fn void routes_match_method_and_path_without_query() @test
{
	Server server = c3ttp::@server(
		{ Method.GET, "/hello", &hello },
		{ Method.POST, "/hello", &echo },
		{ Method.GET, "/status", &status },
	);
	Request request = { .method_id = GET, .target = "/hello?name=world" };
	Response response;
	server.handler(&request, &response, server.context)!!;
	test::eq("hello", response.body);
	test::eq((ushort)200, response.status);
	test::eq("text/plain; charset=utf-8", response.content_type);
	request.method_id = POST;
	request.body = "posted";
	server.handler(&request, &response, null)!!;
	test::eq("posted", response.body);
	request.method_id = GET;
	request.target = "/status";
	server.handler(&request, &response, null)!!;
	test::eq((ushort)201, response.status);
	test::eq("application/json", response.content_type);
	test::eq("{\"ok\":true}", response.body);
}

fn void routes_are_exact_and_missing_routes_return_404() @test
{
	Server server = c3ttp::@server({ Method.GET, "/hello", &hello });
	Request request = { .method_id = GET };
	Response response;
	String[5] targets = { "/Hello", "/hello/", "/hell", "/hello/world", "/missing" };
	foreach (target : targets)
	{
		request.target = target;
		server.handler(&request, &response, null)!!;
		test::eq((ushort)404, response.status);
		test::eq("Not Found", response.body);
	}
	request.target = "/hello";
	request.method_id = HEAD;
	server.handler(&request, &response, null)!!;
	test::eq((ushort)404, response.status);
}

fn void routes_propagate_faults_and_borrow_context() @test
{
	Server server = c3ttp::@server(
		{ Method.GET, "/fallible", &fallible },
		{ Method.GET, "/context", &with_context },
		{ Method.GET, "/legacy", &legacy },
	);
	Request request = { .method_id = GET, .target = "/fallible" };
	Response response;
	server.handler(&request, &response, null)!!;
	test::eq("success", response.body);
	request.target = "/fallible?fail";
	test::@error(server.handler(&request, &response, null), HANDLER_FAILED);
	request.target = "/context";
	test::@error(server.handler(&request, &response, null), HANDLER_FAILED);
	String message = "context";
	server.context = &message;
	server.handler(&request, &response, server.context)!!;
	test::eq("context", response.body);
	test::eq((ushort)202, response.status);
	request.target = "/legacy";
	server.handler(&request, &response, server.context)!!;
	test::eq("legacy", response.body);
}

fn void request_target_helpers_are_zero_copy() @test
{
	String target = "/hello?name=world?raw";
	Request request = { .target = target };
	test::eq("/hello", request.path());
	test::eq("name=world?raw", request.query());
	test::eq((uptr)target.ptr, (uptr)request.path().ptr);
	test::eq((uptr)(target.ptr + 7), (uptr)request.query().ptr);
	request.target = "/hello";
	test::eq("/hello", request.path());
	test::eq("", request.query());
	request.target = "/?";
	test::eq("/", request.path());
	test::eq("", request.query());
	request.target = "";
	test::eq("", request.path());
	test::eq("", request.query());
}

fn void response_helpers_preserve_connection_policy() @test
{
	Response response = { .close = true };
	response.text("created", 201);
	test::eq(true, response.close);
	response.json("null");
	test::eq(true, response.close);
	test::eq((ushort)200, response.status);
	test::eq("null", response.body);
	response.set(404, "missing");
	test::eq((ushort)404, response.status);
	response.ok();
	test::eq((ushort)200, response.status);
}
