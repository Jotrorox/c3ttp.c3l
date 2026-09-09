#!/usr/bin/env python3
"""Build pinned baselines and the working tree, validate, then benchmark serially."""
import argparse
from contextlib import closing
import hashlib
from http.client import HTTPConnection
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BASELINES = {'main': 'ce049990004207ef47ec6e0cfc01662a316ceb0e',
             'current': '19fb56da95a626cbe388f9ac391c4d6d569df98e'}
spec = importlib.util.spec_from_file_location('http_runner', ROOT / 'benchmark/five-way/run.py')
http = importlib.util.module_from_spec(spec)
spec.loader.exec_module(http)


def routes(kind, count):
    if kind == 'literal':
        return [('GET', '/health', 'ok'), ('GET', '/hello', 'hello'),
                ('GET', '/status', 'OK'), ('POST', '/echo', None)]
    return [('GET', '/health', 'ok'), ('GET', '/get-number-back/{number}', 'number'),
            ('GET', '/users/{user}/posts/{post}', 'post')] + [
                ('GET', f'/route/{i:03}/{{value}}', 'value') for i in range(count - 3)]


def fixture(label, kind, count):
    entries = routes(kind, count)
    lines = ['module template_benchmark;', 'import c3ttp;', 'import std::io;', 'import std::time::clock;']
    # Baselines lack templates: use the same small handwritten segment matcher
    # on both, retaining each branch's own literal dispatch API.
    if label != 'templates' and kind == 'mixed':
        lines += ['''fn bool segment(String target, usz* cursor, String* value) @inline
{
    usz start = *cursor;
    while (*cursor < target.len && target[*cursor] != '/' && target[*cursor] != '?') (*cursor)++;
    *value = target[start:*cursor - start];
    return *cursor > start;
}
fn bool literal(String target, usz* cursor, String value) @inline
{
    if (target.len - *cursor < value.len || target[*cursor:value.len] != value) return false;
    *cursor += value.len;
    return true;
}''']
        for i, (_, path, body) in enumerate(entries):
            if '{' not in path:
                continue
            # Emit a handwritten equivalent for each fixed template; no runtime
            # template parsing/registry is added to either baseline library.
            import re
            parts = re.split(r'(\{[^}]+\})', path)
            lines += [f'fn bool match_{i}(String target, String* result) @inline {{',
                      '    usz cursor;', '    String value;']
            for part in filter(None, parts):
                if part.startswith('{'):
                    lines += ['    if (!segment(target, &cursor, &value)) return false;']
                    if part == '{' + body + '}':
                        lines += ['    *result = value;']
                else:
                    lines += [f'    if (!literal(target, &cursor, "{part}")) return false;']
            lines += ["    return cursor == target.len || target[cursor] == '?';", '}']
    if label != 'main':
        for i, (_, path, body) in enumerate(entries):
            if '{' in path and label != 'templates':
                continue
            param = 'RouteParams* params' if '{' in path else 'Request* req'
            value = f'params.get("{body}")!!' if '{' in path else 'req.body' if body is None else json.dumps(body)
            lines += [f'fn String handler_{i}({param}) => {value};']
        literal_entries = [f'{{ Method.{m}, "{p}", &handler_{i} }}'
                           for i, (m, p, _) in enumerate(entries) if label == 'templates' or '{' not in p]
        lines += ['fn ViewHandler route_handler() {',
                  '    Server server = c3ttp::@server({ ' + ', '.join(literal_entries) + ' });',
                  '    return server.handler;', '}']
    if label != 'templates':
        lines += ['fn void? dispatch(RequestView* req, ResponseView* res, void* context) {']
        for i, (method, path, body) in enumerate(entries):
            if '{' in path:
                lines += ['    { String value;', f'    if (req.method_id == {method} && match_{i}(req.target, &value))',
                          '    { res.ok(value); return; } }']
            else:
                value = 'req.body' if body is None else json.dumps(body)
                lines += [f'''    if (req.method_id == {method} && (req.target == "{path}" ||
        (req.target.len > {len(path)} && req.target[{len(path)}] == '?' && req.target[:{len(path)}] == "{path}")))
        {{ {'res.ok(' + value + ')' if label == 'main' else 'route_handler()(req, res, context)!'}; return; }}''']
        lines += ['    res.set(404, "Not Found");', '}']
    handler = 'route_handler()' if label == 'templates' or (label == 'current' and kind == 'literal') else '&dispatch'
    lines += ['''// A real non-inlined callback invocation per iteration, with observable output.
fn void? invoke(ViewHandler handler, RequestView* req, ResponseView* res) @noinline
{
    handler(req, res, null)!;
}
fn int main(String[] args) {''', f'    ViewHandler handler = {handler};', '''    if (args.len > 2 && args[1] == "--dispatch") {
        RequestView req = { .method_id = GET, .target = args[2] };
        ResponseView res;
        usz checksum;
        const usz ITERATIONS = 10_000_000;
        Clock start = clock::now();
        for (usz i; i < ITERATIONS; i++) {
            invoke(handler, &req, &res)!!;
            checksum += res.status + res.body.len + res.body[0];
        }
        io::printfn("%.3f %d", (double)(long)start.to_now() / (double)ITERATIONS, checksum);
        return 0;
    }
    ServerOptions options = c3ttp::default_server_options();
    options.workers = 1;
    options.backend = args.len > 1 && args[1] == "--io-uring" ? IO_URING : POLL;
    c3ttp::serve("127.0.0.1", 8080, handler, options: options)!!;
    return 0;
}''']
    return '\n'.join(lines) + '\n'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--compiler', default='c3c')
    p.add_argument('--wrk', default='wrk')
    p.add_argument('--workdir', type=Path, default=Path('/tmp/c3ttp-template-benchmark'))
    p.add_argument('--output', type=Path, default=ROOT / 'benchmark/templates/results.json')
    p.add_argument('--runs', type=int, default=5)
    p.add_argument('--seconds', type=int, default=3)
    p.add_argument('--warmup', type=int, default=1)
    p.add_argument('--server-cpu', type=int, default=2)
    p.add_argument('--client-cpus', default='4,5')
    p.add_argument('--memory-limit-mb', type=int, default=2048)
    p.add_argument('--backends', nargs='+', choices=['epoll', 'io-uring'], default=['epoll', 'io-uring'])
    p.add_argument('--build-only', action='store_true')
    args = p.parse_args()
    if min(args.runs, args.seconds, args.warmup) < 1:
        p.error('Runs and durations must be positive')
    args.workdir = args.workdir.resolve()
    args.workdir.mkdir(parents=True, exist_ok=True)
    http.OUT = args.workdir
    doc = dict(config={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
               compiler=subprocess.check_output([args.compiler, '--version'], text=True),
               platform=platform.platform(), cpu=subprocess.check_output(['lscpu'], text=True),
               revisions={}, source_hashes={}, builds=[], validation=[], micro=[], results=[], failures=[])
    def save():
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(doc, indent=2) + '\n')
    for label in ['main', 'current', 'templates']:
        tree = args.workdir / 'trees' / label
        ref = subprocess.check_output(['git', 'rev-parse', BASELINES.get(label, 'HEAD')], cwd=ROOT, text=True).strip()
        doc['revisions'][label] = ref + (' + working tree (source hashes recorded)' if label == 'templates' else '')
        names = ['c3ttp.c3i'] + sorted(str(f.relative_to(ROOT)) for f in (ROOT / 'src').glob('*.c3'))
        if label != 'templates':
            names = [name for name in subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', ref], cwd=ROOT, text=True).splitlines()
                     if name == 'c3ttp.c3i' or name.startswith('src/')]
        doc['source_hashes'][label] = {}
        for name in names:
            data = (ROOT / name).read_bytes() if label == 'templates' else subprocess.check_output(['git', 'show', f'{ref}:{name}'], cwd=ROOT)
            dest = tree / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            doc['source_hashes'][label][name] = hashlib.sha256(data).hexdigest()
        for kind, count in [('literal', 4), ('mixed', 4), ('mixed', 32), ('mixed', 100)]:
            project = args.workdir / f'{label}-{kind}-{count}'
            project.mkdir(exist_ok=True)
            source = project / 'main.c3'
            source.write_text(fixture(label, kind, count))
            binary = project / 'server'
            binary.unlink(missing_ok=True)
            command = [args.compiler, '-O3', 'compile', str(tree / 'c3ttp.c3i'), str(tree / 'src'), str(source), '-o', str(binary)]
            start = time.monotonic()
            result = subprocess.run(command, cwd=project, capture_output=True, text=True, timeout=180)
            row = dict(label=label, kind=kind, routes=count, binary=str(binary), command=command,
                       build_seconds=time.monotonic() - start, passed=result.returncode == 0,
                       log=result.stdout + result.stderr, fixture_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
            if row['passed']:
                row.update(binary_bytes=binary.stat().st_size, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
            doc['builds'].append(row)
            save()
            print(f"Build {label} {kind} {count}: {row['passed']} ({row['build_seconds']:.2f}s)", flush=True)
            if not row['passed'] and count != 100:
                raise RuntimeError(row['log'])
    if args.build_only:
        return
    http.assert_free()
    builds = [b for b in doc['builds'] if b['passed']]
    for build in builds:
        for backend in args.backends:
            with http.server(build, backend, args) as process:
                cases = [('/health', 200, b'ok'), ('/health?x=1', 200, b'ok'), ('/missing', 404, b'Not Found')]
                if build['kind'] == 'mixed':
                    cases += [('/get-number-back/5', 200, b'5'), ('/get-number-back/0005?x=/x', 200, b'0005'),
                              ('/get-number-back/%2F', 200, b'%2F'), ('/get-number-back/', 404, b'Not Found'),
                              ('/get-number-back/5/6', 404, b'Not Found'), ('/users/alice/posts/42', 200, b'42'),
                              ('/users/bob/posts/7?x', 200, b'7'), ('/users/bob//7', 404, b'Not Found')]
                    cases += [(f'/route/{i:03}/5?x', 200, b'5') for i in range(build['routes'] - 3)]
                else:
                    cases += [('/hello', 200, b'hello'), ('/status', 200, b'OK')]
                with closing(HTTPConnection('127.0.0.1', 8080, timeout=3)) as client:
                    for _ in range(10):
                        for path, status, body in cases:
                            actual = http.request('GET', path, connection=client)
                            assert actual[:2] == (status, body), (build, path, actual)
                            assert client.sock is not None
                    assert http.request('POST', '/health', b'', client)[:2] == (404, b'Not Found')
                    if build['kind'] == 'literal':
                        assert http.request('POST', '/echo', b'x' * 256, client)[:2] == (200, b'x' * 256)
                    before = http.rss(process.pid)
                    probe = '/get-number-back/5' if build['kind'] == 'mixed' else '/health'
                    for _ in range(5000):
                        actual = http.request('GET', probe, connection=client)
                        assert actual[:2] == (200, b'5' if build['kind'] == 'mixed' else b'ok')
                    after = http.rss(process.pid)
                doc['validation'].append(dict(label=build['label'], kind=build['kind'], routes=build['routes'],
                    backend=backend, checks=len(cases) * 10 + 5001 + (build['kind'] == 'literal'),
                    rss_before_kib=before, rss_after_kib=after))
            save()
        print(f"Validated {build['label']} {build['kind']} {build['routes']}", flush=True)
    scenarios = [('literal', 4, '/health', b'ok'), ('mixed', 4, '/health', b'ok'),
                 ('mixed', 4, '/get-number-back/5', b'5'), ('mixed', 4, '/users/alice/posts/42', b'42'),
                 ('mixed', 32, '/route/028/5', b'5')]
    # All dispatch-only runs finish before HTTP timing; no concurrent builds/tests.
    for kind, count, path, expected in scenarios + [('mixed', 32, '/route/028/5/extra', b'Not Found')]:
        candidates = [b for b in builds if (b['kind'], b['routes']) == (kind, count)]
        for repeat in range(args.runs):
            for build in candidates[repeat % 3:] + candidates[:repeat % 3]:
                raw = subprocess.check_output(['taskset', '-c', str(args.server_cpu), build['binary'], '--dispatch', path], text=True)
                ns, checksum = raw.split()
                assert int(checksum) == 10_000_000 * ((404 if expected == b'Not Found' else 200) + len(expected) + expected[0])
                doc['micro'].append(dict(label=build['label'], kind=kind, routes=count, path=path,
                                         repeat=repeat, ns_per_dispatch=float(ns), checksum=int(checksum)))
        save()
    for kind, count, path, expected in scenarios:
        for backend in args.backends if path == '/get-number-back/5' else args.backends[:1]:
            candidates = [b for b in builds if (b['kind'], b['routes']) == (kind, count)]
            for repeat in range(args.runs):
                for build in candidates[repeat % 3:] + candidates[:repeat % 3]:
                    identity = dict(label=build['label'], kind=kind, routes=count, path=path, backend=backend, repeat=repeat)
                    try:
                        with http.server(build, backend, args) as process:
                            assert http.request('GET', path)[:2] == (200, expected)
                            http.wrk(process, args, 64, args.warmup, path)
                            row = dict(**identity, **http.wrk(process, args, 64, args.seconds, path), rss_kib=http.rss(process.pid))
                            doc['results'].append(row)
                            print(f"{identity}: {row['rps']:.0f} req/s", flush=True)
                    except (RuntimeError, subprocess.TimeoutExpired) as error:
                        doc['failures'].append(dict(**identity, error=str(error)))
                    save()
    print(f"Saved {len(doc['results'])} HTTP samples, {len(doc['failures'])} failures: {args.output}")
    if doc['failures']:
        raise SystemExit('Benchmark samples failed; inspect results')


if __name__ == '__main__':
    main()
