module annotation_tests;
import c3ttp;
import annotation_handlers;
import std::core::test;

faultdef ANNOTATED_FAILURE;

fn String hello() @Route({ GET, "/hello" }) => "hello";
fn String echo(Request* request) @Route({ POST, "/hello" }) => request.body;
fn void status(Request* request, Response* response) @Route({ GET, "/status" })
{
	response.set_status(202);
	response.set_body("OK");
}
fn String? fail() @Route({ GET, "/fail" }) => ANNOTATED_FAILURE~;
fn void? contextual(void* context, Response* response) @Route({ GET, "/context" })
{
	if (!context) return ANNOTATED_FAILURE~;
	response.set_body(*(String*)context);
}

fn void annotated_and_explicit_routes_produce_equal_responses() @test
{
	Server annotated = c3ttp::@server(hello, echo, status);
	Server explicit = c3ttp::@server(
		{ Method.GET, "/hello", &hello },
		{ Method.POST, "/hello", &echo },
		{ Method.GET, "/status", &status },
	);
	String[5] targets = { "/hello", "/hello?name=world", "/status", "/hello/", "/missing" };
	Method[3] methods = { GET, POST, HEAD };
	foreach (target : targets)
	{
		foreach (method : methods)
		{
			Request request = { .target = target, .method_id = method, .body = "posted" };
			Response first = { .status = 200, .content_type = "text/plain; charset=utf-8" };
			Response second = first;
			annotated.handler(&request, &first, null)!!;
			explicit.handler(&request, &second, null)!!;
			test::eq(first.status, second.status);
			test::eq(first.body, second.body);
			test::eq(first.content_type, second.content_type);
			test::eq(first.close, second.close);
		}
	}
}

fn void annotated_handlers_work_across_modules_and_with_explicit_entries() @test
{
	Server server = c3ttp::@server(
		hello,
		{ Method.HEAD, "/hello", &hello },
		annotation_handlers::greeting,
		status,
	);
	Request request = { .target = "/imported?x=1", .method_id = GET };
	Response response;
	server.handler(&request, &response, null)!!;
	test::eq("imported", response.body);
	request.target = "/hello";
	request.method_id = HEAD;
	server.handler(&request, &response, null)!!;
	test::eq("hello", response.body);
	request.target = "/status";
	request.method_id = GET;
	server.handler(&request, &response, null)!!;
	test::eq("OK", response.body);
	test::eq((ushort)202, response.status);
}

fn void single_annotated_route_preserves_optional_handler_errors() @test
{
	Server server = c3ttp::@server(fail);
	Request request = { .target = "/fail", .method_id = GET };
	Response response;
	test::@error(server.handler(&request, &response, null), ANNOTATED_FAILURE);
}

fn void annotated_handler_receives_application_context() @test
{
	Server server = c3ttp::@server(contextual);
	Request request = { .target = "/context", .method_id = GET };
	Response response;
	test::@error(server.handler(&request, &response, null), ANNOTATED_FAILURE);
	String body = "context";
	server.context = &body;
	server.handler(&request, &response, server.context)!!;
	test::eq(body, response.body);
	test::eq((uptr)body.ptr, (uptr)response.body.ptr);
}

fn void individual_response_setters_preserve_other_fields() @test
{
	Response response = { .status = 201, .content_type = "application/json", .close = true };
	response.set_body("null");
	test::eq((ushort)201, response.status);
	test::eq("application/json", response.content_type);
	test::eq(true, response.close);
	response.set_status(202);
	test::eq((ushort)202, response.status);
	test::eq("null", response.body);
	test::eq("application/json", response.content_type);
	test::eq(true, response.close);
}
