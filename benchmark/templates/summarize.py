#!/usr/bin/env python3
"""Regenerate compact tables from the retained measurements."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path, nargs='?', default=Path(__file__).with_name('results.json'))
    args = p.parse_args()
    doc = json.loads(args.input.read_text())
    labels = ['main', 'current', 'templates']
    lines = ['# Measured results', '', 'HTTP: median requests/second (observed min–max), 64 connections.', '',
             '| Fixture / target / backend | main | Starting branch | Templates |', '| --- | ---: | ---: | ---: |']
    grouped = defaultdict(lambda: defaultdict(list))
    for row in doc['results']:
        grouped[(row['kind'], row['routes'], row['path'], row['backend'])][row['label']].append(row)
    summary = []
    for key, rows in grouped.items():
        cells = []
        entry = dict(fixture=key, implementations={})
        for label in labels:
            values = [r['rps'] for r in rows[label]]
            med = statistics.median(values)
            cells.append(f'{med:,.0f} ({min(values):,.0f}–{max(values):,.0f})')
            entry['implementations'][label] = dict(median_rps=med, min_rps=min(values), max_rps=max(values),
                median_p99_us=statistics.median(r['p99_us'] for r in rows[label]))
        lines.append(f'| {key[0]} {key[1]}, `{key[2]}`, {key[3]} | ' + ' | '.join(cells) + ' |')
        summary.append(entry)
    lines += ['', 'Median of per-run p99 latency, microseconds (not an aggregate percentile).', '',
              '| Fixture / target / backend | main | Starting branch | Templates |', '| --- | ---: | ---: | ---: |']
    for row in summary:
        key = row['fixture']
        lines.append(f'| {key[0]} {key[1]}, `{key[2]}`, {key[3]} | ' + ' | '.join(
            f"{row['implementations'][label]['median_p99_us']:,.1f}" for label in labels) + ' |')
    lines += ['', 'Dispatch-only: median nanoseconds/call (observed min–max); includes the common non-inlined callback wrapper and checksum.', '',
              '| Fixture / target | main | Starting branch | Templates |', '| --- | ---: | ---: | ---: |']
    grouped = defaultdict(lambda: defaultdict(list))
    for row in doc['micro']:
        grouped[(row['kind'], row['routes'], row['path'])][row['label']].append(row['ns_per_dispatch'])
    for key, rows in grouped.items():
        lines.append(f'| {key[0]} {key[1]}, `{key[2]}` | ' + ' | '.join(
            f'{statistics.median(rows[label]):.2f} ({min(rows[label]):.2f}–{max(rows[label]):.2f})' for label in labels) + ' |')
    lines += ['', 'Single warm-cache builds: seconds / binary KiB; binary size includes debug information.', '',
              '| Fixture | main | Starting branch | Templates |', '| --- | ---: | ---: | ---: |']
    for kind, count in [('literal', 4), ('mixed', 4), ('mixed', 32), ('mixed', 100)]:
        rows = {r['label']: r for r in doc['builds'] if (r['kind'], r['routes']) == (kind, count)}
        lines.append(f'| {kind} {count} | ' + ' | '.join(
            f"{rows[label]['build_seconds']:.2f} / {rows[label]['binary_bytes'] / 1024:.1f}" if rows[label]['passed'] else 'FAILED'
            for label in labels) + ' |')
    lines += ['', f"{len(doc['results'])} valid HTTP samples; {len(doc['failures'])} failed samples; "
              f"{len(doc['micro'])} dispatch samples; {sum(r['checks'] for r in doc['validation']):,} validation requests.", '']
    args.input.with_name('tables.md').write_text('\n'.join(lines))
    args.input.with_name('summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
