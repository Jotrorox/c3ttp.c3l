module router_simple;

import c3ttp, std::io;

fn void? index_handler(Request* req, Response* res, RouteContext* ctx)
{
    return res.ok("Welcome!\n");
}

fn void? hello_handler(Request* req, Response* res, RouteContext* ctx)
{
    String name = ctx.param("name");
    if (name.len > 0)
    {
        return res.ok(string::tformat("Hello, %s!\n", name));
    }
    else
    {
        return res.ok("Hello, World!\n");
    }
}

fn void? user_handler(Request* req, Response* res, RouteContext* ctx)
{
    String id = ctx.param("id");
    if (id.len > 0)
    {
        return res.ok(string::tformat("User: %s\n", id));
    }
    else
    {
        return res.not_found("No user id\n");
    }
}

fn int main()
{
    Router router;
    router.init(mem);
    defer router.free();

    router.get("/", &index_handler);
    router.get("/hello", &hello_handler);
    router.get("/hello/{name}", &hello_handler);
    router.get("/users/{id}", &user_handler);

    Server server;
    server.init(mem, "127.0.0.1", 8080, 64);
    defer server.free();

    if (catch err = router.serve_evented(&server, 0))
    {
        if (err == io::EOF) return 0;
        return 1;
    }
    return 0;
}