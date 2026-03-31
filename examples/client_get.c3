module client_get;

import c3ttp, std::io;

fn int main()
{
	Client client = c3ttp::new_client();
	Response response = client.send_url(tmem, "GET", "http://example.com/")!!;
	defer response.free();

	io::printfn("%d %s", response.status, response.reason);
	io::printn(response.body);
	return 0;
}
