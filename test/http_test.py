#!/usr/bin/env python3
"""Build a consumer and verify the static API over real Linux sockets."""
import argparse
import http.client
import socket
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--backends", nargs="+", default=["epoll", "io-uring"])
args = p.parse_args()
with tempfile.TemporaryDirectory(prefix="c3ttp-http-test-") as directory:
    binary = str(Path(directory) / "server")
    subprocess.run(["c3c", "-O3", "compile", str(ROOT / "test/http_server.c3"),
                    "--libdir", str(ROOT.parent), "--lib", "c3ttp", "-o", binary],
                   cwd=directory, check=True)
    for backend in args.backends:
        with socket.socket() as probe:
            probe.settimeout(0.1)
            if probe.connect_ex(("127.0.0.1", 8081)) == 0:
                raise RuntimeError("Port 8081 is already in use; stop that server first")
        server = subprocess.Popen([binary, "--" + backend], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError(f"{backend} server exited: {server.communicate()}")
                try:
                    with socket.create_connection(("127.0.0.1", 8081), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.02)
            else:
                raise RuntimeError("Server did not start")
            client = http.client.HTTPConnection("127.0.0.1", 8081, timeout=5)
            cases = [
                ("GET", "/health", None, 200, b"ok"),
                ("GET", "/health?" + "x" * 300, None, 200, b"ok"),
                ("GET", "/status", None, 201, b'{"ok":true}'),
                ("POST", "/echo", b"borrowed body" * 1000, 200, b"borrowed body" * 1000),
                ("HEAD", "/health", None, 200, b""),
                ("GET", "/query?a=b&c=d", None, 200, b"a=b&c=d"),
                ("GET", "/health/", None, 404, b"Not Found"),
                ("POST", "/health", b"", 404, b"Not Found"),
                ("GET", "/missing", None, 404, b"Not Found"),
                ("GET", "/fail", None, 500, b"Internal Server Error"),
            ]
            for method, target, body, status, expected in cases:
                client.request(method, target, body=body)
                response = client.getresponse()
                actual = response.read()
                assert (response.status, actual) == (status, expected), (backend, method, target, response.status, actual)
                if target == "/status":
                    assert response.getheader("Content-Type") == "application/json"
                if method == "HEAD":
                    assert response.getheader("Content-Length") == "2"
                if target == "/fail":
                    assert response.getheader("Connection") == "close"
            client.close()
            # Two responses must preserve the first request's borrowed body
            # until it has been sent, before the engine moves the next request.
            with socket.create_connection(("127.0.0.1", 8081), timeout=5) as connection:
                connection.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
                                   b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                wire = b""
                while data := connection.recv(4096):
                    wire += data
                assert wire.count(b"HTTP/1.1 200 OK") == 2, wire
                assert b"\r\n\r\nhelloHTTP/1.1 200 OK" in wire, wire
                assert wire.endswith(b"\r\n\r\nok"), wire
            print(f"PASS: {backend}: {len(cases)} HTTP cases and borrowed-body pipelining")
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
