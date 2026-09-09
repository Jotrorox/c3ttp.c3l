# Measured results

HTTP: median requests/second (observed min–max), 64 connections.

| Fixture / target / backend | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| literal 4, `/health`, epoll | 268,923 (263,765–275,080) | 267,539 (265,522–271,062) | 268,735 (260,977–269,560) |
| mixed 4, `/health`, epoll | 259,556 (249,587–262,432) | 254,943 (247,588–259,700) | 257,335 (225,628–260,498) |
| mixed 4, `/get-number-back/5`, epoll | 263,043 (257,988–263,894) | 260,609 (258,487–263,864) | 262,692 (256,772–265,143) |
| mixed 4, `/get-number-back/5`, io-uring | 336,405 (335,301–337,730) | 337,313 (332,417–337,929) | 334,298 (331,182–336,037) |
| mixed 4, `/users/alice/posts/42`, epoll | 262,863 (250,301–265,143) | 263,083 (251,182–264,867) | 259,830 (251,695–266,598) |
| mixed 32, `/route/028/5`, epoll | 260,115 (252,931–262,029) | 256,171 (250,567–261,572) | 256,872 (254,273–261,966) |

Median of per-run p99 latency, microseconds (not an aggregate percentile).

| Fixture / target / backend | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| literal 4, `/health`, epoll | 356.0 | 354.0 | 359.0 |
| mixed 4, `/health`, epoll | 794.0 | 1,030.0 | 960.0 |
| mixed 4, `/get-number-back/5`, epoll | 369.0 | 369.0 | 369.0 |
| mixed 4, `/get-number-back/5`, io-uring | 226.0 | 219.0 | 229.0 |
| mixed 4, `/users/alice/posts/42`, epoll | 361.0 | 363.0 | 380.0 |
| mixed 32, `/route/028/5`, epoll | 373.0 | 397.0 | 373.0 |

Dispatch-only: median nanoseconds/call (observed min–max); includes the common non-inlined callback wrapper and checksum.

| Fixture / target | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| literal 4, `/health` | 2.23 (2.21–2.23) | 2.28 (2.25–2.29) | 2.21 (2.21–2.23) |
| mixed 4, `/health` | 2.28 (2.27–2.31) | 3.72 (3.71–3.79) | 2.47 (2.47–2.50) |
| mixed 4, `/get-number-back/5` | 5.50 (5.46–5.52) | 4.00 (3.98–4.01) | 4.61 (4.51–4.87) |
| mixed 4, `/users/alice/posts/42` | 7.80 (7.72–7.90) | 7.15 (7.08–7.24) | 10.23 (10.06–10.45) |
| mixed 32, `/route/028/5` | 41.08 (40.71–41.49) | 40.73 (40.51–40.87) | 42.93 (42.74–43.40) |
| mixed 32, `/route/028/5/extra` | 40.87 (40.68–41.32) | 40.89 (40.86–41.08) | 41.62 (41.49–43.49) |

Single warm-cache builds: seconds / binary KiB; binary size includes debug information.

| Fixture | main | Starting branch | Templates |
| --- | ---: | ---: | ---: |
| literal 4 | 2.26 / 552.8 | 2.18 / 554.9 | 2.28 / 555.3 |
| mixed 4 | 2.26 / 562.1 | 2.21 / 563.5 | 2.25 / 561.6 |
| mixed 32 | 2.45 / 598.9 | 2.55 / 596.0 | 2.58 / 603.5 |
| mixed 100 | 3.23 / 701.9 | 3.35 / 684.0 | 3.66 / 699.1 |

90 valid HTTP samples; 0 failed samples; 90 dispatch samples; 129,930 validation requests.
