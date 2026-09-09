#!/usr/bin/env python3
"""Summarize measured memory/resource samples; optionally draw a standalone SVG."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics

LABELS = ['main', 'current', 'templates']
NAMES = {'main': 'main', 'current': 'Starting branch', 'templates': 'Templates'}


def med(rows, getter):
    return statistics.median(getter(r) for r in rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path, nargs='?', default=Path(__file__).with_name('memory-results.json'))
    p.add_argument('--plot', action='store_true')
    args = p.parse_args()
    doc = json.loads(args.input.read_text())
    labels = doc['config']['labels']
    grouped = defaultdict(lambda: defaultdict(list))
    for row in doc['results']:
        grouped[(row['backend'], row['kind'], row['routes'])][row['label']].append(row)
    lines = ['# Memory and resource measurements', '',
             'All values are medians across three fresh-process repetitions unless stated otherwise. '
             'Memory uses MiB (1,024 KiB); peaks are sampled from smaps every 200 ms.', '',
             '## Idle and loaded memory by route count', '',
             'Each cell: **idle RSS / peak loaded RSS / peak loaded USS**, MiB. '
             'Loaded = 64 persistent connections. USS is private resident memory.', '',
             '| Backend / fixture | main | Starting branch | Templates |',
             '| --- | ---: | ---: | ---: |']
    summary = []
    for key, impls in grouped.items():
        cells = []
        for label in labels:
            rows = impls[label]
            values = dict(backend=key[0], kind=key[1], routes=key[2], label=label,
                idle_rss_kib=med(rows, lambda r:r['idle']['rss_kib']),
                idle_pss_kib=med(rows, lambda r:r['idle']['pss_kib']),
                idle_uss_kib=med(rows, lambda r:r['idle']['uss_kib']),
                load_peak_rss_kib=med(rows, lambda r:max(s['rss_kib'] for s in r['load']['samples'])),
                load_peak_uss_kib=med(rows, lambda r:max(s['uss_kib'] for s in r['load']['samples'])),
                virtual_kib=med(rows, lambda r:r['idle']['virtual_kib']),
                cpu_us_per_request=med(rows, lambda r:r['load']['cpu_us_per_request']),
                load_cpu_percent=med(rows, lambda r:r['load']['cpu_percent']),
                min_idle_rss_kib=min(r['idle']['rss_kib'] for r in rows),
                max_idle_rss_kib=max(r['idle']['rss_kib'] for r in rows),
                min_load_peak_rss_kib=min(max(s['rss_kib'] for s in r['load']['samples']) for r in rows),
                max_load_peak_rss_kib=max(max(s['rss_kib'] for s in r['load']['samples']) for r in rows))
            summary.append(values)
            cells.append(' / '.join(f'{values[k]/1024:.2f}' for k in ['idle_rss_kib','load_peak_rss_kib','load_peak_uss_kib']))
        lines.append(f'| {key[0]}, {key[1]} {key[2]} | ' + ' | '.join(cells) + ' |')
    lines += ['', '## Reserved virtual memory', '',
              'Virtual address space, MiB. This is not physical RAM consumption.', '',
              '| Backend / fixture | main | Starting branch | Templates |', '| --- | ---: | ---: | ---: |']
    for key, impls in grouped.items():
        lines.append(f'| {key[0]}, {key[1]} {key[2]} | ' + ' | '.join(
            f"{med(impls[label],lambda r:r['idle']['virtual_kib'])/1024:.2f}" for label in labels) + ' |')
    details = {backend: grouped[(backend, 'mixed', 100)] for backend in doc['config']['backends'] if (backend, 'mixed', 100) in grouped}
    lines += ['', '## Connection scaling and buffer residency', '',
              '100 mixed routes; a fresh server for each connection trial. Each cell: **RSS / USS**, MiB. '
              'Large bodies are 24 KiB per GET request, fully received and validated.', '',
              '| Backend / phase | main | Starting branch | Templates |', '| --- | ---: | ---: | ---: |']
    for backend, impls in details.items():
        phases = [(r['phase'],r['connections']) for r in impls[labels[0]][0]['connections']]
        for phase, connections in phases:
            cells = []
            for label in labels:
                snapshots = [next(s for s in r['connections'] if (s['phase'],s['connections']) == (phase,connections)) for r in impls[label]]
                cells.append(' / '.join(f'{med(snapshots,lambda s:s[k])/1024:.2f}' for k in ['rss_kib','uss_kib']))
            lines.append(f'| {backend}, {phase}, c={connections} | ' + ' | '.join(cells) + ' |')
    lines += ['', '## Sustained-request growth', '',
              '100 mixed routes; 1,000 warmup requests, then 100,000 verified varying requests per repetition. '
              'Deltas are end minus warmed start. Ranges include all three repetitions.', '',
              '| Backend / implementation | Initial USS MiB | Final USS MiB | RSS delta KiB (min–max) | USS delta KiB (min–max) |',
              '| --- | ---: | ---: | ---: | ---: |']
    for backend, impls in details.items():
        for label in labels:
            rows = impls[label]
            cells = [f"{med(rows,lambda r:r['growth']['samples'][i]['uss_kib'])/1024:.2f}" for i in [0,-1]]
            for metric in ['rss_kib','uss_kib']:
                deltas = [r['growth']['samples'][-1][metric]-r['growth']['samples'][0][metric] for r in rows]
                cells.append(f'{statistics.median(deltas):.0f} ({min(deltas)}–{max(deltas)})')
            lines.append(f'| {backend}, {NAMES[label]} | ' + ' | '.join(cells) + ' |')
    lines += ['', '## CPU consumption under load', '',
              'Server process CPU microseconds per completed request. Includes userspace and charged system CPU time; '
              'excludes the load generator and kernel work charged elsewhere. Tick resolution is 10 ms on this host.', '',
              '| Backend / fixture | main | Starting branch | Templates |', '| --- | ---: | ---: | ---: |']
    for key, impls in grouped.items():
        lines.append(f'| {key[0]}, {key[1]} {key[2]} | ' + ' | '.join(
            f"{med(impls[label],lambda r:r['load']['cpu_us_per_request']):.3f}" for label in labels) + ' |')
    lines += ['', f"{len(doc['results'])} completed runs, {len(doc['failures'])} failed runs; "
              f"{sum(r['load']['requests'] for r in doc['results']):,} measured load requests; "
              f"{sum(r.get('growth',{}).get('verified_requests',0) for r in doc['results']):,} verified growth-probe requests.", '',
              'Raw snapshots also retain PSS, shared/anonymous pages, swap, process high-water marks, '
              'minor/major faults, context switches, FD/socket counts, CPU ticks, binary hashes, and wrk output.', '']
    args.input.with_name('memory-tables.md').write_text('\n'.join(lines))
    args.input.with_name('memory-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('\n'.join(lines))
    if args.plot and details:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        fig, axes = plt.subplots(1, len(details), figsize=(12,4.5), sharey=True, squeeze=False)
        phases = [('idle',None),('load',None),('small_requests',1024),('large_bodies',1024),('after_close',0)]
        for ax, (backend, impls) in zip(axes[0],details.items()):
            for index,label in enumerate(labels):
                values=[]
                for phase,count in phases:
                    if phase=='idle': value=med(impls[label],lambda r:r['idle']['rss_kib'])
                    elif phase=='load': value=med(impls[label],lambda r:max(s['rss_kib'] for s in r['load']['samples']))
                    else: value=med(impls[label],lambda r:next(s['rss_kib'] for s in r['connections'] if s['phase']==phase and s['connections']==count))
                    values.append(value/1024)
                ax.bar([x+(index-1)*.24 for x in range(len(phases))],values,width=.24,label=NAMES[label])
            ax.set_title(backend)
            ax.set_xticks(range(5),['Idle','Load\n64 conns','1,024\nsmall','1,024\n24 KiB','After\nclose'])
            ax.set_axisbelow(True)
            ax.grid(axis='y',alpha=.2)
        axes[0,0].set_ylabel('Resident memory (MiB)')
        axes[0,-1].legend(frameon=False)
        fig.suptitle('100 routes: connection buffers dominate resident memory')
        fig.tight_layout()
        chart = args.input.with_name('memory.svg')
        fig.savefig(chart)
        chart.write_text('\n'.join(line.rstrip() for line in chart.read_text().splitlines()) + '\n')


if __name__=='__main__':
    main()
