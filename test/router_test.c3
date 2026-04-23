module c3ttp;

import std::core::test;
import std::io;

fn void? router_index_handler(Request* req, Response* res, RouteContext* ctx)
{
	res.ok("index")!!;
}

fn void? router_user_handler(Request* req, Response* res, RouteContext* ctx)
{
	String id = ctx.param("id");
	res.ok(string::tformat("user:%s", id))!!;
}

fn void? router_wildcard_handler(Request* req, Response* res, RouteContext* ctx)
{
	String rest = ctx.param("*");
	res.ok(string::tformat("wildcard:%s", rest))!!;
}

fn void? router_named_wildcard_handler(Request* req, Response* res, RouteContext* ctx)
{
	String path = ctx.param("path");
	res.ok(string::tformat("path:%s", path))!!;
}

int router_mw_order_value;

fn RouterHandler? router_mw_first(RouterHandler next, RouteContext* ctx)
{
	router_mw_order_value = router_mw_order_value + 1;
	return next;
}

fn RouterHandler? router_mw_second(RouterHandler next, RouteContext* ctx)
{
	router_mw_order_value = router_mw_order_value + 10;
	return next;
}

fn void? router_mw_handler(Request* req, Response* res, RouteContext* ctx)
{
	router_mw_order_value = router_mw_order_value + 100;
	res.ok("mw-done")!!;
}

fn RouterHandler? router_context_mw(RouterHandler next, RouteContext* ctx)
{
	ctx.set("test-key", (void*)42);
	return next;
}

fn void? router_context_handler(Request* req, Response* res, RouteContext* ctx)
{
	void* val = ctx.get("test-key");
	if (val == (void*)42)
	{
		res.ok("has-context")!!;
	}
	else
	{
		res.ok("no-context")!!;
	}
}

fn void? router_context_key_clone_handler(Request* req, Response* res, RouteContext* ctx)
{
	DString ds = dstring::temp("test-key");
	String cloned_key = ds.str_view();
	void* val = ctx.get(cloned_key);
	if (val == (void*)42)
	{
		res.ok("clone-match")!!;
	}
	else
	{
		res.ok("clone-miss")!!;
	}
}

fn void? router_many_route_handler(Request* req, Response* res, RouteContext* ctx)
{
	res.ok("route-n")!!;
}

fn void router_exact_match() @test
{
	Router router;
	router.init(tmem);
	defer router.free();
	router.get("/", &router_index_handler);

	Request request;
	request.init(tmem, "GET", "/");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("index", response.body);
}

fn void router_param_extraction() @test
{
	Router router;
	router.init(tmem);
	defer router.free();
	router.get("/users/{id}", &router_user_handler);

	Request request;
	request.init(tmem, "GET", "/users/123");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("user:123", response.body);
}

fn void router_wildcard_match() @test
{
	Router router;
	router.init(tmem);
	defer router.free();
	router.get("/files/{*}", &router_wildcard_handler);

	Request request;
	request.init(tmem, "GET", "/files/docs/readme.txt");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("wildcard:docs/readme.txt", response.body);
}

fn void router_named_wildcard_match() @test
{
	Router router;
	router.init(tmem);
	defer router.free();
	router.get("/assets/{*path}", &router_named_wildcard_handler);

	Request request;
	request.init(tmem, "GET", "/assets/css/main.css");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("path:css/main.css", response.body);
}

fn void router_method_not_allowed() @test
{
	Router router;
	router.init(tmem);
	defer router.free();
	router.get("/", &router_index_handler);

	Request request;
	request.init(tmem, "POST", "/");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	test::@error(h(&request, &response, &router), ROUTE_NOT_FOUND);
}

fn void router_not_found() @test
{
	Router router;
	router.init(tmem);
	defer router.free();
	router.get("/", &router_index_handler);

	Request request;
	request.init(tmem, "GET", "/missing");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	test::@error(h(&request, &response, &router), ROUTE_NOT_FOUND);
}

fn void router_middleware_chain() @test
{
	router_mw_order_value = 0;

	Router router;
	router.init(tmem);
	defer router.free();
	router.use(&router_mw_first);
	router.use(&router_mw_second);
	router.get("/mw", &router_mw_handler);

	Request request;
	request.init(tmem, "GET", "/mw");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("mw-done", response.body);
	test::eq(111, router_mw_order_value);
}

fn void router_group_prefix() @test
{
	Router router;
	router.init(tmem);
	defer router.free();

	router.group("/api", fn void(Router* r)
	{
		r.get("/users", &router_index_handler);
		r.get("/users/{id}", &router_user_handler);
	});

	Request request;
	request.init(tmem, "GET", "/api/users/42");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("user:42", response.body);
}

fn void router_context_store() @test
{
	Router router;
	router.init(tmem);
	defer router.free();
	router.use(&router_context_mw);
	router.get("/ctx", &router_context_handler);

	Request request;
	request.init(tmem, "GET", "/ctx");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("has-context", response.body);
}

fn void router_context_store_string_key_comparison() @test
{
	Router router;
	router.init(tmem);
	defer router.free();
	router.use(&router_context_mw);
	router.get("/ctx", &router_context_key_clone_handler);

	Request request;
	request.init(tmem, "GET", "/ctx");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("clone-match", response.body);
}

fn void router_many_routes() @test
{
	Router router;
	router.init(tmem);
	defer router.free();

	for (int i = 0; i < 70; i++)
	{
		String pattern = string::tformat("/route-%d", i);
		router.get(pattern, &router_many_route_handler);
	}

	Request request;
	request.init(tmem, "GET", "/route-69");
	defer request.free();

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	Handler h = router.as_handler();
	h(&request, &response, &router)!!;

	test::eq("route-n", response.body);
}
