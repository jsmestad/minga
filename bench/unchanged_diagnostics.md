# Unchanged diagnostics frame cost

Receipt for [#3488](https://github.com/jsmestad/minga/issues/3488). Decision: **ship**. At 10,000 diagnostics on one URI, an unchanged 20-row cursor or scroll frame did 1.2 to 10.2 million reductions on `main` because the renderer, its context fingerprint and the status bar recopied and re-traversed the whole diagnostic list every frame. With this change the same frames do 0.49 to 2.6 million, a 51% to 79% cut, and the cursor-frame p50 drops from 54.5 ms to 8.9 ms (one resident window) and from 123.7 ms to 19.8 ms (two windows sharing the URI). Frames with no diagnostics are unchanged. Windowed frames now cost the same at 10,000 diagnostics as at none. Resident frames keep one O(D) residual, the resident gutter override list, described below. Retained memory grows by about 1.4 million words at 10,000 diagnostics.

## Reproduce

```sh
MIX_ENV=test mix run bench/unchanged_diagnostics.exs
MIX_ENV=test MINGA_BENCH_DIAG_QUICK=1 mix run bench/unchanged_diagnostics.exs   # D = 0 and 10,000, 20 rows only
```

`MINGA_BENCH_DIAG_LABEL` tags a run and `MINGA_BENCH_DIAG_OUT` chooses its JSON path. The JSON records every sample, the commit, whether `lib/` was dirty, OTP, Elixir, scheduler count and architecture.

Measured on Apple M1, 16 GB, macOS 27.2, Elixir 1.20.5 / OTP 29, `ERL_FLAGS='+S 4:4'`, `MIX_ENV=test`. Baseline is `082783a6e` (`main`); candidate is `1512cba0f`. Both ran the same bench script from clean `lib/` trees. Pair A ran the full matrix, baseline first. Pair B ran the quick matrix, candidate first. Raw samples are in [`unchanged_diagnostics/`](unchanged_diagnostics/) as gzipped JSON.

## Method

Each scenario starts a real Editor generation (Editor, `Renderer.Server`, semantic GUI encoder, `HeadlessPort`) on a 20,000-line Elixir file, publishes D diagnostics spread evenly across the file, parks the cursor at line 10,000 and warms up with 10 frames. A sample is the wall time from the input (or the publish call) to the committed frame, plus the VM-wide `:erlang.statistics(:exact_reductions)` for that interval and the count of `Minga.Diagnostics` reader calls.

| Dimension | Values |
|---|---|
| Diagnostics D | 0, 100, 1,000, 10,000. A viewport of R rows holds about R × D / 20,000 visible matches K. |
| Viewport | 20 and 200 content rows, 160 columns |
| Windows | one, or a vertical split showing the same URI |
| Path | `resident` and `resident_wrapped` use full-document residence, the default for this file. `windowed` and `windowed_wrapped` set `:resident_store_max_lines` to 0, the path files beyond the residence limits take. |
| Frame | `cursor`: 40 frames alternating `j`/`k`. `scroll`: 40 frames alternating `Ctrl-e`/`Ctrl-y`. `publish`: 10 republications of a shifted list of the same size, each followed by its next frame. |

Reductions are the deterministic work counter: the two baseline runs agree within 0.1%, and the two candidate runs within 0.2%, in every shared cell. Wall times move a few percent between runs, more in publication frames, which are bimodal in both builds. Reductions undercount copying out of ETS and garbage collection, so wall time is reported beside them.

Not measured here: keyframe-only frames and folded rows (covered by tests, not by this matrix), physical presentation, and the Swift or Go frontends. The HeadlessPort grid painter is part of every frame in both builds; at 200 rows it dominates the D = 0 cost.

## Steady-state frames

Pair A, cursor frames, every scenario.

| D | Rows | Windows | Path | Frame | Baseline ms p10 / p50 / p90 | Candidate ms p10 / p50 / p90 | Baseline reductions | Candidate reductions | Ratio |
|---:|---:|---:|---|---|---:|---:|---:|---:|---:|
| 0 | 20 | 1 | resident | cursor | 7.4 / 8.9 / 16.1 | 5.1 / 5.2 / 5.7 | 388,826 | 388,638 | 1.00 |
| 0 | 20 | 1 | resident_wrapped | cursor | 13.6 / 14.5 / 15.8 | 10.6 / 10.8 / 11.9 | 716,624 | 716,414 | 1.00 |
| 0 | 20 | 1 | windowed | cursor | 3.9 / 4.4 / 5.2 | 3.1 / 3.3 / 4.1 | 549,255 | 548,741 | 1.00 |
| 0 | 20 | 1 | windowed_wrapped | cursor | 3.5 / 3.7 / 4.3 | 2.9 / 3.1 / 3.7 | 485,840 | 485,826 | 1.00 |
| 0 | 20 | 2 | resident | cursor | 12.3 / 13.1 / 16.9 | 10.7 / 11.3 / 14.1 | 962,104 | 962,013 | 1.00 |
| 0 | 20 | 2 | resident_wrapped | cursor | 37.0 / 42.3 / 48.2 | 31.9 / 36.7 / 40.0 | 1,684,686 | 1,684,041 | 1.00 |
| 0 | 20 | 2 | windowed | cursor | 7.4 / 7.9 / 10.3 | 5.9 / 6.2 / 7.9 | 1,245,817 | 1,244,374 | 1.00 |
| 0 | 20 | 2 | windowed_wrapped | cursor | 5.9 / 6.4 / 7.8 | 4.8 / 4.9 / 5.2 | 909,416 | 909,133 | 1.00 |
| 0 | 200 | 1 | resident | cursor | 74.2 / 80.1 / 88.2 | 62.0 / 63.3 / 72.2 | 7,391,973 | 7,391,721 | 1.00 |
| 0 | 200 | 1 | resident_wrapped | cursor | 86.3 / 91.2 / 107.3 | 68.7 / 72.7 / 78.5 | 8,446,944 | 8,446,473 | 1.00 |
| 0 | 200 | 1 | windowed | cursor | 30.7 / 33.1 / 45.5 | 25.8 / 26.8 / 30.3 | 7,815,530 | 7,813,467 | 1.00 |
| 0 | 200 | 1 | windowed_wrapped | cursor | 36.1 / 39.0 / 48.5 | 29.3 / 30.4 / 40.8 | 8,291,786 | 8,292,505 | 1.00 |
| 0 | 200 | 2 | resident | cursor | 182.6 / 199.4 / 226.5 | 149.8 / 154.8 / 160.2 | 17,025,761 | 17,025,619 | 1.00 |
| 0 | 200 | 2 | resident_wrapped | cursor | 199.1 / 231.9 / 259.2 | 195.8 / 200.6 / 220.9 | 15,075,916 | 15,075,356 | 1.00 |
| 0 | 200 | 2 | windowed | cursor | 59.2 / 61.7 / 84.8 | 58.8 / 60.8 / 87.1 | 17,826,685 | 17,825,821 | 1.00 |
| 0 | 200 | 2 | windowed_wrapped | cursor | 51.5 / 55.1 / 73.0 | 51.4 / 54.0 / 71.8 | 14,447,036 | 14,449,478 | 1.00 |
| 100 | 20 | 1 | resident | cursor | 5.4 / 5.6 / 6.2 | 5.1 / 5.2 / 5.8 | 415,993 | 391,414 | 0.94 |
| 100 | 20 | 1 | resident_wrapped | cursor | 11.1 / 11.5 / 13.1 | 10.8 / 11.0 / 11.9 | 755,013 | 719,127 | 0.95 |
| 100 | 20 | 1 | windowed | cursor | 3.3 / 3.6 / 4.5 | 3.2 / 3.4 / 3.9 | 557,285 | 549,616 | 0.99 |
| 100 | 20 | 1 | windowed_wrapped | cursor | 3.1 / 3.2 / 3.9 | 3.0 / 3.1 / 3.6 | 505,451 | 486,497 | 0.96 |
| 100 | 20 | 2 | resident | cursor | 11.0 / 11.6 / 16.2 | 8.0 / 11.3 / 14.0 | 1,016,968 | 967,717 | 0.95 |
| 100 | 20 | 2 | resident_wrapped | cursor | 34.4 / 38.1 / 41.2 | 34.9 / 37.5 / 40.2 | 1,767,547 | 1,690,182 | 0.96 |
| 100 | 20 | 2 | windowed | cursor | 6.1 / 6.5 / 8.5 | 5.8 / 6.1 / 8.2 | 1,261,250 | 1,245,182 | 0.99 |
| 100 | 20 | 2 | windowed_wrapped | cursor | 5.3 / 5.6 / 7.0 | 4.6 / 5.0 / 6.1 | 945,209 | 909,976 | 0.96 |
| 100 | 200 | 1 | resident | cursor | 98.3 / 120.5 / 157.4 | 61.8 / 62.9 / 71.8 | 7,420,217 | 7,394,964 | 1.00 |
| 100 | 200 | 1 | resident_wrapped | cursor | 70.4 / 72.5 / 89.5 | 69.2 / 71.1 / 85.1 | 8,559,583 | 8,451,179 | 0.99 |
| 100 | 200 | 1 | windowed | cursor | 26.3 / 26.9 / 36.9 | 26.1 / 27.2 / 36.7 | 7,825,295 | 7,814,834 | 1.00 |
| 100 | 200 | 1 | windowed_wrapped | cursor | 30.1 / 31.0 / 42.2 | 29.6 / 30.2 / 41.0 | 8,385,855 | 8,296,165 | 0.99 |
| 100 | 200 | 2 | resident | cursor | 152.9 / 159.2 / 175.9 | 154.1 / 160.2 / 179.3 | 17,081,938 | 17,033,139 | 1.00 |
| 100 | 200 | 2 | resident_wrapped | cursor | 198.1 / 200.4 / 221.4 | 198.6 / 200.5 / 221.4 | 15,305,579 | 15,082,545 | 0.99 |
| 100 | 200 | 2 | windowed | cursor | 59.9 / 62.4 / 87.0 | 59.4 / 61.5 / 84.1 | 17,844,872 | 17,827,382 | 1.00 |
| 100 | 200 | 2 | windowed_wrapped | cursor | 53.2 / 55.1 / 69.5 | 51.8 / 54.1 / 71.7 | 14,637,013 | 14,454,727 | 0.99 |
| 1,000 | 20 | 1 | resident | cursor | 7.0 / 7.2 / 8.0 | 5.5 / 5.6 / 6.2 | 662,053 | 419,795 | 0.63 |
| 1,000 | 20 | 1 | resident_wrapped | cursor | 13.5 / 13.9 / 16.7 | 11.1 / 11.2 / 12.2 | 1,100,438 | 747,578 | 0.68 |
| 1,000 | 20 | 1 | windowed | cursor | 4.5 / 4.9 / 5.5 | 3.1 / 3.3 / 4.2 | 618,322 | 548,748 | 0.89 |
| 1,000 | 20 | 1 | windowed_wrapped | cursor | 5.0 / 5.3 / 5.9 | 2.8 / 3.0 / 3.8 | 668,746 | 485,268 | 0.73 |
| 1,000 | 20 | 2 | resident | cursor | 14.8 / 15.7 / 18.2 | 11.4 / 11.9 / 14.7 | 1,501,422 | 1,024,632 | 0.68 |
| 1,000 | 20 | 2 | resident_wrapped | cursor | 42.3 / 42.8 / 46.1 | 37.1 / 37.8 / 40.5 | 2,510,644 | 1,747,087 | 0.70 |
| 1,000 | 20 | 2 | windowed | cursor | 8.4 / 8.9 / 9.8 | 5.7 / 6.3 / 7.9 | 1,378,384 | 1,243,349 | 0.90 |
| 1,000 | 20 | 2 | windowed_wrapped | cursor | 8.4 / 8.6 / 10.5 | 4.7 / 5.0 / 6.1 | 1,260,902 | 909,757 | 0.72 |
| 1,000 | 200 | 1 | resident | cursor | 64.5 / 65.7 / 75.7 | 63.0 / 63.9 / 73.0 | 7,665,380 | 7,422,061 | 0.97 |
| 1,000 | 200 | 1 | resident_wrapped | cursor | 80.8 / 81.9 / 95.3 | 73.2 / 74.1 / 85.0 | 9,552,841 | 8,477,018 | 0.89 |
| 1,000 | 200 | 1 | windowed | cursor | 27.6 / 28.1 / 38.5 | 26.2 / 27.3 / 37.0 | 7,892,096 | 7,817,266 | 0.99 |
| 1,000 | 200 | 1 | windowed_wrapped | cursor | 37.8 / 40.2 / 51.5 | 29.9 / 31.2 / 41.4 | 9,223,040 | 8,308,340 | 0.90 |
| 1,000 | 200 | 2 | resident | cursor | 154.9 / 159.7 / 181.2 | 152.4 / 154.8 / 185.6 | 17,566,177 | 17,089,106 | 0.97 |
| 1,000 | 200 | 2 | resident_wrapped | cursor | 208.0 / 219.6 / 242.3 | 191.2 / 203.1 / 215.2 | 17,348,200 | 15,139,738 | 0.87 |
| 1,000 | 200 | 2 | windowed | cursor | 62.7 / 65.1 / 87.9 | 59.2 / 61.7 / 83.9 | 17,979,936 | 17,828,568 | 0.99 |
| 1,000 | 200 | 2 | windowed_wrapped | cursor | 67.8 / 69.7 / 92.9 | 52.2 / 54.9 / 74.2 | 16,316,116 | 14,471,983 | 0.89 |
| 10,000 | 20 | 1 | resident | cursor | 50.3 / 54.5 / 58.9 | 7.7 / 8.9 / 10.9 | 3,147,453 | 729,517 | 0.23 |
| 10,000 | 20 | 1 | resident_wrapped | cursor | 60.9 / 69.1 / 76.8 | 12.1 / 14.2 / 16.0 | 4,578,367 | 1,058,656 | 0.23 |
| 10,000 | 20 | 1 | windowed | cursor | 15.3 / 16.4 / 18.7 | 3.1 / 3.3 / 4.0 | 1,243,303 | 551,909 | 0.44 |
| 10,000 | 20 | 1 | windowed_wrapped | cursor | 23.6 / 24.4 / 28.3 | 2.9 / 3.1 / 4.1 | 2,284,373 | 495,817 | 0.22 |
| 10,000 | 20 | 2 | resident | cursor | 120.2 / 123.7 / 133.5 | 15.6 / 19.8 / 23.2 | 6,391,490 | 1,636,916 | 0.26 |
| 10,000 | 20 | 2 | resident_wrapped | cursor | 163.8 / 201.5 / 230.1 | 37.4 / 44.9 / 78.5 | 9,984,730 | 2,360,478 | 0.24 |
| 10,000 | 20 | 2 | windowed | cursor | 29.3 / 31.5 / 34.7 | 5.8 / 6.2 / 8.0 | 2,558,574 | 1,246,881 | 0.49 |
| 10,000 | 20 | 2 | windowed_wrapped | cursor | 44.0 / 45.6 / 52.3 | 4.7 / 5.0 / 6.6 | 4,439,779 | 918,344 | 0.21 |
| 10,000 | 200 | 1 | resident | cursor | 114.7 / 119.0 / 129.4 | 67.8 / 71.7 / 77.8 | 10,150,055 | 7,734,624 | 0.76 |
| 10,000 | 200 | 1 | resident_wrapped | cursor | 202.3 / 208.6 / 233.1 | 77.4 / 94.9 / 106.7 | 19,540,413 | 8,789,444 | 0.45 |
| 10,000 | 200 | 1 | windowed | cursor | 41.4 / 44.3 / 55.1 | 25.9 / 29.0 / 37.3 | 8,584,525 | 7,840,190 | 0.91 |
| 10,000 | 200 | 1 | windowed_wrapped | cursor | 112.5 / 114.9 / 138.3 | 30.4 / 32.3 / 45.3 | 17,586,721 | 8,436,524 | 0.48 |
| 10,000 | 200 | 2 | resident | cursor | 246.7 / 269.4 / 299.2 | 134.4 / 157.1 / 163.6 | 22,458,562 | 17,701,499 | 0.79 |
| 10,000 | 200 | 2 | resident_wrapped | cursor | 461.5 / 500.4 / 546.3 | 169.2 / 194.1 / 229.1 | 37,823,063 | 15,751,698 | 0.42 |
| 10,000 | 200 | 2 | windowed | cursor | 91.3 / 94.7 / 118.4 | 59.5 / 62.2 / 86.5 | 19,336,093 | 17,864,100 | 0.92 |
| 10,000 | 200 | 2 | windowed_wrapped | cursor | 219.1 / 221.5 / 270.3 | 53.1 / 57.5 / 74.9 | 33,130,315 | 14,665,154 | 0.44 |

Pair A, scroll and publish frames at D = 10,000.

| D | Rows | Windows | Path | Frame | Baseline ms p10 / p50 / p90 | Candidate ms p10 / p50 / p90 | Baseline reductions | Candidate reductions | Ratio |
|---:|---:|---:|---|---|---:|---:|---:|---:|---:|
| 10,000 | 20 | 1 | resident | scroll | 56.6 / 60.9 / 63.5 | 11.7 / 14.2 / 17.6 | 3,238,261 | 827,578 | 0.26 |
| 10,000 | 20 | 1 | resident | publish | 703.8 / 1613.5 / 3382.3 | 756.0 / 2874.7 / 3371.4 | 99,335,164 | 97,456,625 | 0.98 |
| 10,000 | 20 | 1 | resident_wrapped | scroll | 70.0 / 78.2 / 90.7 | 20.2 / 29.3 / 31.5 | 4,677,224 | 1,147,652 | 0.25 |
| 10,000 | 20 | 1 | resident_wrapped | publish | 1798.3 / 2867.9 / 5858.4 | 1814.9 / 2103.0 / 6253.8 | 206,814,572 | 203,838,510 | 0.99 |
| 10,000 | 20 | 1 | windowed | scroll | 15.3 / 16.0 / 17.4 | 3.0 / 3.3 / 4.2 | 1,233,763 | 549,503 | 0.45 |
| 10,000 | 20 | 1 | windowed | publish | 65.1 / 69.4 / 89.2 | 68.6 / 70.4 / 98.9 | 3,404,229 | 3,621,296 | 1.06 |
| 10,000 | 20 | 1 | windowed_wrapped | scroll | 23.5 / 24.5 / 27.5 | 2.8 / 3.0 / 3.8 | 2,286,267 | 488,490 | 0.21 |
| 10,000 | 20 | 1 | windowed_wrapped | publish | 74.9 / 80.0 / 102.6 | 70.4 / 73.2 / 83.4 | 4,714,789 | 3,824,024 | 0.81 |
| 10,000 | 20 | 2 | resident | scroll | 127.5 / 132.5 / 140.9 | 23.9 / 26.8 / 31.6 | 6,482,694 | 1,734,713 | 0.27 |
| 10,000 | 20 | 2 | resident | publish | 1659.6 / 1860.2 / 6468.2 | 1633.0 / 1848.9 / 5723.6 | 196,812,391 | 192,242,010 | 0.98 |
| 10,000 | 20 | 2 | resident_wrapped | scroll | 186.3 / 208.9 / 258.1 | 63.7 / 87.5 / 99.5 | 10,189,882 | 2,555,462 | 0.25 |
| 10,000 | 20 | 2 | resident_wrapped | publish | 4276.2 / 5004.5 / 16066.7 | 4334.9 / 5394.0 / 15521.4 | 467,775,892 | 460,317,483 | 0.98 |
| 10,000 | 20 | 2 | windowed | scroll | 28.7 / 29.9 / 34.2 | 5.8 / 6.3 / 8.5 | 2,549,624 | 1,245,164 | 0.49 |
| 10,000 | 20 | 2 | windowed | publish | 98.8 / 105.2 / 118.8 | 85.3 / 92.4 / 105.6 | 4,875,875 | 4,472,724 | 0.92 |
| 10,000 | 20 | 2 | windowed_wrapped | scroll | 49.5 / 50.8 / 56.3 | 4.6 / 4.9 / 6.3 | 4,444,396 | 915,785 | 0.21 |
| 10,000 | 20 | 2 | windowed_wrapped | publish | 122.8 / 126.4 / 143.1 | 92.1 / 100.9 / 117.7 | 7,584,204 | 4,966,343 | 0.65 |
| 10,000 | 200 | 1 | resident | scroll | 124.9 / 126.9 / 139.3 | 77.8 / 78.7 / 89.3 | 10,242,430 | 7,830,123 | 0.76 |
| 10,000 | 200 | 1 | resident | publish | 786.6 / 1748.8 / 3216.9 | 760.8 / 817.7 / 3301.2 | 106,364,716 | 104,489,229 | 0.98 |
| 10,000 | 200 | 1 | resident_wrapped | scroll | 217.3 / 219.3 / 247.4 | 105.7 / 106.6 / 118.1 | 19,639,007 | 8,878,607 | 0.45 |
| 10,000 | 200 | 1 | resident_wrapped | publish | 1921.6 / 3011.3 / 5929.8 | 1855.2 / 3282.9 / 6321.0 | 221,810,314 | 211,604,795 | 0.95 |
| 10,000 | 200 | 1 | windowed | scroll | 41.4 / 44.0 / 54.0 | 25.8 / 28.1 / 29.6 | 8,575,913 | 7,837,267 | 0.91 |
| 10,000 | 200 | 1 | windowed | publish | 99.5 / 101.0 / 132.0 | 98.9 / 104.0 / 133.2 | 11,281,838 | 11,442,638 | 1.01 |
| 10,000 | 200 | 1 | windowed_wrapped | scroll | 112.1 / 115.3 / 139.2 | 30.3 / 31.3 / 38.8 | 17,588,994 | 8,428,617 | 0.48 |
| 10,000 | 200 | 1 | windowed_wrapped | publish | 185.0 / 197.7 / 236.9 | 123.2 / 138.9 / 154.3 | 23,283,312 | 15,029,585 | 0.65 |
| 10,000 | 200 | 2 | resident | scroll | 263.5 / 294.3 / 326.8 | 153.3 / 184.0 / 205.7 | 22,550,170 | 17,800,035 | 0.79 |
| 10,000 | 200 | 2 | resident | publish | 1920.1 / 2143.8 / 6395.6 | 1996.2 / 2125.4 / 6048.4 | 212,936,285 | 208,361,753 | 0.98 |
| 10,000 | 200 | 2 | resident_wrapped | scroll | 488.3 / 509.4 / 543.7 | 217.1 / 240.3 / 266.0 | 38,041,209 | 15,959,583 | 0.42 |
| 10,000 | 200 | 2 | resident_wrapped | publish | 4926.2 / 10220.1 / 16377.9 | 4862.8 / 9240.6 / 15600.2 | 495,653,321 | 473,742,637 | 0.96 |
| 10,000 | 200 | 2 | windowed | scroll | 90.7 / 93.7 / 119.0 | 59.4 / 62.4 / 83.6 | 19,327,298 | 17,861,051 | 0.92 |
| 10,000 | 200 | 2 | windowed | publish | 166.0 / 175.8 / 212.5 | 156.2 / 164.3 / 216.5 | 22,730,129 | 22,165,469 | 0.98 |
| 10,000 | 200 | 2 | windowed_wrapped | scroll | 218.4 / 221.8 / 271.7 | 53.2 / 57.5 / 77.5 | 33,146,424 | 14,671,694 | 0.44 |
| 10,000 | 200 | 2 | windowed_wrapped | publish | 341.8 / 344.9 / 419.4 | 205.7 / 208.1 / 250.1 | 44,599,061 | 27,033,259 | 0.61 |

### Control and run-to-run variation

Pair B repeats the 20-row matrix in the opposite order. At D = 0 the candidate matches the baseline within 0.2% in reductions in both pairs and within run noise in wall time, which is the control: the change adds no cost when there is nothing to recopy.

| D | Rows | Windows | Path | Frame | Baseline ms p10 / p50 / p90 | Candidate ms p10 / p50 / p90 | Baseline reductions | Candidate reductions | Ratio |
|---:|---:|---:|---|---|---:|---:|---:|---:|---:|
| 0 | 20 | 1 | resident | cursor | 5.1 / 5.3 / 6.2 | 5.1 / 5.2 / 5.5 | 388,819 | 388,673 | 1.00 |
| 0 | 20 | 1 | resident | scroll | 6.1 / 7.8 / 9.5 | 6.2 / 7.8 / 9.6 | 485,424 | 485,148 | 1.00 |
| 0 | 20 | 1 | resident | publish | 4.9 / 5.1 / 9.6 | 5.0 / 5.2 / 10.5 | 376,707 | 376,429 | 1.00 |
| 0 | 20 | 1 | resident_wrapped | cursor | 10.6 / 10.8 / 12.0 | 10.7 / 10.9 / 11.9 | 715,970 | 716,414 | 1.00 |
| 0 | 20 | 1 | resident_wrapped | scroll | 12.2 / 13.4 / 15.1 | 12.2 / 13.5 / 14.9 | 814,405 | 814,240 | 1.00 |
| 0 | 20 | 1 | resident_wrapped | publish | 303.1 / 305.2 / 324.2 | 305.8 / 323.8 / 380.8 | 56,168,941 | 56,168,031 | 1.00 |
| 0 | 20 | 1 | windowed | cursor | 3.1 / 3.3 / 4.1 | 3.1 / 3.2 / 3.9 | 549,232 | 548,741 | 1.00 |
| 0 | 20 | 1 | windowed | scroll | 3.0 / 3.2 / 3.9 | 3.1 / 3.2 / 4.0 | 543,652 | 544,031 | 1.00 |
| 0 | 20 | 1 | windowed | publish | 2.9 / 2.9 / 3.4 | 2.9 / 3.2 / 3.8 | 532,866 | 532,630 | 1.00 |
| 0 | 20 | 1 | windowed_wrapped | cursor | 2.9 / 3.1 / 3.7 | 2.9 / 3.1 / 3.8 | 485,592 | 485,762 | 1.00 |
| 0 | 20 | 1 | windowed_wrapped | scroll | 2.9 / 3.2 / 3.8 | 2.9 / 3.0 / 3.6 | 486,399 | 486,088 | 1.00 |
| 0 | 20 | 1 | windowed_wrapped | publish | 2.7 / 3.0 / 3.9 | 2.6 / 2.8 / 3.5 | 467,929 | 467,998 | 1.00 |
| 0 | 20 | 2 | resident | cursor | 10.6 / 11.2 / 13.9 | 10.6 / 11.3 / 13.8 | 962,626 | 962,029 | 1.00 |
| 0 | 20 | 2 | resident | scroll | 15.5 / 19.8 / 24.0 | 15.4 / 19.5 / 23.1 | 1,059,506 | 1,058,691 | 1.00 |
| 0 | 20 | 2 | resident | publish | 10.4 / 10.5 / 10.9 | 10.4 / 10.6 / 11.8 | 950,674 | 949,951 | 1.00 |
| 0 | 20 | 2 | resident_wrapped | cursor | 31.8 / 36.4 / 39.1 | 31.9 / 36.5 / 37.8 | 1,684,436 | 1,683,905 | 1.00 |
| 0 | 20 | 2 | resident_wrapped | scroll | 43.6 / 54.3 / 59.8 | 43.4 / 54.7 / 59.0 | 1,889,276 | 1,888,394 | 1.00 |
| 0 | 20 | 2 | resident_wrapped | publish | 644.8 / 664.3 / 821.8 | 643.5 / 649.8 / 813.4 | 116,259,893 | 116,257,650 | 1.00 |
| 0 | 20 | 2 | windowed | cursor | 5.8 / 6.2 / 7.7 | 5.9 / 6.2 / 7.9 | 1,246,433 | 1,244,328 | 1.00 |
| 0 | 20 | 2 | windowed | scroll | 5.8 / 6.1 / 7.0 | 5.8 / 6.1 / 6.8 | 1,240,620 | 1,238,370 | 1.00 |
| 0 | 20 | 2 | windowed | publish | 5.6 / 5.8 / 6.2 | 5.6 / 5.9 / 8.0 | 1,230,149 | 1,229,049 | 1.00 |
| 0 | 20 | 2 | windowed_wrapped | cursor | 4.8 / 4.9 / 6.4 | 4.7 / 4.9 / 6.3 | 909,317 | 908,827 | 1.00 |
| 0 | 20 | 2 | windowed_wrapped | scroll | 4.7 / 5.0 / 6.3 | 4.7 / 5.0 / 6.1 | 912,334 | 912,483 | 1.00 |
| 0 | 20 | 2 | windowed_wrapped | publish | 5.6 / 5.9 / 7.2 | 5.5 / 5.8 / 7.3 | 1,075,058 | 1,074,530 | 1.00 |
| 10,000 | 20 | 1 | resident | cursor | 50.7 / 53.7 / 58.2 | 7.6 / 8.1 / 10.4 | 3,147,357 | 729,512 | 0.23 |
| 10,000 | 20 | 1 | resident | scroll | 56.1 / 59.5 / 63.6 | 11.5 / 14.1 / 16.7 | 3,238,507 | 827,359 | 0.26 |
| 10,000 | 20 | 1 | resident | publish | 701.3 / 1639.4 / 3148.0 | 767.7 / 1535.7 / 3173.6 | 99,333,531 | 97,457,325 | 0.98 |
| 10,000 | 20 | 1 | resident_wrapped | cursor | 62.1 / 68.7 / 76.1 | 12.1 / 14.2 / 16.0 | 4,578,425 | 1,058,655 | 0.23 |
| 10,000 | 20 | 1 | resident_wrapped | scroll | 68.8 / 76.8 / 83.0 | 20.6 / 29.6 / 31.3 | 4,677,172 | 1,147,765 | 0.25 |
| 10,000 | 20 | 1 | resident_wrapped | publish | 1801.5 / 5091.7 / 5749.1 | 1792.5 / 1928.4 / 6105.5 | 206,818,145 | 203,837,705 | 0.99 |
| 10,000 | 20 | 1 | windowed | cursor | 15.5 / 16.6 / 18.5 | 3.1 / 3.3 / 4.1 | 1,243,184 | 551,907 | 0.44 |
| 10,000 | 20 | 1 | windowed | scroll | 15.1 / 16.4 / 17.9 | 3.1 / 3.2 / 4.3 | 1,233,963 | 549,502 | 0.45 |
| 10,000 | 20 | 1 | windowed | publish | 66.4 / 70.2 / 87.8 | 65.2 / 74.2 / 102.2 | 3,404,086 | 3,621,511 | 1.06 |
| 10,000 | 20 | 1 | windowed_wrapped | cursor | 23.5 / 24.4 / 27.4 | 2.9 / 3.1 / 3.9 | 2,284,744 | 495,058 | 0.22 |
| 10,000 | 20 | 1 | windowed_wrapped | scroll | 23.7 / 24.8 / 27.8 | 2.8 / 3.0 / 3.8 | 2,286,243 | 488,487 | 0.21 |
| 10,000 | 20 | 1 | windowed_wrapped | publish | 75.8 / 79.0 / 98.7 | 69.8 / 84.0 / 88.3 | 4,714,303 | 3,824,141 | 0.81 |
| 10,000 | 20 | 2 | resident | cursor | 121.7 / 124.9 / 132.2 | 15.8 / 19.8 / 22.1 | 6,391,053 | 1,637,758 | 0.26 |
| 10,000 | 20 | 2 | resident | scroll | 129.9 / 133.2 / 138.8 | 24.7 / 27.1 / 33.4 | 6,482,457 | 1,734,829 | 0.27 |
| 10,000 | 20 | 2 | resident | publish | 1649.3 / 1849.3 / 6130.4 | 1779.0 / 1875.3 / 5849.3 | 196,814,501 | 192,240,322 | 0.98 |
| 10,000 | 20 | 2 | resident_wrapped | cursor | 98.0 / 119.8 / 218.8 | 37.5 / 46.2 / 71.1 | 9,984,814 | 2,360,189 | 0.24 |
| 10,000 | 20 | 2 | resident_wrapped | scroll | 188.9 / 210.4 / 253.1 | 63.7 / 90.6 / 97.8 | 10,189,813 | 2,555,564 | 0.25 |
| 10,000 | 20 | 2 | resident_wrapped | publish | 4190.0 / 4760.4 / 16686.9 | 4523.6 / 5505.2 / 16221.2 | 467,775,028 | 460,310,847 | 0.98 |
| 10,000 | 20 | 2 | windowed | cursor | 29.1 / 30.9 / 35.8 | 5.8 / 6.1 / 8.0 | 2,558,638 | 1,247,334 | 0.49 |
| 10,000 | 20 | 2 | windowed | scroll | 28.7 / 30.2 / 34.6 | 5.8 / 6.5 / 8.3 | 2,549,458 | 1,244,935 | 0.49 |
| 10,000 | 20 | 2 | windowed | publish | 98.2 / 103.3 / 117.5 | 87.7 / 93.2 / 104.2 | 4,875,920 | 4,473,187 | 0.92 |
| 10,000 | 20 | 2 | windowed_wrapped | cursor | 44.2 / 46.0 / 52.2 | 4.7 / 4.9 / 6.3 | 4,439,597 | 919,081 | 0.21 |
| 10,000 | 20 | 2 | windowed_wrapped | scroll | 49.2 / 50.6 / 56.3 | 4.6 / 4.8 / 6.3 | 4,443,982 | 915,769 | 0.21 |
| 10,000 | 20 | 2 | windowed_wrapped | publish | 121.2 / 137.4 / 154.9 | 89.6 / 93.3 / 111.3 | 7,585,496 | 4,965,614 | 0.65 |

### Work against visible matches

On windowed paths the candidate's unchanged-frame work depends on K, not D. A single 20-row windowed window does 548,741 reductions at D = 0 and 551,909 at D = 10,000 (K ≈ 10), against 1,243,303 on the baseline. At 200 rows (K ≈ 100) it does 7,840,190 against 7,813,467 at D = 0. The renderer copies one integer per displayed URI per frame for the revision check, queries the line interval index for the visible source lines, and projects only those candidates.

### Resident residual

Resident frames still grow with D: one resident window does 388,638 reductions at D = 0 and 729,517 at D = 10,000, the same 0.34 million extra at 20 and at 200 rows, and about 0.68 million with two windows. A call-time profile attributes it to the resident gutter: `Builder.build_gutter_entries/5` rebuilds the full-document override list from every sign line each frame (`Enum.uniq`, sort, `resolve_gutter_entry/5` × D), and `GUI.Caches.prepare_gutter/4` re-encodes it. That list is part of the resident model and is unchanged by this work; bounding it needs a retained resident gutter keyed by its inputs (diagnostic and git signs, folds, annotations, line count). It is a follow-up, not a regression.

## Publication frames

Publication now does its merge and derivation once, in `Minga.Diagnostics`, instead of lazily on the first renderer read. A publish call for 10,000 diagnostics takes 14.5 ms in the server (baseline: 2.6 ms for the call plus 3.0 ms for the first merged read, paid on the next frame). The renderer then builds the line interval index once per revision (3.5 ms at 10,000).

Publication frames do 0.61 to 1.06 times the baseline's reductions. Every increase is on the unwrapped windowed path and at most 6%; the largest is a single windowed window at D = 10,000, with 3.62 million reductions against 3.40 million and a p50 of 70.4 / 74.2 ms against 69.4 / 70.2 ms in pairs A / B. That is the index build plus the eager derivation. Resident publication frames recompose the full document in both builds because the gutter signs move, and their wall p50 flips between the two modes of a bimodal distribution (for example 1.6 s and 2.9 s in pair A at one resident window) while p10, p90 and reductions agree.

An earlier candidate gave the interval index `make_ref/0` ids. At 10,000 diagnostics, retaining those references raised the renderer's major garbage collections from 8 to 108 across three publication frames and doubled their wall time at equal reductions. The index now uses each diagnostic's published position as its id, and the renderer's collections match the baseline.

## Retained memory

| D | Diagnostics ETS words, baseline | Diagnostics ETS words, candidate | Renderer view words, candidate |
|---:|---:|---:|---:|
| 0 | 1,095 | 1,440 | 0 |
| 100 | 10,130 | 17,162 | 7,285 |
| 1,000 | 91,130 | 160,519 | 72,767 |
| 10,000 | 901,130 | 1,589,965 | 727,749 |

The ETS figure is all `Minga.Diagnostics` tables after the bench's last publication. The baseline holds each source list and a lazily filled merge cache. The candidate holds the source lists, the committed merged list, and one row per diagnostic line so `on_line/3` copies a line instead of the URI. The renderer view (measured with `:erts_debug.size/1`) is the retained merged list, gutter signs and interval index for one displayed URI, shared by all its splits. At 10,000 diagnostics the total is about 1.4 million words (11 MB); at 1,000 it is about 140,000 words (1.1 MB).

## Contracts verified

- `Minga.Diagnostics` is the only writer: its tables are `:protected`, and foreign inserts, deletes and `delete_all_objects` fail without changing published diagnostics.
- Every non-empty publication commits a VM-unique positive revision before the broadcast, including an identical republication. Clearing returns the URI to revision 0 and leaves no per-URI state. Clear-then-republish and a restarted server never reissue a revision a reader holds.
- `changed_since/3` returns `:unchanged` for the known revision; the renderer reuses the identical retained terms, so an unchanged frame copies no diagnostic list.
- Splits showing one file share one view per frame, and a new revision refreshes it.
- Windowed projection from index candidates equals projection from the full list, in published order with duplicates and malformed spans (property test).
- A message-only republication leaves the context fingerprint unchanged; a sign change does not.
- Resident windows carry diagnostics only in their resident semantic layer, which still replaces on hydration and retains on unrelated edits.
- `mix conformance.gen` reproduces the committed corpus with no diff. No field crosses the Editor to Renderer boundary, so `Renderer.Submission` and `RenderReceipt` sizes are unchanged.
