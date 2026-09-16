# Issue #3309 transcript rendering benchmark

The committed benchmark `BenchmarkTranscriptWarmUpdateView` seeds a valid 80x30 production frame, scrolls away from the bottom, warms one empty delta, and measures subsequent empty-delta `Model.Update` plus `View().Content` calls. Full replacement setup remains outside the timed region because installing the payload's semantic records is distinct from layout work. `BenchmarkTranscriptPinnedWarmUpdateView` measures the existing followed-bottom path at 10,000 messages.

Both revisions used Go 1.26.4 on darwin/arm64, Apple M1, normal optimized `go test` builds, 30 warmed samples, and one timed Update+View per sample:

```sh
go test ./internal/ui -run '^$' -bench '^BenchmarkTranscriptWarmUpdateView$' -benchmem -benchtime=1x -count=30
go test ./internal/ui -run '^$' -bench '^BenchmarkTranscriptPinnedWarmUpdateView$' -benchmem -benchtime=1x -count=30
```

Base is `407af47f7d5698ae02b8e96581a040b1a227d0f5`. Head is the issue branch working tree after the bounded renderer change.

| Position | Messages | Revision | Mean | p50 | p95 | Mean bytes/op | Mean allocs/op |
|---|---:|---|---:|---:|---:|---:|---:|
| Unpinned | 100 | base | 9.897 ms | 9.522 ms | 12.128 ms | 2,222,575 | 100,524 |
| Unpinned | 100 | head | 3.128 ms | 2.751 ms | 5.241 ms | 920,739 | 28,708 |
| Unpinned | 1,000 | base | 74.822 ms | 74.608 ms | 77.377 ms | 15,009,079 | 789,997 |
| Unpinned | 1,000 | head | 3.098 ms | 3.040 ms | 3.350 ms | 963,142 | 28,718 |
| Unpinned | 10,000 | base | 731.045 ms | 722.092 ms | 786.460 ms | 139,672,180 | 7,684,079 |
| Unpinned | 10,000 | head | 2.864 ms | 2.835 ms | 3.010 ms | 920,752 | 28,709 |
| Pinned | 10,000 | base | 4.278 ms | 3.653 ms | 6.665 ms | 936,265 | 30,048 |
| Pinned | 10,000 | head | 3.082 ms | 2.865 ms | 4.747 ms | 921,385 | 28,711 |

The 10,000-message unpinned mean improved by 255x. Pinned p95 improved by 28.8%, pinned mean allocations fell by 4.4%, and both stay inside the 10% non-regression limit. The four adjacent text files contain the raw `go test` output.
