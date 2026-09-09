module hello_server;

import c3ttp;
import std::io;

fn String hello() @Route({ GET, "/" })
{
	return "Hello from c3ttp\n";
}

fn String health() @Route({ GET, "/health" })
{
	return "ok";
}

fn void api_status(Response* response)
{
	response.json("{\"status\":\"ok\"}");
}

fn String echo(Request* request)
{
	return request.body;
}

// GET /get-number-back/5 returns the raw segment "5" without allocating.
fn String? number(RouteParams* params) @Route({ GET, "/get-number-back/{number}" })
{
	return params.get("number");
}

fn int main(String[] args)
{
	ServerOptions options = c3ttp::default_server_options();
	// Zero selects every available CPU. Keep one worker for easy local use.
	options.workers = 1;
	foreach (String argument : args[1..])
	{
		if (argument == "--epoll") options.backend = POLL;
		if (argument == "--io-uring") options.backend = IO_URING;
		if (argument == "--workers=2") options.workers = 2;
		if (argument == "--all-cpus") options.workers = 0;
	}
	String backend = options.backend != POLL && c3ttp::io_uring_available() ? "io_uring" : "epoll";
	if (options.workers)
	{
		io::printfn("c3ttp listening on http://127.0.0.1:8080 (%s, workers=%d)", backend, options.workers);
	}
	else
	{
		io::printfn("c3ttp listening on http://127.0.0.1:8080 (%s, all allowed CPUs)", backend);
	}
	Server server = c3ttp::@server({
		c3ttp::@route(health),
		c3ttp::@route(hello),
		c3ttp::@route(number),
		{ Method.GET, "/status", &api_status },
		{ Method.POST, "/echo", &echo },
	});
	server.options = options;
	server.listen("127.0.0.1", 8080)!!;
	return 0;
}
