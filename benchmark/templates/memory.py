#!/usr/bin/env python3
"""Measure memory and resource usage of the exact three-way throughput binaries."""
import argparse
from contextlib import closing
import hashlib
from http.client import HTTPConnection, HTTPException
import json
import os
from pathlib import Path
import platform
import re
import resource
import subprocess
import time

from compare import ROOT, http


def snapshot(pid):
    """smaps gives precise page accounting; status RSS/HWM can be batched by Linux."""
    proc = Path(f'/proc/{pid}')
    status = {}
    for line in (proc / 'status').read_text().splitlines():
        key, _, value = line.partition(':')
        if key in ('VmRSS', 'VmHWM', 'VmSize', 'VmPeak', 'VmSwap', 'VmPTE', 'Threads',
                   'voluntary_ctxt_switches', 'nonvoluntary_ctxt_switches'):
            status[key] = int(value.split()[0])
    smaps = {}
    for line in (proc / 'smaps_rollup').read_text().splitlines():
        key, _, value = line.partition(':')
        if value.strip().endswith('kB'):
            smaps[key] = int(value.split()[0])
    # Fields after the closing comm parenthesis begin at /proc stat field 3.
    stat = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
    descriptors = list((proc / 'fd').iterdir())
    sockets = 0
    for fd in descriptors:
        try:
            sockets += os.readlink(fd).startswith('socket:')
        except FileNotFoundError:
            pass
    return dict(monotonic=time.monotonic(), rss_kib=smaps['Rss'], pss_kib=smaps['Pss'],
                uss_kib=smaps['Private_Clean'] + smaps['Private_Dirty'] + smaps.get('Private_Hugetlb', 0),
                shared_kib=smaps['Shared_Clean'] + smaps['Shared_Dirty'],
                anonymous_kib=smaps['Anonymous'], swap_kib=smaps['Swap'], virtual_kib=status['VmSize'],
                status_hwm_kib=status['VmHWM'], status_vmpeak_kib=status['VmPeak'],
                minor_faults=int(stat[7]), major_faults=int(stat[9]),
                cpu_ticks=int(stat[11]) + int(stat[12]),
                voluntary_switches=status['voluntary_ctxt_switches'],
                involuntary_switches=status['nonvoluntary_ctxt_switches'],
                fd_count=len(descriptors), socket_fd_count=sockets, status=status, smaps=smaps)


def endpoint(build):
    return ('/health', b'ok') if build['kind'] == 'literal' else (f"/route/{build['routes'] - 4:03}/5", b'5')


def checked(client, path, expected, status=200, method='GET', body=None):
    client.request(method, path, body=body)
    response = client.getresponse()
    actual = response.read()
    if (response.status, actual) != (status, expected) or client.sock is None:
        raise RuntimeError(f'Bad persistent response: {method} {path}: {response.status}, {actual[:80]!r}')


def settle_fds(pid, expected):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if snapshot(pid)['fd_count'] == expected:
            return
        time.sleep(.01)
    raise RuntimeError(f'File descriptors did not return to baseline {expected}: {snapshot(pid)["fd_count"]}')


def growth_cases(build):
    last, expected = endpoint(build)
    if build['kind'] == 'literal':
        return [('/health', b'ok', 200), ('/hello', b'hello', 200), ('/status', b'OK', 200),
                ('/missing', b'Not Found', 404)]
    return [(last, expected, 200), ('/get-number-back/0005?q=/raw', b'0005', 200),
            ('/users/alice/posts/42', b'42', 200), ('/get-number-back/%2F', b'%2F', 200),
            (last + '/extra', b'Not Found', 404), ('/get-number-back/', b'Not Found', 404),
            ('/health', b'ok', 200), ('/missing', b'Not Found', 404)]


def sustained(build, process, args):
    samples = []
    cases = growth_cases(build)
    with closing(HTTPConnection('127.0.0.1', 8080, timeout=5)) as client:
        for i in range(1000):
            checked(client, *cases[i % len(cases)])
        samples.append(dict(requests=0, **snapshot(process.pid)))
        for i in range(1, args.requests + 1):
            checked(client, *cases[(i - 1) % len(cases)])
            if i % args.sample_requests == 0 or i == args.requests:
                samples.append(dict(requests=i, **snapshot(process.pid)))
    return dict(warmup_requests=1000, verified_requests=args.requests, samples=samples)


