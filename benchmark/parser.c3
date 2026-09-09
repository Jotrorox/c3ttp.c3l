module parser_benchmark;
import c3ttp;
import std::io;
import std::time::clock;

// A real parser call per iteration; the checksum keeps results observable.
fn int main()
{
	String[3] inputs = {
		"GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n",
		"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello",
		"POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
	};
	const usz ITERATIONS = 5_000_000;
	usz checksum;
	foreach (index, wire : inputs)
	{
		Clock start = clock::now();
		for (usz i; i < ITERATIONS; i++)
		{
			RequestParser parser;
			parser.init();
			parser.parse((char[])wire)!!;
			checksum += parser.request.message_length + parser.request.body_length;
		}
		double ns = (double)(long)start.to_now() / (double)ITERATIONS;
		io::printfn("parser_%d %.3f ns/request", index, ns);
	}
	io::printfn("checksum %d", checksum);
	return 0;
}
