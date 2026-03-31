module hello_server;

import c3ttp, std::io;

fn void? hello(Request* request, Response* response, void* context)
{
	response.set_body("hello from c3ttp\n");
	response.set_header("Content-Type", "text/plain; charset=utf-8");
}

fn int main()
{
	Server server;
	server.init(tmem, "127.0.0.1", 8080);
	defer server.free();

	io::printn("Serving one request on http://127.0.0.1:8080");
	server.serve(&hello, 1)!!;
	return 0;
}
