#!/usr/bin/env python3
"""Pinned, rotated five-way HTTP comparison with validation and RSS measurements."""
import argparse
import contextlib
import http.client
import json
import os
import re
import resource
import socket
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get('C3TTP_COMPARISON_DIR', '/tmp/c3ttp-five-way')).resolve()


def rss(pid):
    values = {}
    for line in Path(f'/proc/{pid}/status').read_text().splitlines():
        key, _, value = line.partition(':')
        if key in ('VmRSS', 'VmHWM'):
            values[key] = int(value.split()[0])
    return values


def request(method, path, body=None, connection=None):
    own = connection is None
    client = connection or http.client.HTTPConnection('127.0.0.1', 8080, timeout=2)
    try:
        client.request(method, path, body=body)
        response = client.getresponse()
        return response.status, response.read(), dict(response.getheaders())
    finally:
        if own:
            client.close()


def assert_free():
    with socket.socket() as probe:
        probe.settimeout(0.1)
        if probe.connect_ex(('127.0.0.1', 8080)) == 0:
            raise RuntimeError('Port 8080 is occupied')


@contextlib.contextmanager
def server(build, backend, args):
    def limit_memory():
        # Bound an upstream allocation leak; failed runs never enter medians.
        ceiling = args.memory_limit_mb * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (ceiling, ceiling))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    command = ['taskset', '-c', str(args.server_cpu), build['binary'], '--' + backend]
    log_path = OUT / f"{build['label']}-{build['routes']}-{backend}.log"
    with log_path.open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=log, preexec_fn=limit_memory)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError(f'Server exited with {process.returncode}; see {log_path}')
                try:
                    status, body, _ = request('GET', '/health')
                    if (status, body) != (200, b'ok'):
                        raise RuntimeError('Health check returned incorrect status/body')
                    break
                except (OSError, http.client.HTTPException):
                    time.sleep(0.05)
            else:
                raise RuntimeError('Server did not become ready')
            yield process
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            for _ in range(100):
                try:
                    assert_free()
                    break
                except RuntimeError:
                    time.sleep(0.05)
            else:
                raise RuntimeError('Server did not release port 8080')


def verify(build, backend, args):
    with server(build, backend, args) as process:
        cases = [('GET', '/health', None, 200, b'ok'),
                 ('GET', '/health?probe=1', None, 200, b'ok'),
                 ('GET', '/hello', None, 200, b'Hello world!\n'),
                 ('GET', '/status', None, 200, b'OK'),
                 ('POST', '/echo', b'echo-me' * 100, 200, b'echo-me' * 100),
                 ('POST', '/health', b'', 404, None),
                 ('GET', '/absent', None, 404, None)]
        if build['routes'] > 4:
            cases += [('GET', f'/route/{i:03}', None, 200, b'ok') for i in range(build['routes'] - 4)]
        for method, path, body, expected_status, expected_body in cases:
            status, data, headers = request(method, path, body)
            assert status == expected_status, (build['label'], method, path, status)
            assert expected_body is None or data == expected_body, (build['label'], path, data)
        repeated = []
        workload_cases = [('GET', '/health', None, b'ok'),
                          ('POST', '/echo', b'x' * 256, b'x' * 256)]
        if build['routes'] > 4:
            workload_cases.append(('GET', f"/route/{build['routes'] - 5:03}", None, b'ok'))
        for method, path, body, expected in workload_cases:
            client = http.client.HTTPConnection('127.0.0.1', 8080, timeout=2)
            try:
                for _ in range(100):
                    status, data, _ = request(method, path, body, client)
                    assert (status, data) == (200, expected), (build['label'], method, path, status, data)
                    assert client.sock is not None, (build['label'], path, 'closed connection')
            finally:
                client.close()
            repeated.append(dict(method=method, path=path, checked_requests=100))
        status, body, headers = request('GET', '/health')
        checks = []
        client = http.client.HTTPConnection('127.0.0.1', 8080, timeout=2)
        try:
            for method, path, body, expected_status, expected_body in cases[:5]:
                status, data, response_headers = request(method, path, body, client)
                checks.append(dict(method=method, path=path, status=status,
                                   body_matches=data == expected_body,
                                   keep_alive=client.sock is not None,
                                   headers=response_headers))
        except (OSError, http.client.HTTPException) as error:
            checks.append(dict(error=str(error)))
        finally:
            client.close()
        return dict(label=build['label'], routes=build['routes'], backend=backend,
                    fresh_connection_checks=len(cases), repeated_keep_alive=repeated, mixed_keep_alive=checks,
                    health_headers=headers, rss_kib=rss(process.pid))



