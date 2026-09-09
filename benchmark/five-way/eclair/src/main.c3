module eclair_comparison @feat(FIVE_WAY_ECLAIR);

import eclair;

fn String health() @Route({ GET, "/health" }) { return "ok"; }
fn String hello() @Route({ GET, "/hello" }) { return "Hello world!\n"; }
fn String status() @Route({ GET, "/status" }) { return "OK"; }
fn String echo(Request* req) @Route({ POST, "/echo" }) { return req.body(); }

fn int main(String[] args)
{
    Server server = eclair::new_server(8080);
    server.@add_route(health);
    server.@add_route(hello);
    server.@add_route(status);
    server.@add_route(echo);
    server.listen();
    return 0;
}
