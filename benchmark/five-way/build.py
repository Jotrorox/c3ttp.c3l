#!/usr/bin/env python3
"""Build equivalent applications from pinned revisions; never modifies library sources."""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = Path(os.environ.get('C3TTP_COMPARISON_DIR', '/tmp/c3ttp-five-way')).resolve()
REFS = {
    'main': 'ce049990004207ef47ec6e0cfc01662a316ceb0e',
    'explicit': '9585c33c35477119f3161172c6bc9733a54389ab',
    'route': 'c1875c5790f012020b94143bd37429b9384df1d3',
    'methods': '3e5d6c84c3183dd24ecb7cb37a1ce5c5f4cde89f',
}
DEPS = {
    'eclair': ('https://github.com/Ecoral360/eclair.c3l', 'f8a837d0649d797fada62eadacc8cb7843939cca'),
    'dessert': ('https://github.com/Ecoral360/dessert.c3l', '8a3f69794ef63d56c044c3f8734442fbd45c7f63'),
}


def output(*cmd, cwd=ROOT):
    return subprocess.check_output(cmd, cwd=cwd, text=True).strip()


def source(label, count):
    routes = [('health', 'GET', '/health', '"ok"'),
              ('hello', 'GET', '/hello', '"Hello world!\\n"'),
              ('status', 'GET', '/status', '"OK"'),
              ('echo', 'POST', '/echo', 'req.body()' if label == 'eclair' else 'req.body')]
    routes += [(f'route_{i:03}', 'GET', f'/route/{i:03}', '"ok"') for i in range(count - 4)]
    lines = ['module comparison;', '', f'import {"eclair" if label == "eclair" else "c3ttp"};', '']
    if label == 'main':
        lines += ['fn void? dispatch(RequestView* req, ResponseView* res, void* context)', '{']
        for name, method, path, body in routes:
            lines += [f'    if (req.method_id == {method} && (req.target == "{path}" ||',
                      f'        (req.target.len > {len(path)} && req.target[{len(path)}] == \'?\' && req.target[:{len(path)}] == "{path}")))',
                      f'    {{ res.ok({body}); return; }}']
        lines += ['    res.set(404, "Not Found", "text/plain; charset=utf-8");', '}', '']
    else:
        for name, method, path, body in routes:
            annotation = (f' @Route({{ {method}, "{path}" }})' if label in ('route', 'eclair') else
                          f' @{method.title()}("{path}")' if label == 'methods' else '')
            params = 'Request* req' if name == 'echo' else ''
            lines += [f'fn String {name}({params}){annotation} {{ return {body}; }}']
    lines += ['', 'fn int main(String[] args)', '{']
    if label == 'eclair':
        lines += ['    Server server = eclair::new_server(8080);']
        lines += [f'    server.@add_route({name});' for name, _, _, _ in routes]
        lines += ['    server.listen();']
    else:
        lines += ['    ServerOptions options = c3ttp::default_server_options();',
                  '    options.workers = 1;', '    options.backend = POLL;',
                  '    foreach (String arg : args[1..])',
                  '        if (arg == "--io-uring") options.backend = IO_URING;']
        if label == 'main':
            lines += ['    c3ttp::serve("127.0.0.1", 8080, &dispatch, options: options)!!;']
        else:
            entries = [f'{{ Method.{method}, "{path}", &{name} }}' if label == 'explicit' else name
                       for name, method, path, _ in routes]
            lines += ['    Server server = c3ttp::@server(', '        ' + ',\n        '.join(entries) + ');',
                      '    server.options = options;', '    server.listen("127.0.0.1", 8080)!!;']
    return '\n'.join(lines + ['    return 0;', '}', ''])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--compiler', default=str(OUT / 'toolchain/c3/c3c'))
    args = p.parse_args()
    compiler = str(Path(shutil.which(args.compiler) or args.compiler).resolve())
    OUT.mkdir(parents=True, exist_ok=True)
    revisions = {}
    for label, ref in REFS.items():
        revision = output('git', 'rev-parse', ref + '^{commit}')
        revisions[label] = revision
        tree = OUT / 'trees' / label
        for name in output('git', 'ls-tree', '-r', '--name-only', revision).splitlines():
            if name == 'c3ttp.c3i' or name.startswith('src/'):
                dest = tree / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(subprocess.check_output(['git', 'show', f'{revision}:{name}'], cwd=ROOT))
    for label, (url, revision) in DEPS.items():
        tree = OUT / 'lib' / (label + '.c3l')
        if not tree.exists():
            tree.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['git', 'clone', url, str(tree)], check=True)
        if output('git', 'status', '--porcelain', cwd=tree):
            raise SystemExit(f'Dependency has local changes: {tree}')
        subprocess.run(['git', 'checkout', '--detach', revision], cwd=tree, check=True)
        revisions[label] = output('git', 'rev-parse', 'HEAD', cwd=tree)
    rows = []
    failures = []
    for count in (4, 32, 100):
        for label in (*REFS, 'eclair'):
            project = OUT / f'{label}-{count}'
            project.mkdir(exist_ok=True)
            shutil.rmtree(project / 'build', ignore_errors=True)
            fixture = project / 'main.c3'
            fixture.write_text(source(label, count))
            if label == 'eclair':
                manifest = {'langrev': '1', 'dependency-search-paths': ['../lib'],
                            'dependencies': ['eclair', 'dessert'], 'sources': ['main.c3'],
                            'opt': 'O3', 'cflags': '-O3',
                            'targets': {'server': {'type': 'executable'}}}
                (project / 'project.json').write_text(json.dumps(manifest, indent=2) + '\n')
                command = [compiler, 'build', 'server', '-vv', '--cc', str(HERE / 'cc-record.py')]
                binary = project / 'out/server'
            else:
                tree = OUT / 'trees' / label
                binary = project / 'server'
                command = [compiler, '-O3', 'compile', str(tree / 'c3ttp.c3i'), str(tree / 'src'), str(fixture), '-o', str(binary)]
            start = time.monotonic()
            cc_log = project / 'cc-commands.jsonl'
            cc_log.write_text('')
            result = subprocess.run(command, cwd=project, capture_output=True, text=True,
                                    env={**os.environ, 'C3TTP_CC_LOG': str(cc_log)})
            elapsed = time.monotonic() - start
            (project / 'build.log').write_text(result.stdout + result.stderr)
            if result.returncode:
                failures.append(dict(label=label, routes=count, error=result.stdout + result.stderr))
                print(f'{label} {count} routes: BUILD FAILED (see build.log)', flush=True)
                if count == 4:
                    raise SystemExit(result.stdout + result.stderr)
                continue
            row = dict(label=label, routes=count, binary=str(binary), build_seconds=elapsed,
                       binary_bytes=binary.stat().st_size, command=command,
                       source_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                       binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                       c_commands=[json.loads(line) for line in cc_log.read_text().splitlines()])
            if label == 'eclair':
                assert any('-c' in cmd and '-O3' in cmd for cmd in row['c_commands']), 'Missing optimized C compilation'
            rows.append(row)
            print(f'{label} {count} routes: {elapsed:.2f}s, {binary.stat().st_size} bytes', flush=True)
    metadata = dict(revisions=revisions, compiler=output(compiler, '--version'),
                    c_compiler=output('cc', '--version'), platform=platform.platform(),
                    cpu=output('lscpu'), builds=rows, failures=failures, optimization='C3 -O3; Eclair C sources -O3',
                    toolchain_archive_sha256=hashlib.sha256((OUT / 'toolchain/c3-linux.tar.gz').read_bytes()).hexdigest()
                    if (OUT / 'toolchain/c3-linux.tar.gz').exists() else None)
    (OUT / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')


if __name__ == '__main__':
    main()