def wrk(process, args, connections, seconds, path, post=False):
    command = ['taskset', '-c', args.client_cpus, args.wrk, '-t2', f'-c{connections}',
               '--latency', f'-d{seconds}s']
    if post:
        command += ['-s', str(HERE / 'post.lua')]
    result = subprocess.run(command + ['http://127.0.0.1:8080' + path], capture_output=True, text=True,
                            timeout=seconds + 15)
    raw = result.stdout + result.stderr
    if result.returncode or 'Socket errors' in raw or 'Non-2xx' in raw or process.poll() is not None:
        raise RuntimeError(f'Failed wrk sample (server exit={process.poll()}):\n{raw}')
    match = re.search(r'Requests/sec:\s+([\d.]+)', raw)
    latency = re.search(r'99%\s+([\d.]+)(us|ms|s)', raw)
    if not match or not latency:
        raise RuntimeError('Unrecognized wrk output: ' + raw)
    return dict(rps=float(match[1]), p99_us=float(latency[1]) * {'us': 1, 'ms': 1000, 's': 1000000}[latency[2]], raw=raw)


def measure(build, backend, scenario, args):
    with server(build, backend, args) as process:
        status, body, _ = request('POST' if scenario.get('post') else 'GET', scenario['path'],
                                  b'x' * 256 if scenario.get('post') else None)
        assert (status, body) == (200, b'x' * 256 if scenario.get('post') else b'ok')
        initial = rss(process.pid)
        wrk(process, args, scenario['connections'], args.warmup, scenario['path'], scenario.get('post'))
        warmed = rss(process.pid)
        result = wrk(process, args, scenario['connections'], args.seconds, scenario['path'], scenario.get('post'))
        result.update(rss_initial_kib=initial, rss_warm_kib=warmed, rss_final_kib=rss(process.pid))
        return result


def memory_probe(build, args):
    with server(build, 'epoll', args) as process:
        client = http.client.HTTPConnection('127.0.0.1', 8080, timeout=2)
        path = '/health' if build['routes'] == 4 else f"/route/{build['routes'] - 5:03}"
        samples = []
        try:
            for i in range(5001):
                if i % 1000 == 0:
                    samples.append(dict(requests=i, **rss(process.pid)))
                if i == 5000:
                    break
                status, body, _ = request('GET', path, connection=client)
                assert (status, body) == (200, b'ok')
        finally:
            client.close()
        return dict(label=build['label'], routes=build['routes'], path=path, samples=samples)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--wrk', default='wrk')
    p.add_argument('--runs', type=int, default=5)
    p.add_argument('--seconds', type=int, default=3)
    p.add_argument('--warmup', type=int, default=1)
    p.add_argument('--server-cpu', type=int, default=2)
    p.add_argument('--client-cpus', default='4,5')
    p.add_argument('--memory-limit-mb', type=int, default=2048)
    p.add_argument('--output', type=Path, default=OUT / 'http.json')
    p.add_argument('--validate-only', action='store_true')
    args = p.parse_args()
    if min(args.runs, args.seconds, args.warmup, args.memory_limit_mb) < 1:
        p.error('Runs, durations, and memory ceiling must be positive')
    assert_free()
    builds = json.loads((OUT / 'build.json').read_text())['builds']
    document = dict(config={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                    validation=[], memory=[], results=[], failures=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    def save():
        args.output.write_text(json.dumps(document, indent=2) + '\n')
    for build in builds:
        for backend in ('epoll',) if build['label'] == 'eclair' else ('epoll', 'io-uring'):
            document['validation'].append(verify(build, backend, args))
            print(f"Validated {build['label']} {build['routes']} {backend}", flush=True)
        document['memory'].append(memory_probe(build, args))
        save()
    if args.validate_only:
        return
    scenarios = [dict(name='small-first-c2', routes=4, path='/health', connections=2),
                 dict(name='small-first-c64', routes=4, path='/health', connections=64),
                 dict(name='small-post-c64', routes=4, path='/echo', connections=64, post=True),
                 dict(name='medium-last-c64', routes=32, path='/route/027', connections=64),
                 dict(name='large-last-c64', routes=100, path='/route/095', connections=64)]
    for scenario in scenarios:
        for backend in ('epoll', 'io-uring') if scenario['name'] == 'small-first-c64' else ('epoll',):
            candidates = [b for b in builds if b['routes'] == scenario['routes'] and
                          (backend == 'epoll' or b['label'] != 'eclair')]
            for repeat in range(args.runs):
                # Latin rotation distributes first/last positions across five repetitions.
                shift = repeat % len(candidates)
                for build in candidates[shift:] + candidates[:shift]:
                    identity = dict(label=build['label'], backend=backend, scenario=scenario['name'],
                                    routes=build['routes'], connections=scenario['connections'], repeat=repeat + 1)
                    try:
                        row = dict(**identity, **measure(build, backend, scenario, args))
                        document['results'].append(row)
                        print(f"{identity}: {row['rps']:.0f} req/s; RSS {row['rss_final_kib']['VmRSS']} KiB", flush=True)
                    except (RuntimeError, subprocess.TimeoutExpired) as error:
                        log_path = OUT / f"{build['label']}-{build['routes']}-{backend}.log"
                        document['failures'].append(dict(**identity, error=str(error),
                            server_log=log_path.read_text() if log_path.exists() else ''))
                        print(f'FAILED {identity}: {error}', flush=True)
                    save()
    print(f"Saved {len(document['results'])} valid samples; {len(document['failures'])} failed samples to {args.output}")


if __name__ == '__main__':
    main()
