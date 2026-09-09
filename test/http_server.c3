module http_integration_server;
import c3ttp;

faultdef TEST_FAILURE;
fn String health() @Route({ GET, "/health" }) => "ok";
fn String echo(Request* request) @Route({ POST, "/echo" }) => request.body;
fn void status(Response* response)
{
	response.json("{\"ok\":true}");
	response.set_status(201);
}
fn String? fail() => TEST_FAILURE~;
fn String query(Request* request) => request.query();

fn String? number(RouteParams* params) @Route({ GET, "/get-number-back/{number}" }) => params.get("number");
fn String? post_id(RouteParams* params) => params.get("post");

fn int main(String[] args)
{
	Server server = c3ttp::@server({
		c3ttp::@route(health),
		c3ttp::@route(number),
		{ Method.GET, "/users/{user}/posts/{post}", &post_id },
		{ Method.HEAD, "/health", &health },
		c3ttp::@route(echo),
		{ Method.GET, "/status", &status },
		{ Method.GET, "/fail", &fail },
		{ Method.GET, "/query", &query },
	});
	server.options.backend = args.len > 1 && args[1] == "--io-uring" ? IO_URING : POLL;
	server.listen("127.0.0.1", 8081)!!;
	return 0;
}
