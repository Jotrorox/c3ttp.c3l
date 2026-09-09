module inventory_handlers;
import c3ttp;

fn String health() @Route({ GET, "/health" }) => "ok";
fn String echo(Request* req) => req.body;

// Export a compile-time inventory from a feature module.
macro @routes()
{
	return {
		c3ttp::@route(health),
		{ Method.POST, "/echo", &echo },
	};
}