def connection_scaling(build, process, args, idle_fds):
    clients = []
    rows = []
    path, expected = endpoint(build)
    try:
        rows.append(dict(phase='before_connections', connections=0, **snapshot(process.pid)))
        for count in args.connections:
            while len(clients) < count:
                client = HTTPConnection('127.0.0.1', 8080, timeout=5)
                clients.append(client)
                checked(client, path, expected)
            snap = snapshot(process.pid)
            if snap['fd_count'] != idle_fds + count:
                raise RuntimeError(f'Expected {count} accepted connections: {snap}')
            rows.append(dict(phase='small_requests', connections=count, **snap))
        # GET bodies exercise the same parser/buffer path on all three fixtures.
        # The handler still returns the same captured value or literal body.
        body = b'x' * args.body_bytes
        for client in clients:
            checked(client, path, expected, body=body)
        rows.append(dict(phase='large_bodies', connections=len(clients), body_bytes=args.body_bytes,
                         **snapshot(process.pid)))
    finally:
        for client in clients:
            client.close()
    settle_fds(process.pid, idle_fds)
    rows.append(dict(phase='after_close', connections=0, **snapshot(process.pid)))
    # Reuse the same pool capacity: distinguish retained pages from growth per cycle.
    clients = []
    try:
        for _ in range(max(args.connections)):
            client = HTTPConnection('127.0.0.1', 8080, timeout=5)
            clients.append(client)
            checked(client, path, expected, body=body)
        rows.append(dict(phase='second_large_cycle', connections=len(clients), body_bytes=args.body_bytes,
                         **snapshot(process.pid)))
    finally:
        for client in clients:
            client.close()
    settle_fds(process.pid, idle_fds)
    rows.append(dict(phase='after_second_close', connections=0, **snapshot(process.pid)))
    return rows


