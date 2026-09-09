module http_integration_server;
import c3ttp;

faultdef TEST_FAILURE;
fn String health() => "ok";
fn String echo(Request* request) => request.body;
fn void status(Response* response) => response.json("{\"ok\":true}", 201);
fn String? fail() => TEST_FAILURE~;
fn String query(Request* request) => request.query();

fn int main(String[] args)
{
	Server server = c3ttp::@server(
		{ Method.GET, "/health", &health },
		{ Method.HEAD, "/health", &health },
		{ Method.POST, "/echo", &echo },
		{ Method.GET, "/status", &status },
		{ Method.GET, "/fail", &fail },
		{ Method.GET, "/query", &query },
	);
	server.options.backend = args.len > 1 && args[1] == "--io-uring" ? IO_URING : POLL;
	server.listen("127.0.0.1", 8081)!!;
	return 0;
}
