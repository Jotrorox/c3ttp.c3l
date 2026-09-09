module method_annotation_tests;
import c3ttp;
import std::core::test;

fn String get_handler() @Get("/methods") => "GET";
fn String post_handler() @Post("/methods") => "POST";
fn String put_handler() @Put("/methods") => "PUT";
fn String delete_handler() @Delete("/methods") => "DELETE";
fn String head_handler() @Head("/methods") => "HEAD";
fn String options_handler() @Options("/methods") => "OPTIONS";
fn String patch_handler() @Patch("/methods") => "PATCH";
fn String connect_handler() @Connect("/methods") => "CONNECT";
fn String trace_handler() @Trace("/methods") => "TRACE";
fn String legacy_handler() @Route({ GET, "/legacy" }) => "legacy";
fn String asterisk_handler() @Options("*") => "options";
fn String shared_handler() @Get("/shared") @Post("/shared") @Put("/alternate") => "shared";
fn String mixed_handler() @Route({ PATCH, "/mixed" }) @Delete("/mixed") => "mixed";

fn void all_method_annotations_dispatch_the_correct_handler() @test
{
	Server server = c3ttp::@server(
		get_handler, post_handler, put_handler, delete_handler, head_handler,
		options_handler, patch_handler, connect_handler, trace_handler,
	);
	Method[9] methods = { GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH, CONNECT, TRACE };
	String[9] bodies = { "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "CONNECT", "TRACE" };
	foreach (i, method : methods)
	{
		Request request = { .target = "/methods?raw=query", .method_id = method };
		Response response;
		server.handler(&request, &response, null)!!;
		test::eq(bodies[i], response.body);
		test::eq((ushort)200, response.status);
	}
	Request request = { .target = "/methods", .method_id = OTHER };
	Response response;
	server.handler(&request, &response, null)!!;
	test::eq((ushort)404, response.status);
}

fn void method_annotations_mix_with_legacy_annotations_and_explicit_routes() @test
{
	Server server = c3ttp::@server(
		get_handler,
		legacy_handler,
		{ Method.POST, "/legacy", &legacy_handler },
		asterisk_handler,
	);
	Request request = { .target = "/legacy", .method_id = GET };
	Response response;
	server.handler(&request, &response, null)!!;
	test::eq("legacy", response.body);
	request.method_id = POST;
	server.handler(&request, &response, null)!!;
	test::eq("legacy", response.body);
	request.target = "*";
	request.method_id = OPTIONS;
	server.handler(&request, &response, null)!!;
	test::eq("options", response.body);
	request.target = "/unregistered";
	server.handler(&request, &response, null)!!;
	test::eq((ushort)404, response.status);
}

fn void stacked_method_annotations_register_every_route() @test
{
	Server server = c3ttp::@server(shared_handler, mixed_handler);
	Method[5] methods = { GET, POST, PUT, PATCH, DELETE };
	String[5] paths = { "/shared", "/shared", "/alternate", "/mixed", "/mixed" };
	foreach (i, method : methods)
	{
		Request request = { .target = paths[i], .method_id = method };
		Response response;
		server.handler(&request, &response, null)!!;
		test::eq((ushort)200, response.status);
		test::eq(i < 3 ? "shared" : "mixed", response.body);
	}
	Request request = { .target = "/shared", .method_id = PUT };
	Response response;
	server.handler(&request, &response, null)!!;
	test::eq((ushort)404, response.status);
}
