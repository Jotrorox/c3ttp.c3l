module server_minimal;

import c3ttp, std::io;

fn void? handler(Request* req, Response* res, void* ctx)
{
    return res.ok("Hello");
}

fn int main()
{
    Server server;
    server.init(mem, "127.0.0.1", 8080, 64);
    defer server.free();
    io::printn("Server initialized");
    server.serve_prefork(&handler)!!;
    return 0;
}
