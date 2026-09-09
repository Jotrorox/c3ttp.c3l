#!/usr/bin/env python3
"""Verify that invalid public route declarations fail with useful diagnostics."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CASES = [
    ("", "at least one route"),
    ('{ Method.GET, "/", &hello }, { Method.GET, "/", &hello }', "Duplicate route"),
    ('{ Method.GET, "", &hello }', "must not be empty"),
    ('{ Method.GET, "relative", &hello }', "must start with /"),
    ('{ Method.GET, "/?query", &hello }', "query, or a fragment"),
    ('{ Method.GET, "/#fragment", &hello }', "query, or a fragment"),
    ('{ Method.GET, "/bad path", &hello }', "whitespace"),
    ('{ Method.GET, "/", &bad_return }', "must return String"),
    ('{ Method.GET, "/", &bad_parameter }', "parameters must be Request*"),
    ('{ Method.GET, "/", &too_many }', "at most three parameters"),
    ('{ Method.GET, "/" }', "must be { Method, path, &handler }"),
    ('{ 1, "/", &hello }', "methods must use Method.GET"),
    ("hello", "Handler needs @Route"),
    ("hello, annotated", "Handler needs @Route"),
    ("&annotated", "Pass an annotated function name"),
    ("annotated, annotated", "Duplicate route"),
    ('annotated, { Method.GET, "/annotated", &hello }', "Duplicate route"),
    ("annotated, invalid_path", "must start with /"),
    ("annotated, invalid_return", "must return String"),
    ("annotated, invalid_parameter", "parameters must be Request*"),
]
with tempfile.TemporaryDirectory(prefix="c3ttp-compile-test-") as directory:
    source = Path(directory) / "invalid.c3"
    for routes, expected in CASES:
        source.write_text('''module invalid_routes;
import c3ttp;
fn String hello() => "hello";
fn int bad_return() => 1;
fn String bad_parameter(int id) => "bad";
fn String too_many(Request* a, Request* b, Request* c, Request* d) => "bad";
fn String annotated() @Route({ GET, "/annotated" }) => "annotated";
fn String invalid_path() @Route({ GET, "relative" }) => "bad";
fn int invalid_return() @Route({ GET, "/return" }) => 1;
fn String invalid_parameter(int id) @Route({ GET, "/parameter" }) => "bad";
fn int main() {
    Server server = c3ttp::@server(''' + routes + ''');
    return 0;
}
''')
        result = subprocess.run(
            ["c3c", "-C", "compile", str(source), "--libdir", str(ROOT.parent), "--lib", "c3ttp"],
            cwd=directory, capture_output=True, text=True,
        )
        output = result.stdout + result.stderr
        if result.returncode == 0 or expected not in output:
            raise AssertionError(f"Expected rejection containing {expected!r}:\n{output}")
        print(f"PASS: {expected}")
