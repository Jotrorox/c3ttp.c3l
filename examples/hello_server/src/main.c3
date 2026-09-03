module hello_server;

import c3ttp;
import std::io;

fn void? hello(RequestView* request, ResponseView* response, void* context)
{
	if (request.target == "/health")
	{
		c3ttp::ResponseView.ok(response, "ok");
		return;
	}
	c3ttp::ResponseView.set(response, 200, "Hello from c3ttp\n");
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
	c3ttp::serve("127.0.0.1", 8080, &hello, options: options)!!;
	return 0;
}
