#!/usr/bin/env python3
"""Produce tables and a standalone SVG from the retained measurements."""
import argparse
import collections
import json
import statistics
from pathlib import Path

HERE = Path(__file__).resolve().parent
LABELS = {'main': 'main', 'explicit': 'Explicit routes', 'route': '@Route',
          'methods': '@Get / @Post', 'eclair': 'Eclair'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('--output', type=Path, default=HERE / 'results')
    args = p.parse_args()
    data = json.loads(args.input.read_text())
    groups = collections.defaultdict(list)
    for row in data['results']:
        groups[row['scenario'], row['backend'], row['label']].append(row)
    summary = []
    for (scenario, backend, label), rows in groups.items():
        rates = [r['rps'] for r in rows]
        summary.append(dict(scenario=scenario, backend=backend, label=label, samples=len(rows),
                            median_rps=statistics.median(rates), min_rps=min(rates), max_rps=max(rates),
                            median_p99_us=statistics.median(r['p99_us'] for r in rows),
                            median_final_rss_kib=statistics.median(r['rss_final_kib']['VmRSS'] for r in rows)))
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    table = ['| Workload | Backend | Implementation | Valid runs | Median req/s | Min–max req/s | Median p99 µs | End RSS MiB |',
             '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |']
    for r in summary:
        table.append(f"| {r['scenario']} | {r['backend']} | {LABELS[r['label']]} | {r['samples']} | "
                     f"{r['median_rps']:,.0f} | {r['min_rps']:,.0f}–{r['max_rps']:,.0f} | "
                     f"{r['median_p99_us']:,.0f} | {r['median_final_rss_kib']/1024:.1f} |")
    (args.output / 'tables.md').write_text('\n'.join(table) + '\n')
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print('Tables saved; install matplotlib to regenerate the optional SVG chart.')
        return
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.8))
    for ax, scenario, title in zip(axes, ['small-first-c64', 'medium-last-c64'],
                                  ['4 routes: first route', '32 routes: last route']):
        rows = {r['label']: r for r in summary if r['scenario'] == scenario and r['backend'] == 'epoll'}
        for i, (label, name) in enumerate(LABELS.items()):
            if label not in rows:
                ax.text(0, i, 'No valid run', va='center')
                continue
            row = rows[label]
            value = row['median_rps'] / 1000
            ax.barh(i, value, color='#ba6846' if label == 'eclair' else '#326a91')
            ax.errorbar(value, i, xerr=[[value-row['min_rps']/1000], [row['max_rps']/1000-value]],
                        fmt='none', ecolor='#202020', capsize=3)
            ax.text(value + 5, i, f'{value:.1f}', va='center', fontsize=9)
        ax.set_yticks(range(len(LABELS)), LABELS.values())
        ax.invert_yaxis()
        ax.set_xlabel('Thousands of requests / second')
        ax.set_title(title)
        ax.set_xlim(0, max(r['max_rps']/1000 for r in rows.values()) * 1.23)
        ax.spines[['top', 'right']].set_visible(False)
    fig.suptitle('Five implementations · epoll · one server core · 64 connections', fontsize=13)
    fig.text(.5, .01, f"Median of up to {data['config']['runs']} × {data['config']['seconds']}-second runs; whiskers show min–max, not confidence intervals.\n"
                      'Eclair results apply to repeated identical requests; mixed keep-alive validation failed.',
             ha='center', fontsize=9)
    fig.tight_layout(rect=(0, .08, 1, .94))
    svg = args.output / 'throughput.svg'
    fig.savefig(svg)
    svg.write_text('\n'.join(line.rstrip() for line in svg.read_text().splitlines()) + '\n')
    fig.savefig(args.output / 'throughput.png', dpi=160)
    print(f'Summary and chart saved to {args.output}')


if __name__ == '__main__':
    main()