def loaded(build, process, args):
    path, expected = endpoint(build)
    with closing(HTTPConnection('127.0.0.1', 8080, timeout=5)) as client:
        checked(client, path, expected)
    # Establish pages before timing; the warmup is intentionally separate.
    http.wrk(process, args, 64, 1, path)
    initial = snapshot(process.pid)
    command = ['taskset', '-c', args.client_cpus, args.wrk, '-t2', '-c64', '--latency',
               f'-d{args.seconds}s', 'http://127.0.0.1:8080' + path]
    samples = []
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as load:
        deadline = time.monotonic() + args.seconds + 15
        try:
            while load.poll() is None:
                if time.monotonic() > deadline:
                    raise RuntimeError('wrk timed out')
                if process.poll() is not None:
                    raise RuntimeError('Server exited during load')
                samples.append(snapshot(process.pid))
                time.sleep(args.interval)
            stdout, stderr = load.communicate(timeout=5)
        finally:
            if load.poll() is None:
                load.kill()
                load.communicate()
    final = snapshot(process.pid)
    raw = stdout + stderr
    if load.returncode or 'Socket errors' in raw or 'Non-2xx' in raw:
        raise RuntimeError('Failed load sample: ' + raw)
    total = re.search(r'(\d+) requests in', raw)
    rps = re.search(r'Requests/sec:\s+([\d.]+)', raw)
    p99 = re.search(r'99%\s+([\d.]+)(us|ms|s)', raw)
    if not (total and rps and p99):
        raise RuntimeError('Unrecognized wrk output: ' + raw)
    requests = int(total[1])
    cpu_seconds = (final['cpu_ticks'] - initial['cpu_ticks']) / os.sysconf('SC_CLK_TCK')
    return dict(path=path, command=command, requests=requests, rps=float(rps[1]), raw=raw,
                p99_us=float(p99[1]) * {'us': 1, 'ms': 1000, 's': 1000000}[p99[2]],
                cpu_seconds=cpu_seconds, cpu_us_per_request=cpu_seconds * 1e6 / requests,
                cpu_percent=cpu_seconds / (final['monotonic'] - initial['monotonic']) * 100,
                minor_faults=final['minor_faults'] - initial['minor_faults'],
                major_faults=final['major_faults'] - initial['major_faults'],
                initial=initial, final=final, samples=samples)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', type=Path, default=Path(__file__).with_name('results.json'))
    p.add_argument('--output', type=Path, default=Path(__file__).with_name('memory-results.json'))
    p.add_argument('--wrk', default='wrk')
    p.add_argument('--runs', type=int, default=3)
    p.add_argument('--seconds', type=int, default=3)
    p.add_argument('--interval', type=float, default=.2)
    p.add_argument('--requests', type=int, default=100000)
    p.add_argument('--sample-requests', type=int, default=10000)
    p.add_argument('--connections', nargs='+', type=int, default=[1, 64, 256, 512, 1024])
    p.add_argument('--body-bytes', type=int, default=24 * 1024)
    p.add_argument('--server-cpu', type=int, default=2)
    p.add_argument('--client-cpus', default='4,5')
    p.add_argument('--monitor-cpu', type=int, default=6)
    p.add_argument('--memory-limit-mb', type=int, default=2048)
    p.add_argument('--backends', nargs='+', choices=['epoll', 'io-uring'], default=['epoll', 'io-uring'])
    p.add_argument('--labels', nargs='+', choices=['main', 'current', 'templates'], default=['main', 'current', 'templates'])
    p.add_argument('--fixtures', nargs='+', choices=['literal-4', 'mixed-4', 'mixed-32', 'mixed-100'],
                   default=['literal-4', 'mixed-4', 'mixed-32', 'mixed-100'])
    args = p.parse_args()
    if min(args.runs, args.seconds, args.requests, args.sample_requests, args.interval, args.body_bytes) <= 0:
        p.error('Counts, sizes and durations must be positive')
    if args.connections != sorted(set(args.connections)) or min(args.connections) < 1 or max(args.connections) > 1024:
        p.error('Connection counts must increase, be unique, and lie between 1 and 1024')
    if args.body_bytes > 31000:
        p.error('Bodies must fit the unchanged 32 KiB receive buffer')
    if resource.getrlimit(resource.RLIMIT_NOFILE)[0] < max(args.connections) + 32:
        p.error('Raise the file descriptor soft limit before the connection test')
    os.sched_setaffinity(0, {args.monitor_cpu})
    manifest = json.loads(args.manifest.read_text())
    builds = [b for b in manifest['builds'] if b['passed'] and b['label'] in args.labels
              and f"{b['kind']}-{b['routes']}" in args.fixtures]
    for b in builds:
        if hashlib.sha256(Path(b['binary']).read_bytes()).hexdigest() != b['binary_sha256']:
            raise RuntimeError('Binary changed since throughput benchmark: ' + b['binary'])
    # Persist the exact metadata even if the source manifest is later overwritten.
    doc = dict(config={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
               measured_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
               platform=platform.platform(), clock_ticks=os.sysconf('SC_CLK_TCK'),
               page_bytes=os.sysconf('SC_PAGE_SIZE'), compiler=manifest['compiler'], cpu=manifest['cpu'],
               revisions=manifest['revisions'], source_hashes=manifest['source_hashes'], builds=builds,
               results=[], failures=[])
    http.OUT = args.output.resolve().parent / 'memory-logs'
    http.OUT.mkdir(parents=True, exist_ok=True)
    http.assert_free()
    def save():
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(doc, indent=2) + '\n')
    for fixture in args.fixtures:
        for backend in args.backends:
            candidates = [b for b in builds if f"{b['kind']}-{b['routes']}" == fixture]
            if not candidates:
                raise RuntimeError('No matching builds for ' + fixture)
            for repeat in range(args.runs):
                offset = repeat % len(candidates)
                for build in candidates[offset:] + candidates[:offset]:
                    identity = dict(label=build['label'], kind=build['kind'], routes=build['routes'], backend=backend, repeat=repeat)
                    try:
                        with http.server(build, backend, args) as process:
                            time.sleep(.05)  # Let the readiness connection close.
                            row = dict(**identity, pid=process.pid, idle=snapshot(process.pid))
                            row['load'] = loaded(build, process, args)
                            settle_fds(process.pid, row['idle']['fd_count'])
                            if fixture == 'mixed-100':
                                row['growth'] = sustained(build, process, args)
                                settle_fds(process.pid, row['idle']['fd_count'])
                            row['final'] = snapshot(process.pid)
                        if fixture == 'mixed-100':
                            # A fresh process keeps the connection curve independent
                            # of pages touched by the preceding 64-connection load.
                            with http.server(build, backend, args) as process:
                                time.sleep(.05)
                                row['connection_idle'] = snapshot(process.pid)
                                row['connections'] = connection_scaling(build, process, args, row['connection_idle']['fd_count'])
                        doc['results'].append(row)
                        print(f"{identity}: idle RSS {row['idle']['rss_kib']} KiB; load peak {max(s['rss_kib'] for s in row['load']['samples'])} KiB", flush=True)
                    except (RuntimeError, OSError, HTTPException, AssertionError, subprocess.TimeoutExpired) as error:
                        doc['failures'].append(dict(**identity, error=str(error)))
                        print(f'FAILED {identity}: {error}', flush=True)
                    save()
    print(f"Saved {len(doc['results'])} runs and {len(doc['failures'])} failures to {args.output}")
    if doc['failures']:
        raise SystemExit('Memory benchmark failed; see recorded failures')


if __name__ == '__main__':
    main()
