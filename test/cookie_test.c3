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
	response.set_cookie("session", "abc123");
	test::eq("session=abc123", response.header("Set-Cookie")!!);
}

fn void response_set_cookie_with_attributes() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_cookie("session", "abc123", "/", 3600, true, true, "Strict");
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
	response.set_cookie("a", "1");
	response.set_cookie("b", "2");
	test::eq(2, count_headers(&response.headers, "Set-Cookie"));
}

fn void response_set_cookie_no_optional_attributes() @test
{
	Response response;
	response.init(tmem, 200, "OK");
	defer response.free();
	response.set_cookie("id", "xyz", "", -1, false, false, "");
	test::eq("id=xyz", response.header("Set-Cookie")!!);
}
