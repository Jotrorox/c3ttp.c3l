module c3ttp;

import std::core::test;
import std::io;

fn void parse_simple_query_string() @test
{
	FormFieldList fields = parse_query_string(tmem, "foo=bar&baz=qux")!!;
	defer { foreach (&f : fields) { f.name.free(tmem); f.value.free(tmem); } fields.free(); }
	test::eq("bar", get_form_field(&fields, "foo")!!);
	test::eq("qux", get_form_field(&fields, "baz")!!);
}

fn void parse_query_string_with_empty_value() @test
{
	FormFieldList fields = parse_query_string(tmem, "foo=&baz=qux")!!;
	defer { foreach (&f : fields) { f.name.free(tmem); f.value.free(tmem); } fields.free(); }
	test::eq("", get_form_field(&fields, "foo")!!);
	test::eq("qux", get_form_field(&fields, "baz")!!);
}

fn void parse_query_string_without_equals() @test
{
	FormFieldList fields = parse_query_string(tmem, "foo&baz=qux")!!;
	defer { foreach (&f : fields) { f.name.free(tmem); f.value.free(tmem); } fields.free(); }
	test::eq("", get_form_field(&fields, "foo")!!);
	test::eq("qux", get_form_field(&fields, "baz")!!);
}

fn void parse_query_string_with_encoding() @test
{
	FormFieldList fields = parse_query_string(tmem, "name=John%20Doe&city=New%20York")!!;
	defer { foreach (&f : fields) { f.name.free(tmem); f.value.free(tmem); } fields.free(); }
	test::eq("John Doe", get_form_field(&fields, "name")!!);
	test::eq("New York", get_form_field(&fields, "city")!!);
}

fn void parse_form_urlencoded_body() @test
{
	FormFieldList fields = parse_form_urlencoded(tmem, "email=test%40example.com&pass=secret")!!;
	defer { foreach (&f : fields) { f.name.free(tmem); f.value.free(tmem); } fields.free(); }
	test::eq("test@example.com", get_form_field(&fields, "email")!!);
	test::eq("secret", get_form_field(&fields, "pass")!!);
}

fn void request_query_extraction() @test
{
	Request request;
	request.init(tmem, "GET", "/path?a=1&b=2");
	defer request.free();
	test::eq("a=1&b=2", request.query());
}

fn void request_query_without_query_string() @test
{
	Request request;
	request.init(tmem, "GET", "/path");
	defer request.free();
	test::eq("", request.query());
}

fn void url_encode_special_chars() @test
{
	String encoded = url_encode(tmem, "hello world!");
	defer encoded.free(tmem);
	test::eq("hello%20world%21", encoded);
}

fn void url_encode_unreserved_chars() @test
{
	String encoded = url_encode(tmem, "abc-_.~123");
	defer encoded.free(tmem);
	test::eq("abc-_.~123", encoded);
}

fn void url_decode_special_chars() @test
{
	String decoded = url_decode(tmem, "hello%20world%21")!!;
	defer decoded.free(tmem);
	test::eq("hello world!", decoded);
}

fn void url_decode_plus_as_space() @test
{
	String decoded = url_decode(tmem, "hello+world")!!;
	defer decoded.free(tmem);
	test::eq("hello world", decoded);
}

fn void url_decode_invalid_encoding() @test
{
	test::@error(url_decode(tmem, "hello%ZZ"), INVALID_ENCODING);
	test::@error(url_decode(tmem, "hello%"), INVALID_ENCODING);
}

fn void get_form_field_or_returns_default() @test
{
	FormFieldList fields = parse_query_string(tmem, "foo=bar")!!;
	defer { foreach (&f : fields) { f.name.free(tmem); f.value.free(tmem); } fields.free(); }
	test::eq("bar", get_form_field_or(&fields, "foo", "default"));
	test::eq("default", get_form_field_or(&fields, "missing", "default"));
}

fn void parse_empty_query_string() @test
{
	FormFieldList fields = parse_query_string(tmem, "")!!;
	defer { foreach (&f : fields) { f.name.free(tmem); f.value.free(tmem); } fields.free(); }
	test::eq(0, fields.len());
}

fn void parse_query_string_with_duplicates() @test
{
	FormFieldList fields = parse_query_string(tmem, "foo=bar&foo=baz")!!;
	defer { foreach (&f : fields) { f.name.free(tmem); f.value.free(tmem); } fields.free(); }
	test::eq("bar", get_form_field(&fields, "foo")!!);
	test::eq(2, fields.len());
}
