module hello_server;

import c3ttp, std::io, std::time;

fn void? hello(Request* request, Response* response, void* context)
{
	response.set_body("hello from c3ttp\n");
	response.set_header("Content-Type", "text/plain; charset=utf-8");
}

fn int main()
{
	ServerOptions options = c3ttp::default_server_options();
	options.limits.max_buffered_body_size = 256 * 1024;
	options.limits.max_chunked_body_size = 512 * 1024;
	options.timeouts.header_timeout = time::sec(5);
	options.timeouts.idle_timeout = time::sec(10);

	Server server;
	server.init(tmem, "127.0.0.1", 8080, 64, options);
	defer server.free();

	io::printn("Serving one request on http://127.0.0.1:8080");
	server.serve(&hello, 1)!!;
	return 0;
}
