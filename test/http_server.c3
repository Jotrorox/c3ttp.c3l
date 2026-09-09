module http_integration_server;
import c3ttp;

faultdef TEST_FAILURE;
fn String health() @Get("/health") @Head("/health") => "ok";
fn String echo(Request* request) @Post("/echo") => request.body;
fn void status(Response* response) @Get("/status")
{
	response.json("{\"ok\":true}");
	response.set_status(201);
}
fn String? fail() @Get("/fail") => TEST_FAILURE~;
fn String query(Request* request) @Get("/query") => request.query();

fn int main(String[] args)
{
	Server server = c3ttp::@server(
		health,
		echo, status, fail, query,
	);
	server.options.backend = args.len > 1 && args[1] == "--io-uring" ? IO_URING : POLL;
	server.listen("127.0.0.1", 8081)!!;
	return 0;
}
