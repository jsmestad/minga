# Batch range replacements

Receipt for [#3500](https://github.com/jsmestad/minga/issues/3500), part of [#3501](https://github.com/jsmestad/minga/issues/3501). Decision: **ship**. `Minga.Buffer.apply_edits/3` applied each edit of a batch by copying, re-indexing, and splitting the whole document, so a batch of `k` edits on an `n`-byte document cost `k` full traversals. The candidate applies each run of separated edits in one pass and keeps every observable result of the sequential algorithm. A 1,000-edit rename takes 2.2 ms instead of 1.2 s on a 1 MiB document and 33 ms instead of 28 s on a 16 MiB document. Batches that the candidate cannot plan, and single edits, cost the same as before.

## What changed

`Minga.Buffer.Operation.replace_ranges_with_patches/2` still sorts the batch by start position, highest first, and still defines each edit's meaning against the document the previous edit produced. `Minga.Buffer.RangeBatch.apply_run/3` takes the longest leading run of edits whose sequential result it can reproduce from one snapshot, and assembles that run in one pass. An edit joins the run only when all of these hold:

- Its span ends strictly below the span of the edit applied before it, so every byte it reads is original text.
- Both positions name existing lines, and the caret column is within its line.
- Its span starts and ends on code point boundaries, and its replacement is valid UTF-8.
- After the span is deleted, the caret is still a grapheme boundary, so the sequential operation would insert at the span start. ASCII on both sides of the caret is always a boundary; anything else asks `Cursor.caret_boundary?/2` about exactly the text that `Cursor.place/2` reads.

Any other edit applies on its own with the previous code path, reusing the snapshot the run planner already took. Runs also require the document to be valid UTF-8, checked once per batch and tracked through edits applied on their own, because runs skip grapheme scans that can raise on invalid text. A batch of one edit takes the previous path directly.

Positions still resolve through `Selection`, carets through `Cursor`, and the cursor after an insert through `Document`. The new owner helpers are `Selection.characterwise_in/3`, `Document.position_after_insert/2`, and `UndoPatch.replacement/4`. There is no second coordinate authority, no compatibility shim, and no character-by-character reconstruction. The Buffer process code is unchanged: one writer, one version bump, one undo entry, and no incremental delta (consumers resynchronize).

The LSP and agent workspace-edit path was already a single pass. `Minga.LSP.TextEdit.apply/3` assembles the new content once and `replace_content_if_version/4` installs it, so this change does not touch it.

## Contract checks

`Minga.Test.SequentialRangeReplace` (test support) is the pre-change algorithm, kept verbatim as the control. Every check below compares content, cursor, line index, and undo patches with it.

| Check | Where | What it proves |
|---|---|---|
| 21 recorded current-behavior cases | `test/minga/buffer/range_batch_test.exs` | Unsorted input, equal endpoints (an inclusive one-character range, not a zero-width insert), end-of-file insertion, repeated starts, overlap, adjacency, reversed ranges, lines and columns past the end, CRLF as one character, combining marks, a column inside a code point, emoji, multi-line replacements, deleted line breaks, an empty document, a line created by an earlier edit, a prepended mark, and invalid UTF-8 text. Each row also equals the control. |
| Three properties (1,500 + 500 + 1,000 runs per test run) | same | Random batches over Unicode, CRLF, combining marks, regional indicators, ZWJ sequences, Hangul jamo, and a prepended mark; separated batches at grapheme stops; dense batches at code point stops with endpoints past the last line. Where the control raises (positions inside a code point), the candidate raises the same exception. Six seeds at 20 times the run count also passed. |
| `apply_run/3` run boundaries | same | Separated ASCII edits form one run; an overlapping edit ends the run; a column past its line, and a deletion that joins a Hangul syllable, stay sequential. |
| Buffer consumer path | `test/minga/buffer/process_test.exs`, `apply_edits/3 batch contract` | A 203-edit Unicode and CRLF batch with an overlapping pair and a line past the end: content and cursor equal the control, the version bumps once, the buffer is dirty, one undo restores the original content and cursor, one redo restores the edited content and cursor, and delta consumers get `:reset_required`. |

Each eligibility condition was removed in turn (six mutations), and each removal failed at least one of these tests.

Error behavior is unchanged. `apply_edits/3` returns `:ok` or `{:error, :read_only}`; malformed edits still raise `FunctionClauseError` inside the Buffer process. The candidate sends any edit it cannot validate to the previous code path, which raises as before.

## Method

`bench/batch_replacements.exs`, run as `MIX_ENV=test mix run bench/batch_replacements.exs MODE OUT_DIR`.

- **Fixtures.** Elixir-shaped source lines of 60 to 73 bytes, filled with whole lines to 1 MiB (15,747 lines, 1,048,576 bytes) and 16 MiB (242,849 lines, 16,777,210 bytes). Each edit renames the identifier at columns 6 to 12 on one line. Batches of 1, 10, 1,000, and 10,000 edits on consecutive lines at the start, middle, or end of the file. Boundary cases use 1 MiB and 1,000 edits in the middle unless named otherwise; the script defines each one.
- **Stage mode.** Each sample runs the sequential control and the production operation in fresh processes, in alternating order, from the same fixture, and fails the run unless both results match. Samples continue up to 15, or until the cell has used 20 s after at least one sample. Wall time is from `System.monotonic_time`; reductions are the sample process's own reductions, a deterministic work count.
- **Consumer mode.** A started `Minga.Buffer.Process`, timing the `apply_edits` call, then one undo and one redo (batches up to 1,000 edits), each sent as the public function's message without its 5 s call timeout. Up to 5 samples per cell. Each sample checks content, cursor, version, undo, and redo. Run once on the baseline commit and once on the candidate commit.
- **Build and machine.** `MIX_ENV=test` for both commits. Apple M1, 8 cores, 16 GB, macOS 27.2, Elixir 1.20.5, OTP 29. Baseline commit `082783a6ea5441cb5bd9425ef892797eca215004`; candidate commit `e697bd861206f75bfe284c13b3d26f413638b900`, with no uncommitted `lib/` changes during any run. Raw samples, summaries, and identities are in `bench/batch_replacements/`.

Percentiles are nearest-rank. Cells with one or two samples are sequential samples that take 10 s to 4.5 min each; their candidate samples are in the same cell.

## Results: stage

All times in milliseconds.

| Workload | Edits | n | Sequential p10 / p50 / p90 / p95 (ms) | Candidate p10 / p50 / p90 / p95 (ms) | p50 ratio | Reductions p50: sequential / candidate |
|---|---:|---:|---|---|---:|---|
| `1MiB/1/start` | 1 | 15 | 1.00 / 1.14 / 1.36 / 6.59 | 1.03 / 1.22 / 1.30 / 1.34 | 0.93x | 72,521 / 72,658 |
| `1MiB/1/middle` | 1 | 15 | 1.08 / 1.33 / 1.44 / 1.47 | 1.07 / 1.25 / 1.54 / 1.60 | 1.07x | 73,108 / 73,065 |
| `1MiB/1/eof` | 1 | 15 | 1.16 / 1.26 / 1.44 / 1.49 | 0.97 / 1.11 / 1.38 / 1.46 | 1.13x | 73,578 / 73,587 |
| `1MiB/10/start` | 10 | 15 | 12.2 / 12.8 / 13.5 / 13.6 | 1.16 / 1.30 / 1.79 / 3.70 | 9.80x | 1,151,673 / 76,333 |
| `1MiB/10/middle` | 10 | 15 | 12.5 / 13.1 / 14.5 / 14.6 | 1.28 / 1.41 / 1.55 / 1.55 | 9.27x | 1,156,712 / 76,841 |
| `1MiB/10/eof` | 10 | 15 | 12.0 / 12.7 / 13.5 / 14.6 | 1.31 / 1.41 / 1.56 / 1.61 | 8.96x | 1,155,692 / 77,324 |
| `1MiB/1000/start` | 1000 | 15 | 1,183 / 1,216 / 1,289 / 1,335 | 1.96 / 2.19 / 2.39 / 2.62 | 556.60x | 119,020,684 / 151,732 |
| `1MiB/1000/middle` | 1000 | 15 | 1,184 / 1,222 / 1,269 / 1,303 | 1.91 / 2.16 / 2.53 / 2.69 | 566.42x | 119,490,657 / 152,084 |
| `1MiB/1000/eof` | 1000 | 15 | 1,258 / 1,316 / 1,371 / 1,400 | 2.06 / 2.27 / 2.82 / 3.72 | 579.84x | 119,621,783 / 152,455 |
| `1MiB/10000/start` | 10000 | 2 | 10,584 / 10,584 / 10,689 / 10,689 | 12.4 / 12.4 / 12.5 / 12.5 | 851.67x | 1,175,720,391 / 784,188 |
| `1MiB/10000/middle` | 10000 | 2 | 11,524 / 11,524 / 11,686 / 11,686 | 12.9 / 12.9 / 13.7 / 13.7 | 891.70x | 1,171,620,556 / 784,587 |
| `1MiB/10000/eof` | 10000 | 2 | 13,094 / 13,094 / 13,287 / 13,287 | 13.4 / 13.4 / 13.8 / 13.8 | 973.62x | 1,192,800,885 / 787,102 |
| `16MiB/1/start` | 1 | 15 | 21.8 / 29.3 / 36.0 / 36.1 | 19.6 / 23.6 / 30.8 / 31.8 | 1.24x | 1,027,484 / 1,022,049 |
| `16MiB/1/middle` | 1 | 15 | 25.2 / 27.6 / 33.9 / 38.1 | 21.1 / 26.9 / 33.8 / 35.7 | 1.03x | 1,025,009 / 1,026,968 |
| `16MiB/1/eof` | 1 | 15 | 21.6 / 23.5 / 30.9 / 31.2 | 23.7 / 29.9 / 38.9 / 39.7 | 0.79x | 1,020,897 / 1,023,804 |
| `16MiB/10/start` | 10 | 15 | 264 / 291 / 323 / 344 | 23.5 / 26.0 / 27.4 / 28.5 | 11.20x | 16,801,837 / 1,069,402 |
| `16MiB/10/middle` | 10 | 15 | 256 / 261 / 291 / 297 | 24.7 / 25.8 / 28.4 / 29.3 | 10.12x | 16,758,817 / 1,069,617 |
| `16MiB/10/eof` | 10 | 15 | 246 / 255 / 301 / 323 | 24.2 / 25.5 / 28.0 / 28.5 | 9.96x | 16,755,844 / 1,069,169 |
| `16MiB/1000/start` | 1000 | 1 | 27,363 / 27,363 / 27,363 / 27,363 | 28.7 / 28.7 / 28.7 / 28.7 | 951.95x | 1,749,602,725 / 1,139,293 |
| `16MiB/1000/middle` | 1000 | 1 | 27,629 / 27,629 / 27,629 / 27,629 | 33.0 / 33.0 / 33.0 / 33.0 | 836.05x | 1,748,687,325 / 1,145,547 |
| `16MiB/1000/eof` | 1000 | 1 | 23,771 / 23,771 / 23,771 / 23,771 | 30.0 / 30.0 / 30.0 / 30.0 | 791.80x | 1,737,199,391 / 1,143,171 |
| `16MiB/10000/start` | 10000 | 1 | 245,154 / 245,154 / 245,154 / 245,154 | 40.8 / 40.8 / 40.8 / 40.8 | 6002.50x | 17,509,491,313 / 1,790,125 |
| `16MiB/10000/middle` | 10000 | 1 | 268,692 / 268,692 / 268,692 / 268,692 | 45.1 / 45.1 / 45.1 / 45.1 | 5955.31x | 17,503,606,890 / 1,792,940 |
| `16MiB/10000/eof` | 10000 | 1 | 260,050 / 260,050 / 260,050 / 260,050 | 44.4 / 44.4 / 44.4 / 44.4 | 5852.50x | 17,390,558,800 / 1,793,134 |
| `boundary/adjacent` |  | 8 | 1,272 / 1,305 / 1,339 / 1,339 | 1,271 / 1,279 / 1,336 / 1,336 | 1.02x | 120,002,412 / 110,480,126 |
| `boundary/column past line end` |  | 8 | 1,360 / 1,370 / 1,461 / 1,461 | 1,198 / 1,259 / 1,316 / 1,316 | 1.09x | 119,598,488 / 118,523,467 |
| `boundary/conflicting` |  | 6 | 2,414 / 2,429 / 2,507 / 2,507 | 1,336 / 1,351 / 1,385 / 1,385 | 1.80x | 238,867,180 / 122,812,915 |
| `boundary/crlf` |  | 15 | 1,361 / 1,388 / 1,441 / 1,475 | 2.11 / 2.23 / 2.33 / 2.53 | 623.26x | 117,127,086 / 154,546 |
| `boundary/eof insertion` |  | 15 | 1.62 / 1.79 / 2.79 / 5.04 | 1.59 / 1.76 / 2.06 / 2.28 | 1.02x | 121,753 / 121,718 |
| `boundary/equal endpoints` |  | 15 | 1,201 / 1,212 / 1,255 / 1,308 | 1.98 / 2.16 / 2.59 / 2.66 | 561.47x | 119,463,280 / 152,157 |
| `boundary/multi-line replacements` |  | 14 | 1,433 / 1,460 / 1,518 / 1,556 | 3.17 / 3.22 / 3.67 / 3.76 | 453.23x | 126,093,738 / 220,166 |
| `boundary/overlapping` |  | 9 | 1,178 / 1,195 / 1,240 / 1,240 | 1,184 / 1,197 / 1,242 / 1,242 | 1.00x | 115,169,624 / 118,519,370 |
| `boundary/unicode` |  | 15 | 1,272 / 1,305 / 1,364 / 1,371 | 2.47 / 2.53 / 2.75 / 2.79 | 514.86x | 123,342,283 / 157,921 |
| `boundary/unicode caret check` |  | 15 | 1,265 / 1,277 / 1,339 / 1,344 | 3.02 / 3.44 / 3.81 / 3.99 | 371.87x | 123,257,119 / 206,540 |
| `boundary/unsorted` |  | 15 | 1,280 / 1,317 / 1,348 / 1,366 | 2.33 / 2.50 / 3.24 / 4.08 | 527.20x | 119,802,190 / 172,539 |

Single edits take the previous path and do the same work: reductions agree to within 0.6%, and the wall-time differences in both directions are run-to-run variation. Batches that the candidate cannot plan (`overlapping`, `adjacent`, `column past line end`) cost the same as before; `overlapping` does 2.9% more reductions for the extra snapshot check per edit, and its wall time is unchanged. `conflicting` gains 1.8x because half of its edits join runs.

## Results: consumer path

| Workload | Step | n (base / cand) | Baseline p50 / p95 (ms) | Candidate p50 / p95 (ms) | p50 ratio |
|---|---|---|---|---|---:|
| `16MiB/1/middle` | apply_edits | 5 / 5 | 32.5 / 36.6 | 30.3 / 33.7 | 1.07x |
| `16MiB/1/middle` | undo | 5 / 5 | 35.1 / 51.9 | 30.0 / 33.0 | 1.17x |
| `16MiB/1/middle` | redo | 5 / 5 | 36.4 / 43.2 | 35.8 / 44.4 | 1.02x |
| `16MiB/10/middle` | apply_edits | 5 / 5 | 339 / 341 | 28.0 / 31.2 | 12.11x |
| `16MiB/10/middle` | undo | 5 / 5 | 273 / 276 | 247 / 249 | 1.10x |
| `16MiB/10/middle` | redo | 5 / 5 | 263 / 266 | 227 / 242 | 1.16x |
| `16MiB/1000/middle` | apply_edits | 1 / 1 | 30,008 / 30,008 | 34.5 / 34.5 | 870.80x |
| `16MiB/1000/middle` | undo | 1 / 1 | 22,969 / 22,969 | 22,416 / 22,416 | 1.02x |
| `16MiB/1000/middle` | redo | 1 / 1 | 22,635 / 22,635 | 22,408 / 22,408 | 1.01x |
| `16MiB/10000/middle` | apply_edits | 1 / 5 | 279,100 / 279,100 | 41.8 / 43.6 | 6670.65x |
| `1MiB/1/middle` | apply_edits | 5 / 5 | 1.55 / 4.08 | 1.85 / 4.68 | 0.84x |
| `1MiB/1/middle` | undo | 5 / 5 | 1.65 / 4.49 | 1.87 / 4.62 | 0.88x |
| `1MiB/1/middle` | redo | 5 / 5 | 1.92 / 2.04 | 2.15 / 2.46 | 0.89x |
| `1MiB/10/middle` | apply_edits | 5 / 5 | 15.8 / 16.9 | 1.64 / 1.85 | 9.62x |
| `1MiB/10/middle` | undo | 5 / 5 | 15.9 / 16.7 | 14.8 / 25.9 | 1.08x |
| `1MiB/10/middle` | redo | 5 / 5 | 15.5 / 17.9 | 22.8 / 34.4 | 0.68x |
| `1MiB/1000/middle` | apply_edits | 5 / 5 | 1,418 / 1,446 | 3.49 / 3.57 | 406.12x |
| `1MiB/1000/middle` | undo | 5 / 5 | 1,411 / 1,458 | 1,350 / 1,555 | 1.05x |
| `1MiB/1000/middle` | redo | 5 / 5 | 1,585 / 1,595 | 1,475 / 1,529 | 1.07x |
| `1MiB/10000/middle` | apply_edits | 2 / 5 | 12,602 / 12,685 | 13.7 / 14.2 | 920.90x |
| `boundary/overlapping` | apply_edits | 5 / 5 | 1,282 / 1,332 | 1,244 / 1,301 | 1.03x |
| `boundary/overlapping` | undo | 5 / 5 | 1,344 / 1,395 | 1,239 / 1,273 | 1.08x |
| `boundary/overlapping` | redo | 5 / 5 | 1,453 / 1,462 | 1,329 / 1,375 | 1.09x |
| `boundary/unicode` | apply_edits | 5 / 5 | 1,386 / 1,416 | 3.53 / 3.87 | 392.98x |
| `boundary/unicode` | undo | 5 / 5 | 1,429 / 1,503 | 1,381 / 1,419 | 1.03x |
| `boundary/unicode` | redo | 5 / 5 | 1,625 / 1,640 | 1,325 / 1,346 | 1.23x |

`apply_edits` improves by the same factors as the stage. Undo, redo, and single-edit calls run the same code on both commits; their differences are run-to-run variation between two separate runs. Three more alternating runs of the 1 MiB single-edit and 10-edit cells (`consumer-repeat/`) put both commits within 10% of each other in both directions for those calls.

## Decision

Ship. The candidate removes the per-edit document traversal for separated batches, which is the common case for renames, formatting, and agent edits: 9x to 12x at 10 edits, 400x to 900x at 1,000 edits, and 900x to 6,700x at 10,000 edits. It has no measured regression. Single edits, unplannable batches, undo, and redo stay within run-to-run variation, and the work counters explain the one small extra cost.

## Findings outside this change

- **Batch undo and redo are still `k` document rebuilds.** `UndoHistory` applies each patch with `UndoPatch.apply/2`, which rebuilds the whole document. Undoing the 1,000-edit 16 MiB batch takes 22 s on both commits. The same single-pass assembly would apply here, as a separate change.
- **Large calls exceed the 5 s GenServer timeout.** On the baseline commit, `apply_edits/3` on a 16 MiB document times out for the caller beyond about 180 edits, while the Buffer process keeps working. After this change `apply_edits/3` is fast, but `undo/1` and `redo/1` of a large batch still time out.
- **Two existing contract defects in the sequential semantics, preserved here.** (1) A column past its line end deletes at the clamped byte offset, but `Cursor.place/2` inserts at the line end, so the recorded undo patch is wrong: applying `{{0, 5}, {0, 5}, "Z"}` to `"ab\ncd"` gives `"abZ\ncd"`, and undo gives `"abZ\nc"`. (2) Overlapping edits can cut through a previous replacement inside a code point, which leaves invalid UTF-8; undo then raises and the Buffer process exits. The candidate keeps both behaviors exactly, as #3500 requires. Fixing them changes the public contract and needs its own ticket.
