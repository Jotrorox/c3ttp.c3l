#!/usr/bin/env python3
"""Compare prebuilt servers using alternating, pinned wrk runs (no rebuilds)."""
import argparse
import http.client
import json
import os
import re
import socket
import statistics
import subprocess
import time
from pathlib import Path


def measure(binary, backend, connections, args):
    command = ["taskset", "-c", str(args.server_cpu), str(Path(binary).resolve()), "--" + backend]
    with open(os.devnull, "w") as log:
        server = subprocess.Popen(command, stdout=log, stderr=log)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError(f"Server exited: {command}")
                client = http.client.HTTPConnection("127.0.0.1", 8080, timeout=0.2)
                try:
                    client.request("GET", "/health")
                    response = client.getresponse()
                    if (response.status, response.read()) != (200, b"ok"):
                        raise RuntimeError("Benchmark response must be HTTP 200 with body 'ok'")
                    break
                except (OSError, http.client.HTTPException):
                    time.sleep(0.05)
                finally:
                    client.close()
            else:
                raise RuntimeError("Server did not become ready")
            base = ["taskset", "-c", args.client_cpus, args.wrk, "-t2", f"-c{connections}", "--latency"]
            url = "http://127.0.0.1:8080/health"
            subprocess.run(base + ["-d1s", url], check=True, capture_output=True)
            result = subprocess.run(base + [f"-d{args.seconds}s", url], check=True, capture_output=True, text=True).stdout
            if "Socket errors" in result or "Non-2xx" in result:
                raise RuntimeError(result)
            return {"rps": float(re.search(r"Requests/sec:\s+([\d.]+)", result)[1]), "raw": result}
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            # io_uring may hold the listening socket briefly after process exit.
            # Wait for release before another SO_REUSEPORT listener is launched.
            for _ in range(100):
                with socket.socket() as probe:
                    probe.settimeout(0.1)
                    if probe.connect_ex(("127.0.0.1", 8080)) != 0:
                        break
                time.sleep(0.05)
            else:
                raise RuntimeError("Listener was not released after server exit")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("binaries", nargs="+", help="LABEL=PATH, measured in alternating order")
    p.add_argument("--wrk", default="wrk")
    p.add_argument("--runs", type=int, default=5)
    p.add_argument("--seconds", type=int, default=3)
    p.add_argument("--server-cpu", type=int, default=2)
    p.add_argument("--client-cpus", default="4,5")
    p.add_argument("--backends", nargs="+", choices=["epoll", "io-uring"], default=["epoll", "io-uring"])
    p.add_argument("--output", required=True)
    p.add_argument("--max-regression", type=float, default=3.0,
                   help="Fail if the second binary's median throughput drops by more than this percent")
    args = p.parse_args()
    binaries = [item.split("=", 1) for item in args.binaries]
    if any(len(item) != 2 or not all(item) for item in binaries):
        p.error("binaries must be LABEL=PATH")
    if len({label for label, _ in binaries}) != len(binaries):
        p.error("binary labels must be unique")
    if args.max_regression < 0:
        p.error("max-regression must be nonnegative")
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    if args.runs < 1 or args.seconds < 1:
        p.error("runs and seconds must be positive")
    with socket.socket() as probe:
        probe.settimeout(0.1)
        if probe.connect_ex(("127.0.0.1", 8080)) == 0:
            raise RuntimeError("Port 8080 is already in use; stop that server first")
    rows = []
    for backend in args.backends:
        for connections in (2, 64):
            for repeat in range(args.runs):
                for label, binary in binaries[::1 if repeat % 2 == 0 else -1]:
                    row = dict(label=label, backend=backend, connections=connections, repeat=repeat)
                    row.update(measure(binary, backend, connections, args))
                    rows.append(row)
                    print(f"{label} {backend} c={connections} run={repeat + 1}: {row['rps']:.0f} req/s", flush=True)
                    Path(args.output).write_text(json.dumps({"config": vars(args), "results": rows}, indent=2) + "\n")

    failed = False
    if len(binaries) == 2:
        for backend in args.backends:
            for connections in (2, 64):
                medians = [statistics.median(row["rps"] for row in rows
                           if row["label"] == label and row["backend"] == backend
                           and row["connections"] == connections) for label, _ in binaries]
                change = (medians[1] / medians[0] - 1) * 100
                print(f"Median {backend} c={connections}: {medians[0]:.0f} -> {medians[1]:.0f} req/s ({change:+.2f}%)")
                failed |= change < -args.max_regression
    if failed:
        raise SystemExit("Throughput regression exceeds the configured noise allowance")


if __name__ == "__main__":
    main()
