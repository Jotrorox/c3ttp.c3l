module c3ttp;

import std::core::test;
import std::io;

fn String? cookie_test_get_param(ParamList* params, String name)
{
	foreach (&param : *params)
	{
		if (param.name == name) return param.value;
	}
	return INVALID_HEADER~;
}

fn void parse_cookie_header_simple() @test
{
	ParamList cookies = parse_cookie_header(tmem, "session=abc123; user=john")!!;
	defer { foreach (&c : cookies) { c.name.free(tmem); c.value.free(tmem); } cookies.free(); }
	test::eq("abc123", cookie_test_get_param(&cookies, "session")!!);
	test::eq("john", cookie_test_get_param(&cookies, "user")!!);
}

fn void parse_cookie_header_with_whitespace() @test
{
	ParamList cookies = parse_cookie_header(tmem, "session=abc123;  user=john  ")!!;
	defer { foreach (&c : cookies) { c.name.free(tmem); c.value.free(tmem); } cookies.free(); }
	test::eq("abc123", cookie_test_get_param(&cookies, "session")!!);
	test::eq("john", cookie_test_get_param(&cookies, "user")!!);
}

fn void parse_cookie_header_without_value() @test
{
	ParamList cookies = parse_cookie_header(tmem, "session=abc123; HttpOnly")!!;
	defer { foreach (&c : cookies) { c.name.free(tmem); c.value.free(tmem); } cookies.free(); }
	test::eq("abc123", cookie_test_get_param(&cookies, "session")!!);
	test::eq("", cookie_test_get_param(&cookies, "HttpOnly")!!);
}

fn void parse_empty_cookie_header() @test
{
	ParamList cookies = parse_cookie_header(tmem, "")!!;
	defer { foreach (&c : cookies) { c.name.free(tmem); c.value.free(tmem); } cookies.free(); }
	test::eq(0, cookies.len());
}

fn void response_set_cookie_simple() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_cookie("session", "abc123")!!;
	test::eq("session=abc123", response.header("Set-Cookie")!!);
}

fn void response_set_cookie_with_attributes() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_cookie("session", "abc123", "/", 3600, true, true, "Strict")!!;
	String cookie = response.header("Set-Cookie")!!;
	test::@check(cookie.contains("session=abc123"), "expected name=value");
	test::@check(cookie.contains("Path=/"), "expected path");
	test::@check(cookie.contains("Max-Age=3600"), "expected max-age");
	test::@check(cookie.contains("HttpOnly"), "expected httponly");
	test::@check(cookie.contains("Secure"), "expected secure");
	test::@check(cookie.contains("SameSite=Strict"), "expected samesite");
}

fn void response_set_cookie_multiple_cookies() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_cookie("a", "1")!!;
	response.set_cookie("b", "2")!!;
	test::eq((usz)2, count_headers(&response.headers, "Set-Cookie"));
}

fn void response_set_cookie_no_optional_attributes() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_cookie("id", "xyz", "", -1, false, false, "")!!;
	test::eq("id=xyz", response.header("Set-Cookie")!!);
}

fn void response_set_cookie_rejects_injection_without_mutation() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();

	test::@error(response.set_cookie("session", "ok\r\nX-Evil: yes"), INVALID_HEADER);
	test::eq((sz)0, response.headers.len());

	test::@error(response.set_cookie("session", "ok", "/; Secure"), INVALID_HEADER);
	test::@error(response.set_cookie("session", "ok", "/", -1, false, false, "strict"), INVALID_HEADER);
	test::@error(response.set_cookie("bad name", "ok"), INVALID_HEADER);
	test::eq((sz)0, response.headers.len());
}

fn void header_mutators_reject_invalid_syntax_before_mutation() @test
{
	Request request;
	request.init(tmem, "GET", "/");
	defer request.free();
	request.set_header("X-Good", "original")!!;

	test::@error(request.set_header("X-Good", "changed\r\nX-Evil: yes"), INVALID_HEADER);
	test::eq("original", request.header("X-Good")!!);
	test::@error(request.add_header("Bad Name", "value"), INVALID_HEADER);
	test::eq((sz)1, request.headers.len());

	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	test::@error(response.add_header("", "value"), INVALID_HEADER);
	test::@error(response.set_header("X-Test", "bad\x00value"), INVALID_HEADER);
	test::eq((sz)0, response.headers.len());
}
