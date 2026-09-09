# Memory and resource measurements

All values are medians across three fresh-process repetitions unless stated otherwise. Memory uses MiB (1,024 KiB); peaks are sampled from smaps every 200 ms.

## Idle and loaded memory by route count

Each cell: **idle RSS / peak loaded RSS / peak loaded USS**, MiB. Loaded = 64 persistent connections. USS is private resident memory.

| Backend / fixture | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| epoll, literal 4 | 6.74 / 6.99 / 4.96 | 6.62 / 6.87 / 4.96 | 6.74 / 6.98 / 4.96 |
| io-uring, literal 4 | 7.08 / 7.33 / 5.36 | 7.08 / 7.32 / 5.36 | 7.09 / 7.34 / 5.36 |
| epoll, mixed 4 | 6.70 / 6.95 / 4.97 | 6.69 / 6.93 / 4.97 | 6.82 / 7.06 / 4.97 |
| io-uring, mixed 4 | 7.09 / 7.34 / 5.37 | 7.03 / 7.27 / 5.36 | 7.09 / 7.34 / 5.37 |
| epoll, mixed 32 | 6.75 / 6.99 / 4.98 | 6.71 / 6.96 / 4.98 | 6.71 / 6.96 / 4.98 |
| io-uring, mixed 32 | 7.16 / 7.40 / 5.38 | 7.11 / 7.35 / 5.38 | 7.16 / 7.40 / 5.38 |
| epoll, mixed 100 | 6.68 / 6.92 / 5.01 | 6.79 / 7.03 / 5.00 | 6.68 / 6.93 / 5.02 |
| io-uring, mixed 100 | 7.06 / 7.31 / 5.40 | 7.18 / 7.43 / 5.40 | 7.13 / 7.38 / 5.42 |

## Reserved virtual memory

Virtual address space, MiB. This is not physical RAM consumption.

| Backend / fixture | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| epoll, literal 4 | 40.46 | 40.46 | 40.46 |
| io-uring, literal 4 | 40.86 | 40.86 | 40.86 |
| epoll, mixed 4 | 40.47 | 40.47 | 40.47 |
| io-uring, mixed 4 | 40.86 | 40.86 | 40.86 |
| epoll, mixed 32 | 40.48 | 40.48 | 40.48 |
| io-uring, mixed 32 | 40.88 | 40.88 | 40.88 |
| epoll, mixed 100 | 40.51 | 40.50 | 40.52 |
| io-uring, mixed 100 | 40.90 | 40.90 | 40.91 |

## Connection scaling and buffer residency

100 mixed routes; a fresh server for each connection trial. Each cell: **RSS / USS**, MiB. Large bodies are 24 KiB per GET request, fully received and validated.

| Backend / phase | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| epoll, before_connections, c=0 | 6.74 / 4.76 | 6.73 / 4.76 | 6.80 / 4.77 |
| epoll, small_requests, c=1 | 6.74 / 4.76 | 6.73 / 4.76 | 6.81 / 4.78 |
| epoll, small_requests, c=64 | 6.98 / 5.01 | 6.98 / 5.00 | 7.05 / 5.02 |
| epoll, small_requests, c=256 | 7.73 / 5.76 | 7.73 / 5.75 | 7.80 / 5.77 |
| epoll, small_requests, c=512 | 8.73 / 6.76 | 8.73 / 6.75 | 8.80 / 6.77 |
| epoll, small_requests, c=1024 | 10.73 / 8.76 | 10.73 / 8.75 | 10.80 / 8.77 |
| epoll, large_bodies, c=1024 | 34.73 / 32.76 | 34.73 / 32.75 | 34.80 / 32.77 |
| epoll, after_close, c=0 | 34.73 / 32.76 | 34.73 / 32.75 | 34.80 / 32.77 |
| epoll, second_large_cycle, c=1024 | 34.73 / 32.76 | 34.73 / 32.75 | 34.80 / 32.77 |
| epoll, after_second_close, c=0 | 34.73 / 32.76 | 34.73 / 32.75 | 34.80 / 32.77 |
| io-uring, before_connections, c=0 | 7.12 / 5.16 | 7.18 / 5.15 | 7.14 / 5.17 |
| io-uring, small_requests, c=1 | 7.12 / 5.16 | 7.18 / 5.15 | 7.14 / 5.18 |
| io-uring, small_requests, c=64 | 7.37 / 5.40 | 7.43 / 5.40 | 7.39 / 5.43 |
| io-uring, small_requests, c=256 | 8.12 / 6.15 | 8.18 / 6.15 | 8.14 / 6.18 |
| io-uring, small_requests, c=512 | 9.12 / 7.15 | 9.18 / 7.15 | 9.14 / 7.18 |
| io-uring, small_requests, c=1024 | 11.12 / 9.15 | 11.18 / 9.15 | 11.14 / 9.18 |
| io-uring, large_bodies, c=1024 | 35.12 / 33.15 | 35.18 / 33.15 | 35.14 / 33.18 |
| io-uring, after_close, c=0 | 35.12 / 33.15 | 35.18 / 33.15 | 35.14 / 33.18 |
| io-uring, second_large_cycle, c=1024 | 35.12 / 33.15 | 35.18 / 33.15 | 35.14 / 33.18 |
| io-uring, after_second_close, c=0 | 35.12 / 33.15 | 35.18 / 33.15 | 35.14 / 33.18 |

## Sustained-request growth

100 mixed routes; 1,000 warmup requests, then 100,000 verified varying requests per repetition. Deltas are end minus warmed start. Ranges include all three repetitions.

| Backend / implementation | Initial USS MiB | Final USS MiB | RSS delta KiB (min–max) | USS delta KiB (min–max) |
| --- | ---: | ---: | ---: | ---: |
| epoll, main | 5.01 | 5.01 | 0 (0–0) | 0 (0–0) |
| epoll, Starting branch | 5.00 | 5.00 | 0 (0–0) | 0 (0–0) |
| epoll, Templates | 5.02 | 5.02 | 0 (0–0) | 0 (0–0) |
| io-uring, main | 5.40 | 5.40 | 0 (0–0) | 0 (0–0) |
| io-uring, Starting branch | 5.40 | 5.40 | 0 (0–0) | 0 (0–0) |
| io-uring, Templates | 5.42 | 5.42 | 0 (0–0) | 0 (0–0) |

## CPU consumption under load

Server process CPU microseconds per completed request. Includes userspace and charged system CPU time; excludes the load generator and kernel work charged elsewhere. Tick resolution is 10 ms on this host.

| Backend / fixture | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| epoll, literal 4 | 2.402 | 2.358 | 2.375 |
| io-uring, literal 4 | 1.740 | 1.732 | 1.725 |
| epoll, mixed 4 | 2.515 | 2.480 | 2.496 |
| io-uring, mixed 4 | 1.741 | 1.755 | 1.762 |
| epoll, mixed 32 | 2.527 | 2.511 | 2.510 |
| io-uring, mixed 32 | 1.788 | 1.745 | 1.786 |
| epoll, mixed 100 | 2.568 | 2.526 | 2.538 |
| io-uring, mixed 100 | 1.774 | 1.779 | 1.832 |

72 completed runs, 0 failed runs; 63,674,485 measured load requests; 1,800,000 verified growth-probe requests.

Raw snapshots also retain PSS, shared/anonymous pages, swap, process high-water marks, minor/major faults, context switches, FD/socket counts, CPU ticks, binary hashes, and wrk output.
