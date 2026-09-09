module http_integration_server;
import c3ttp;

faultdef TEST_FAILURE;
fn String health() @Route({ GET, "/health" }) => "ok";
fn String echo(Request* request) @Route({ POST, "/echo" }) => request.body;
fn void status(Response* response) @Route({ GET, "/status" })
{
	response.json("{\"ok\":true}");
	response.set_status(201);
}
fn String? fail() @Route({ GET, "/fail" }) => TEST_FAILURE~;
fn String query(Request* request) @Route({ GET, "/query" }) => request.query();

fn int main(String[] args)
{
	Server server = c3ttp::@server(
		health,
		{ Method.HEAD, "/health", &health },
		echo, status, fail, query,
	);
	server.options.backend = args.len > 1 && args[1] == "--io-uring" ? IO_URING : POLL;
	server.listen("127.0.0.1", 8081)!!;
	return 0;
}
