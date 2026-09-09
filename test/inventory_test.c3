module inventory_tests;
import c3ttp;
import inventory_handlers;
import std::core::test;

fn String hello() @Route({ GET, "/hello" }) => "hello";
fn String explicit_only() => "explicit";

fn void inventories_compose_imported_annotations_and_explicit_aliases() @test
{
	Server server = c3ttp::@server(
		inventory_handlers::@routes(),
		{
			c3ttp::@route(hello),
			{ Method.GET, "/alias", &hello },
			{ Method.GET, "/explicit", &explicit_only },
		},
	);
	String[5] targets = { "/health?probe=1", "/echo", "/hello", "/alias", "/explicit" };
	String[5] bodies = { "ok", "posted", "hello", "hello", "explicit" };
	foreach (i, target : targets)
	{
		Request request = { .target = target, .method_id = i == 1 ? POST : GET, .body = "posted" };
		Response response;
		server.handler(&request, &response, null)!!;
		test::eq((ushort)200, response.status);
		test::eq(bodies[i], response.body);
	}
	Request request = { .target = "/alias", .method_id = POST };
	Response response;
	server.handler(&request, &response, null)!!;
	test::eq((ushort)404, response.status);
}

fn void materialized_routes_work_alone_and_beside_existing_registration_forms() @test
{
	Server single = c3ttp::@server(c3ttp::@route(hello));
	Server mixed = c3ttp::@server(
		{ c3ttp::@route(inventory_handlers::health) },
		hello,
		{ Method.POST, "/echo", &inventory_handlers::echo },
	);
	Request request = { .target = "/hello?x=1", .method_id = GET };
	Response first, second;
	single.handler(&request, &first, null)!!;
	mixed.handler(&request, &second, null)!!;
	test::eq("hello", first.body);
	test::eq(first.body, second.body);
}
