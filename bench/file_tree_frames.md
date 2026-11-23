# File-tree frame cost

Receipt for [#3493](https://github.com/jsmestad/minga/issues/3493). Decision: **ship** a per-row cost cut, and **do not** add cross-frame retention of the semantic model in this ticket. Every frame on `main` rebuilds every file-tree row, including frames where nothing in the tree changed and frames where the sidebar is hidden but the tree is loaded. Each file row made four calls to the runtime filetype-override Agent (two detections, icon and color, two calls each), so a 10,000-entry tree cost 40,000 Agent round trips per frame and a 50,000-entry tree 200,000. The candidate reads the override registry once per frame, detects each file once, and expands each path once. It halves the work of every file-tree frame (reductions ratio 0.46 to 0.54 at 10,000 and 50,000 entries, 0.61 to 0.65 at 1,000) and cuts the p50 frame time by 30% to 94% depending on size and frame kind. It keeps no state across frames, so it cannot hide a missing invalidation.

The model is still rebuilt on every frame. Removing that work needs renderer-side retention keyed by every model input, including the filetype and language registries, which have no revision today, and it would still leave the O(N) Editor-to-Renderer copy of the file-tree state. That is an owner and transport change and needs its own accepted design; see [Not shipped](#not-shipped-cross-frame-retention).

## Reproduce

```sh
MIX_ENV=test ERL_FLAGS='+S 4:4' mix run bench/file_tree_frames.exs
MIX_ENV=test MINGA_BENCH_TREE_SIZES=50000 MINGA_BENCH_TREE_PARTS=consumer mix run bench/file_tree_frames.exs
```

`MINGA_BENCH_TREE_LABEL` tags a run, `MINGA_BENCH_TREE_OUT` chooses its JSON path, `MINGA_BENCH_TREE_SIZES` takes a comma list of sizes and `MINGA_BENCH_TREE_PARTS` takes `stages`, `consumer` or both. The JSON records every sample, the commit, whether `lib/` was dirty, OTP, Elixir, scheduler count, architecture and the machine load average when the run finished.

Measured on Apple M1 (MacBook Air, 8 cores, 16 GB), macOS 27.2, Elixir 1.20.5 / OTP 29, `ERL_FLAGS='+S 4:4'`, `MIX_ENV=test`, warm filesystem cache. Baseline is `03fef9aa6` (`main` at `ee23dd518` plus this bench, the headless-frontend decoder fix and the contract tests; `lib/` is identical to `main`). Candidate is `dbe88342b`. Each run checked out the commit, so both builds ran the same bench script from clean `lib/` trees. Raw samples are in [`file_tree_frames/`](file_tree_frames/) as gzipped JSON.

Runs alternated one size at a time. Pair A ran baseline first at each size, pair B candidate first. Pairs C (candidate first) and D (baseline first) repeated the 50,000-entry consumer path. The machine was shared with other BEAM workloads: the load average stayed between 4 and 12 for most runs, reached about 95 during pair A's 50,000-entry baseline and about 40 during pair B's 50,000-entry candidate. Wall time is therefore noisy. Reductions are the deterministic work counter: across all four pairs each build's p50 reductions agree within 0.1% in every shared cell.

## Method

Fixture: N files in leaf directories of 100, 20 directories per package, every directory expanded, ten source extensions and unique file names, plus a 2,000-line `README.md` that is the active buffer. Visible entries: 1,012, 10,106 and 50,526.

Stages run in a fresh process per sample so no sample inherits another's heap: `scan` is `Minga.Project.FileTree.refresh/1` (the filesystem walk), `build` is `FileTreeBuilder.build/1`, `encode_unchanged` is `FileTreeEncoder.encode/2` against warm caches (the unchanged-frame fingerprint) and `encode_full` against empty caches (a full re-send). Ten samples each.

The consumer path starts a real Editor generation (Editor, `Renderer.Server`, semantic GUI encoder, `HeadlessPort`) at 160 by 50, opens the tree on the fixture through `:toggle_file_tree` and expands every directory through the tree's owner API. The headless backend renders synchronously, so a sample covers Editor dispatch, the Editor-to-Renderer copy of the file-tree state, model construction, encoding and the headless frontend's decode. Twenty samples per kind after three warm-up frames:

| Kind | Input | What changes in the tree model |
|---|---|---|
| `unchanged` | `j`/`k` in the editor buffer, tree visible and unfocused | nothing |
| `hidden` | the same keys with the sidebar hidden and the tree loaded | nothing |
| `select` | `j`/`k` in the focused tree | selection only |
| `toggle` | `TAB` on a 100-file leaf directory | 100 rows removed or added |
| `git` | `Freshness.refresh_git_status/2` with 50 modified files, alternating two sets | badges |
| `fs` | a completed refresh adding or removing one file, accepted through `FileTreeState.accept_refresh_result/4` | one row |

The `fs` rescan runs before the sample starts; the `scan` stage measures it separately. Work counters (Rows builds and filetype-registry calls) come from two extra traced frames per kind, so call tracing never inflates the timed samples. GC words is the VM-wide `words_reclaimed` delta per sample, an allocation proxy.

## Consumer path

Pair A.

| Files | Frame | Baseline ms p10 / p50 / p90 | Candidate ms p10 / p50 / p90 | p50 ratio | Baseline reductions | Candidate reductions | Ratio |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1,000 | unchanged | 17.8 / 19.4 / 22.9 | 9.9 / 10.3 / 11.2 | 0.53 | 1,618,978 | 1,032,675 | 0.64 |
| 1,000 | hidden | 17.3 / 18.3 / 25.8 | 8.9 / 9.2 / 9.7 | 0.51 | 1,518,361 | 931,576 | 0.61 |
| 1,000 | select | 18.8 / 20.0 / 39.2 | 9.9 / 10.2 / 11.0 | 0.51 | 1,625,230 | 1,037,906 | 0.64 |
| 1,000 | toggle | 17.2 / 18.7 / 20.1 | 9.3 / 9.7 / 11.8 | 0.52 | 1,623,789 | 1,015,061 | 0.63 |
| 1,000 | git | 23.0 / 24.5 / 62.4 | 13.0 / 13.9 / 25.0 | 0.57 | 1,784,036 | 1,162,318 | 0.65 |
| 1,000 | fs | 17.0 / 17.5 / 23.5 | 10.7 / 11.3 / 11.7 | 0.65 | 1,516,594 | 974,019 | 0.64 |
| 10,000 | unchanged | 312.6 / 328.0 / 378.4 | 173.5 / 192.3 / 234.3 | 0.59 | 12,033,001 | 6,044,540 | 0.50 |
| 10,000 | hidden | 406.3 / 511.9 / 778.7 | 182.1 / 191.5 / 203.8 | 0.37 | 11,360,810 | 5,372,370 | 0.47 |
| 10,000 | select | 356.5 / 402.2 / 635.4 | 153.7 / 168.6 / 202.2 | 0.42 | 12,092,963 | 6,104,568 | 0.50 |
| 10,000 | toggle | 157.3 / 168.2 / 320.7 | 69.9 / 84.9 / 247.4 | 0.50 | 12,019,393 | 6,030,890 | 0.50 |
| 10,000 | git | 435.2 / 544.3 / 1062.6 | 176.9 / 196.4 / 453.3 | 0.36 | 14,567,713 | 7,806,766 | 0.54 |
| 10,000 | fs | 356.5 / 417.3 / 884.2 | 138.1 / 149.4 / 179.8 | 0.36 | 11,946,338 | 6,017,046 | 0.50 |
| 50,000 | unchanged | 2497.2 / 4281.9 / 7611.4 | 357.0 / 1455.4 / 1595.3 | 0.34 | 58,623,962 | 28,533,001 | 0.49 |
| 50,000 | hidden | 1747.9 / 3583.0 / 5420.7 | 296.3 / 1410.6 / 1488.8 | 0.39 | 55,368,544 | 25,277,483 | 0.46 |
| 50,000 | select | 1690.3 / 1798.8 / 2467.1 | 351.9 / 361.1 / 408.3 | 0.20 | 58,922,534 | 28,831,904 | 0.49 |
| 50,000 | toggle | 801.5 / 893.8 / 1712.7 | 380.0 / 391.7 / 615.1 | 0.44 | 58,619,536 | 28,529,448 | 0.49 |
| 50,000 | git | 5650.7 / 9970.6 / 19603.4 | 840.4 / 1933.8 / 3742.6 | 0.19 | 71,672,842 | 37,447,892 | 0.52 |
| 50,000 | fs | 3642.4 / 5356.6 / 12963.4 | 417.7 / 1500.6 / 1627.5 | 0.28 | 58,613,033 | 28,580,959 | 0.49 |

Pair B, opposite order.

| Files | Frame | Baseline ms p10 / p50 / p90 | Candidate ms p10 / p50 / p90 | p50 ratio | Baseline reductions | Candidate reductions | Ratio |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1,000 | unchanged | 17.4 / 18.2 / 24.1 | 10.1 / 10.6 / 11.6 | 0.59 | 1,618,967 | 1,032,636 | 0.64 |
| 1,000 | hidden | 16.5 / 16.8 / 17.6 | 9.1 / 10.1 / 11.6 | 0.60 | 1,518,363 | 937,575 | 0.62 |
| 1,000 | select | 17.3 / 17.6 / 23.6 | 10.7 / 11.3 / 12.8 | 0.64 | 1,625,221 | 1,037,236 | 0.64 |
| 1,000 | toggle | 16.1 / 17.2 / 18.6 | 10.0 / 10.6 / 11.2 | 0.61 | 1,623,808 | 1,014,360 | 0.62 |
| 1,000 | git | 22.3 / 22.9 / 42.4 | 12.1 / 13.0 / 23.3 | 0.57 | 1,785,315 | 1,165,153 | 0.65 |
| 1,000 | fs | 16.4 / 16.9 / 17.7 | 10.9 / 11.7 / 13.8 | 0.70 | 1,516,723 | 974,021 | 0.64 |
| 10,000 | unchanged | 574.5 / 646.1 / 1199.2 | 156.0 / 159.6 / 188.7 | 0.25 | 12,032,993 | 6,044,579 | 0.50 |
| 10,000 | hidden | 298.4 / 326.2 / 425.5 | 147.0 / 149.0 / 158.9 | 0.46 | 11,360,661 | 5,372,370 | 0.47 |
| 10,000 | select | 334.6 / 384.9 / 688.9 | 128.5 / 131.7 / 142.6 | 0.34 | 12,092,730 | 6,104,351 | 0.50 |
| 10,000 | toggle | 147.4 / 197.4 / 264.4 | 62.2 / 69.6 / 157.2 | 0.35 | 12,019,404 | 6,030,882 | 0.50 |
| 10,000 | git | 583.9 / 929.9 / 1652.7 | 257.8 / 366.0 / 541.7 | 0.39 | 14,567,790 | 7,806,866 | 0.54 |
| 10,000 | fs | 512.2 / 653.1 / 1408.0 | 274.1 / 365.5 / 666.5 | 0.56 | 11,946,449 | 6,017,236 | 0.50 |
| 50,000 | unchanged | 4843.6 / 5518.9 / 6765.7 | 406.1 / 1638.9 / 2064.1 | 0.30 | 58,624,342 | 28,533,064 | 0.49 |
| 50,000 | hidden | 3083.2 / 3579.1 / 4410.3 | 307.1 / 1420.0 / 1620.1 | 0.40 | 55,368,688 | 25,277,480 | 0.46 |
| 50,000 | select | 3584.1 / 4630.4 / 6131.8 | 359.7 / 372.0 / 679.9 | 0.08 | 58,923,195 | 28,831,927 | 0.49 |
| 50,000 | toggle | 898.5 / 1225.2 / 10413.1 | 398.0 / 537.6 / 7020.4 | 0.44 | 58,619,661 | 28,529,448 | 0.49 |
| 50,000 | git | 3157.6 / 3203.9 / 7378.7 | 1804.8 / 3674.4 / 4881.1 | 1.15 | 71,670,219 | 37,447,938 | 0.52 |
| 50,000 | fs | 2513.9 / 2700.0 / 4042.7 | 1021.6 / 3259.1 / 6861.6 | 1.21 | 58,612,361 | 28,581,305 | 0.49 |

Pair B's 50,000-entry `git` and `fs` candidate p50 is slower than its baseline while doing half the reductions and allocating 40% fewer words. That run overlapped a load average of about 40 from other work on the machine. Pairs C and D repeated the 50,000-entry consumer path at load averages between 4 and 20:

| Pair | Files | Frame | Baseline ms p10 / p50 / p90 | Candidate ms p10 / p50 / p90 | p50 ratio | Baseline reductions | Candidate reductions | Ratio |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| C | 50,000 | unchanged | 2357.2 / 2592.8 / 2813.6 | 361.6 / 1441.8 / 1534.1 | 0.56 | 58,623,704 | 28,532,989 | 0.49 |
| C | 50,000 | hidden | 1700.8 / 2380.6 / 2478.3 | 312.0 / 1409.7 / 1524.3 | 0.59 | 55,368,190 | 25,277,452 | 0.46 |
| C | 50,000 | select | 1654.2 / 1738.0 / 2160.7 | 358.0 / 363.2 / 419.3 | 0.21 | 58,922,566 | 28,831,901 | 0.49 |
| C | 50,000 | toggle | 788.5 / 823.8 / 1684.0 | 419.7 / 477.7 / 894.2 | 0.58 | 58,618,892 | 28,529,447 | 0.49 |
| C | 50,000 | git | 3185.0 / 3318.3 / 5968.7 | 940.9 / 2179.7 / 3150.9 | 0.66 | 71,670,183 | 37,447,946 | 0.52 |
| C | 50,000 | fs | 2564.7 / 3097.0 / 4030.1 | 501.6 / 1615.2 / 1830.3 | 0.52 | 58,612,468 | 28,581,001 | 0.49 |
| D | 50,000 | unchanged | 2741.6 / 3642.1 / 5818.2 | 377.0 / 1575.3 / 1682.9 | 0.43 | 58,623,939 | 28,532,922 | 0.49 |
| D | 50,000 | hidden | 2313.7 / 5375.5 / 7525.4 | 312.3 / 1474.9 / 1759.6 | 0.27 | 55,368,894 | 25,277,467 | 0.46 |
| D | 50,000 | select | 5328.6 / 6062.9 / 13536.4 | 363.7 / 384.8 / 460.0 | 0.06 | 58,923,583 | 28,832,034 | 0.49 |
| D | 50,000 | toggle | 894.4 / 1143.7 / 5993.3 | 390.9 / 404.1 / 456.0 | 0.35 | 58,619,675 | 28,529,632 | 0.49 |
| D | 50,000 | git | 3106.7 / 3168.4 / 6530.9 | 840.7 / 1933.1 / 3393.0 | 0.61 | 71,670,077 | 37,447,714 | 0.52 |
| D | 50,000 | fs | 2408.4 / 2557.9 / 2730.2 | 429.8 / 1561.5 / 1831.9 | 0.61 | 58,612,207 | 28,581,063 | 0.49 |

In both repeats the candidate is faster in every kind, so pair B's inversion is attributed to contention, not to the change. The candidate's 50,000-entry `unchanged`, `hidden`, `git` and `fs` distributions are bimodal in every pair (p10 near 0.4 s, p50 near 1.5 s). The cause is not attributed here; the reductions per frame are constant across samples, so the spread is not extra work in the changed code. Every candidate p50 in pairs A, C and D is below its paired baseline p50.

## Stages

Pair A. Scan and encode are identical code in both builds; their reductions match and their wall differences are run variation.

| Files | Stage | Baseline ms p10 / p50 / p90 | Candidate ms p10 / p50 / p90 | p50 ratio | Baseline reductions | Candidate reductions | Ratio |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1,000 | scan | 35.7 / 37.2 / 40.4 | 37.4 / 39.2 / 41.3 | 1.06 | 190,155 | 190,156 | 1.00 |
| 1,000 | build | 14.9 / 15.2 / 15.9 | 4.6 / 4.8 / 4.9 | 0.31 | 1,090,848 | 499,397 | 0.46 |
| 1,000 | encode_unchanged | 0.5 / 0.5 / 0.5 | 0.5 / 0.5 / 0.5 | 0.99 | 4,001 | 4,001 | 1.00 |
| 1,000 | encode_full | 4.9 / 5.0 / 5.1 | 5.0 / 5.1 / 5.3 | 1.02 | 399,336 | 399,341 | 1.00 |
| 10,000 | scan | 404.4 / 449.0 / 492.0 | 436.0 / 471.4 / 1106.2 | 1.05 | 1,787,587 | 1,786,255 | 1.00 |
| 10,000 | build | 281.2 / 323.7 / 423.8 | 255.1 / 295.2 / 422.6 | 0.91 | 10,868,948 | 4,881,115 | 0.45 |
| 10,000 | encode_unchanged | 5.1 / 5.5 / 27.7 | 7.7 / 10.0 / 14.0 | 1.81 | 56,006 | 56,006 | 1.00 |
| 10,000 | encode_full | 132.2 / 141.5 / 169.2 | 204.3 / 344.1 / 528.1 | 2.43 | 3,791,613 | 3,791,613 | 1.00 |
| 50,000 | scan | 2750.5 / 2959.0 / 14336.8 | 3945.2 / 5040.7 / 19906.3 | 1.70 | 8,849,204 | 8,860,119 | 1.00 |
| 50,000 | build | 4551.6 / 8000.9 / 12081.9 | 1930.7 / 2261.6 / 2748.2 | 0.28 | 54,645,444 | 24,552,778 | 0.45 |
| 50,000 | encode_unchanged | 38.3 / 40.9 / 42.7 | 49.3 / 51.5 / 55.8 | 1.26 | 286,491 | 286,497 | 1.00 |
| 50,000 | encode_full | 1046.6 / 1181.0 / 1277.2 | 878.2 / 1118.6 / 1625.0 | 0.95 | 18,940,297 | 18,940,298 | 1.00 |

Pair B.

| Files | Stage | Baseline ms p10 / p50 / p90 | Candidate ms p10 / p50 / p90 | p50 ratio | Baseline reductions | Candidate reductions | Ratio |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1,000 | scan | 50.5 / 52.2 / 63.7 | 38.6 / 39.7 / 47.4 | 0.76 | 190,155 | 193,705 | 1.02 |
| 1,000 | build | 18.2 / 19.6 / 24.4 | 5.6 / 5.6 / 7.2 | 0.29 | 1,090,852 | 499,397 | 0.46 |
| 1,000 | encode_unchanged | 0.6 / 0.6 / 0.6 | 0.6 / 0.6 / 0.7 | 0.99 | 4,001 | 4,001 | 1.00 |
| 1,000 | encode_full | 5.5 / 5.9 / 6.3 | 5.9 / 6.1 / 6.8 | 1.03 | 399,336 | 399,336 | 1.00 |
| 10,000 | scan | 577.7 / 677.1 / 2641.2 | 425.6 / 448.9 / 552.4 | 0.66 | 1,786,259 | 1,786,249 | 1.00 |
| 10,000 | build | 299.9 / 552.4 / 1736.0 | 70.8 / 71.7 / 74.0 | 0.13 | 10,869,152 | 4,881,115 | 0.45 |
| 10,000 | encode_unchanged | 13.2 / 16.1 / 25.1 | 5.2 / 5.2 / 5.3 | 0.33 | 56,006 | 56,006 | 1.00 |
| 10,000 | encode_full | 442.6 / 590.3 / 1014.7 | 129.0 / 131.6 / 137.2 | 0.22 | 3,791,817 | 3,791,613 | 1.00 |
| 50,000 | scan | 4287.9 / 5697.0 / 10906.7 | 2638.8 / 2803.1 / 3179.4 | 0.49 | 8,860,319 | 8,859,630 | 1.00 |
| 50,000 | build | 4065.5 / 8317.0 / 15854.0 | 1652.9 / 1696.5 / 1824.1 | 0.20 | 54,645,719 | 24,552,716 | 0.45 |
| 50,000 | encode_unchanged | 104.4 / 107.1 / 116.6 | 37.3 / 38.6 / 82.3 | 0.36 | 286,494 | 286,488 | 1.00 |
| 50,000 | encode_full | 2239.1 / 2470.5 / 2935.7 | 945.1 / 1039.5 / 1168.6 | 0.42 | 18,940,705 | 18,940,297 | 1.00 |

Model construction dominates every frame. At 10,000 entries on `main`, `build` is 10.9 million of the 12.0 million reductions in an unchanged frame. Scanning runs only on refresh, off the frame path, and costs about 0.18 million reductions per 1,000 entries. Encoding an unchanged frame is a 56,000-reduction fingerprint at 10,000 entries; a full re-send is 3.8 million.

## Work counters, sizes and memory

Registry reads count every call into `Minga.Language.Filetype.Registry` during one input, from any caller. The 9 that remain on the candidate come from other chrome (tab bar, status bar, breadcrumb). `toggle` runs four model builds per `TAB` in both builds because the command renders more than once; on `main` its tree buffer sync (`FileTree.BufferSync`) also detected every file again on the Editor process.

| Files | Frame | Row builds B / C | Registry reads B / C | GC words p50 B / C |
|---:|---|---:|---:|---:|
| 1,000 | unchanged | 1 / 2 | 4,012 / 17 | 3,297,855 / 2,125,239 |
| 1,000 | toggle | 4 / 4 | 17,148 / 35 | 3,238,386 / 2,155,369 |
| 1,000 | git | 1 / 1 | 5,414 / 10 | 3,692,996 / 2,454,733 |
| 10,000 | unchanged | 1 / 1 | 40,012 / 9 | 27,776,715 / 16,002,795 |
| 10,000 | hidden | 1 / 1 | 40,012 / 9 | 26,353,787 / 14,582,244 |
| 10,000 | select | 1 / 1 | 40,012 / 9 | 28,054,882 / 16,283,656 |
| 10,000 | toggle | 4 / 4 | 179,148 / 35 | 27,795,447 / 16,217,826 |
| 10,000 | git | 1 / 1 | 59,414 / 10 | 33,939,821 / 20,922,375 |
| 10,000 | fs | 1 / 1 | 39,612 / 9 | 28,281,411 / 16,785,160 |
| 50,000 | unchanged | 1 / 1 | 200,012 / 9 | 137,429,627 / 78,904,944 |
| 50,000 | toggle | 4 / 4 | 899,148 / 35 | 138,878,287 / 79,444,524 |
| 50,000 | git | 1 / 1 | 299,414 / 10 | 167,885,485 / 103,282,134 |

The 1,000-entry candidate `unchanged` row counted two builds because a timer-driven render landed inside its traced window; its timed samples are single frames.

| Files | Entries | File-tree state words (copied Editor to Renderer per frame) | Model words | Full encoded bytes | Editor KB after GC | Renderer KB after GC |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 1,012 | 34,727 | 80,909 | 271,739 | 950 | 4,023 |
| 10,000 | 10,106 | 345,865 | 808,139 | 2,796,245 | 7,811 | 4,023 |
| 50,000 | 50,526 | 1,728,789 | 4,040,439 | 14,380,305 | 40,297 | 4,023 |

Retained memory is identical in both builds in pairs A, B and D (pair C's candidate Editor measured smaller after its collection). The candidate retains nothing new: the registry snapshot and the per-frame filetype list are garbage after the frame. The Renderer keeps only fingerprints of the file tree, so its retained size does not grow with the tree.

## What changed

- `Minga.Language.Filetype.detect_all/1`, exposed as `Minga.Language.detect_filetypes/1`, detects a list of paths with the same priority as `detect/1` (runtime filename override, bundled filename, runtime extension override, bundled extension, `.env` pattern) against one read of the runtime overrides, through `Minga.Language.Filetype.Registry.path_overrides/0`. `detect/1` keeps its per-call lookups and shares the priority chain.
- `FileTreeBuilder` detects every file row once per frame through that batch and derives icon and color from the one result; directories still take icon and color from the folder name.
- `FileTree.BufferSync` builds the tree buffer text with the same batch.
- `FileTree.Rows` expands each entry path once (the row identity is the expanded path), and `FileTree.Row.new/1` no longer filters a `:relative_path` key that no caller passes.

## Required contract

The candidate keeps no state across frames: every frame rebuilds the model from the tree, the buffers, diagnostics, heat levels, the theme and a fresh registry read. The tests below pin each contract item at the consumer boundary. All of them except the `detect_all/1` unit tests also pass on the baseline `lib/` (the control), and two mutations confirmed they fail when behavior breaks (the builder ignoring git status fails the git test; `detect_all/1` ignoring runtime filename overrides fails the runtime-registry test).

| Contract item | Test |
|---|---|
| Unchanged frame sends nothing | `file_tree_frames_test.exs` "an unchanged frame sends nothing and rebuilds an equal model" |
| Full resident data, also when hidden | "every visible entry is resident, including while the sidebar is hidden" |
| Root change | "a root change resends the tree for the new root" |
| Filesystem update, stable identity | "a filesystem update resends the tree and keeps surviving row identities" |
| Expand and collapse | "collapse and expand resend the tree without and then with the children" |
| Selection | "a selection move sends only the selection" |
| Filtering | "filtering resends only the matching rows and clearing restores them" |
| Git status | "a git status change resends the tree with the new badge" |
| Buffer identity | "the active row follows the active buffer", "editing a buffer marks its row dirty on the next frame" |
| Frontend presentation | "a theme change recolors file icons on the next frame", "a width change resends the tree", "moving focus away from the tree reaches the frontend" |
| BEAM-owned icons equal per-path detection | "file icons and colors match per-path filetype detection"; `filetype_test.exs` and `runtime_registry_test.exs` `detect_all/1` |
| Registry changes are not retained | `file_tree_filetype_override_test.exs` |
| Keyboard activation, focus return, refresh after reopen | `integration/file_tree_frames_smoke_test.exs` (actual path through the headless frontend's wire decoder) |
| Mouse activation | existing `handlers/gui_action_handler_test.exs` and `input/` file-tree tests, unchanged and passing |

The actual-path smoke exposed a test-harness defect, fixed in the bench commit: `Minga.Test.HeadlessPort` still decoded the version 3 file-tree payload. Since the version 4 format added a generation field, it silently dropped every full tree and crashed on the first selection-only command, so no Elixir test could observe the file tree on the wire.

## Not shipped: cross-frame retention

The ticket's question was whether unchanged frames repeat model construction. They do, on both builds, once per frame and also while the sidebar is hidden. Retaining the built model in the Renderer would cut the candidate's remaining `build` cost on `unchanged`, `hidden` and `select` frames (about 4.9 million reductions at 10,000 entries, 24.6 million at 50,000). It was not built because:

- A correct retention key must cover the filetype override registry and `Minga.Language.Registry`, which language packs and extensions change at runtime and which carry no revision. Without one, a retained model would show stale icons after a registration: a missing invalidation hidden by a cache.
- The Editor still copies the whole file-tree state to the Renderer every frame (1.7 million words at 50,000 entries), and the encoder still fingerprints every row. Retention in the Renderer removes neither.

The right shape is a revision-qualified file-tree submission, following the Agent transcript and diagnostics precedents (#3888, #3488): the Editor sends the tree only when it changes, the Renderer retains the model keyed by tree revision plus registry revisions, and the encoder compares revisions instead of hashing rows. That changes the Editor-to-Renderer transport and adds registry revisions, so it needs its own accepted design.
