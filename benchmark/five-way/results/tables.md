| Workload | Backend | Implementation | Valid runs | Median req/s | Min–max req/s | Median p99 µs | End RSS MiB |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| small-first-c2 | epoll | main | 5 | 155,553 | 154,049–156,474 | 17 | 6.7 |
| small-first-c2 | epoll | Explicit routes | 5 | 157,732 | 156,137–158,694 | 16 | 6.7 |
| small-first-c2 | epoll | @Route | 5 | 155,066 | 154,081–157,532 | 17 | 6.7 |
| small-first-c2 | epoll | @Get / @Post | 5 | 156,087 | 155,967–158,124 | 16 | 6.7 |
| small-first-c2 | epoll | Eclair | 5 | 20,930 | 20,510–21,735 | 228 | 45.4 |
| small-first-c64 | epoll | main | 5 | 267,816 | 265,980–272,139 | 357 | 6.9 |
| small-first-c64 | epoll | Explicit routes | 5 | 268,387 | 266,303–271,325 | 361 | 6.9 |
| small-first-c64 | epoll | @Route | 5 | 269,123 | 266,021–272,406 | 358 | 7.0 |
| small-first-c64 | epoll | @Get / @Post | 5 | 266,674 | 264,520–271,099 | 368 | 6.9 |
| small-first-c64 | epoll | Eclair | 5 | 66,123 | 65,795–66,261 | 2,130 | 155.2 |
| small-first-c64 | io-uring | main | 5 | 341,446 | 335,960–342,207 | 218 | 7.4 |
| small-first-c64 | io-uring | Explicit routes | 5 | 338,744 | 338,197–340,294 | 224 | 7.4 |
| small-first-c64 | io-uring | @Route | 5 | 338,642 | 337,214–342,071 | 224 | 7.3 |
| small-first-c64 | io-uring | @Get / @Post | 5 | 339,209 | 335,563–339,765 | 239 | 7.4 |
| small-post-c64 | epoll | main | 5 | 260,216 | 255,693–262,472 | 368 | 6.9 |
| small-post-c64 | epoll | Explicit routes | 5 | 261,702 | 257,563–262,825 | 364 | 6.9 |
| small-post-c64 | epoll | @Route | 5 | 260,771 | 258,039–261,898 | 364 | 6.9 |
| small-post-c64 | epoll | @Get / @Post | 5 | 261,999 | 260,100–262,089 | 366 | 6.9 |
| small-post-c64 | epoll | Eclair | 5 | 47,068 | 46,611–47,164 | 2,540 | 123.7 |
| medium-last-c64 | epoll | main | 5 | 267,743 | 263,271–268,821 | 778 | 6.9 |
| medium-last-c64 | epoll | Explicit routes | 5 | 268,578 | 266,859–270,477 | 542 | 6.9 |
| medium-last-c64 | epoll | @Route | 5 | 269,350 | 265,796–270,859 | 707 | 6.9 |
| medium-last-c64 | epoll | @Get / @Post | 5 | 267,692 | 265,989–270,608 | 796 | 6.9 |
| medium-last-c64 | epoll | Eclair | 5 | 60,965 | 59,748–61,092 | 2,070 | 1262.5 |
| large-last-c64 | epoll | main | 5 | 267,792 | 264,544–269,463 | 540 | 6.9 |
| large-last-c64 | epoll | Explicit routes | 5 | 267,654 | 264,253–270,945 | 656 | 6.9 |
