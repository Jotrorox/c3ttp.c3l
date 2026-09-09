#!/usr/bin/env python3
"""Compile large mixed route inventories and check every route's response."""
import argparse
import json
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--compiler', default='c3c')
    p.add_argument('--counts', nargs='+', type=int, default=[100])
    p.add_argument('--output', type=Path)
    args = p.parse_args()
    if any(n < 1 for n in args.counts):
        p.error('Route counts must be positive')
    results = []
    with tempfile.TemporaryDirectory(prefix='c3ttp-inventory-') as directory:
        tree = Path(directory)
        for count in args.counts:
            # A feature module owns the route inventory. Alternate annotations
            # and explicit entries; unique bodies detect dispatching to a wrong handler.
            handlers = ['module inventory_feature;', 'import c3ttp;']
            entries = []
            for i in range(count):
                method = 'GET' if i % 2 == 0 else 'POST'
                attr = f' @Route({{ {method}, "/route/{i}" }})' if i % 2 == 0 else ''
                handlers.append(f'fn String handler_{i}(){attr} => "body-{i}";')
                entries.append(f'c3ttp::@route(handler_{i})' if i % 2 == 0 else
                               f'{{ Method.{method}, "/route/{i}", &handler_{i} }}')
            handlers += ['macro @routes() { return {', ',\n'.join(entries), '}; }']
            (tree / 'feature.c3').write_text('\n'.join(handlers) + '\n')
            checks = ['module inventory_scale;', 'import c3ttp;', 'import inventory_feature;',
                      'fn int main() {', 'Server server = c3ttp::@server(inventory_feature::@routes());',
                      'Request req;', 'Response res;']
            for i in range(count):
                method = 'GET' if i % 2 == 0 else 'POST'
                checks += [f'req.target = "/route/{i}?probe=1"; req.method_id = {method};',
                           'server.handler(&req, &res, null)!!;',
                           f'if (res.status != 200 || res.body != "body-{i}") return 1;']
            checks += ['req.target = "/route/0"; req.method_id = POST;',
                       'server.handler(&req, &res, null)!!;', 'if (res.status != 404) return 2;',
                       'req.target = "/missing"; req.method_id = GET;',
                       'server.handler(&req, &res, null)!!;', 'if (res.status != 404) return 3;',
                       'return 0;', '}']
            (tree / 'main.c3').write_text('\n'.join(checks) + '\n')
            binary = tree / 'check'
            command = [args.compiler, '-O3', 'compile', str(tree / 'main.c3'), str(tree / 'feature.c3'),
                       '--libdir', str(ROOT.parent), '--lib', 'c3ttp', '-o', str(binary)]
            start = time.monotonic()
            result = subprocess.run(command, cwd=tree, capture_output=True, text=True, timeout=180)
            elapsed = time.monotonic() - start
            if result.returncode:
                results.append(dict(routes=count, passed=False, build_seconds=elapsed,
                                    error=result.stdout + result.stderr))
                print(f'FAIL: {count} routes: {result.stdout + result.stderr}', flush=True)
                continue
            subprocess.run([str(binary)], cwd=tree, check=True, timeout=30)
            results.append(dict(routes=count, passed=True, checked_responses=count + 2, build_seconds=elapsed,
                                binary_bytes=binary.stat().st_size))
            print(f'PASS: {count} mixed routes across modules, {count + 2} responses checked; build {elapsed:.2f}s', flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(dict(compiler=subprocess.check_output([args.compiler, '--version'], text=True),
                                               results=results), indent=2) + '\n')
    if any(not row['passed'] for row in results):
        raise SystemExit('Some route counts failed; see the recorded diagnostics')


if __name__ == '__main__':
    main()
