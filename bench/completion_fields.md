# Completion field preparation

Receipt for [#3497](https://github.com/jsmestad/minga/issues/3497), part of [#3501](https://github.com/jsmestad/minga/issues/3501). Decision: **reject, no production change**. Parsing an LSP completion item prepares one field that nothing reads before display: the per-codepoint mapping from normalized filter text back to the displayed label, which only the at most 200 items a snapshot retains use, to place match ranges. Deferring it removes 30% to 36% of the completion Task's parse work and 6% to 7% of the parsed batch, but every later snapshot then rebuilds the mapping for its retained items on the Editor process. That adds 71% to 72% to the per-keystroke filter work at 100 items, 19% at 1,000 and 2% to 3% at 10,000, and 1% to 29% to installation. Moving one-time work off a background Task onto every keystroke of the Editor is the wrong trade, so the deferral is rejected. A second candidate kept the mapping eager and made it cheaper (ASCII codepoints lowercase directly). It cuts parse work by 11% to 16% with no change elsewhere, but its wall-time gain is smaller than the paired run-to-run variation on this machine and lands only in the background Task, so it is rejected as well. Every other eagerly prepared field is either needed before display (ranking, identity, the visible row) or costs about 1% of parsing.

The Editor-side cost that does scale with list size is not field preparation: installing a 10,000-item batch takes 130 to 165 ms on the Editor process, and about half of that is SHA-256 hashing of item identities (see [Findings outside this ticket](#findings-outside-this-ticket)).

## Reproduce

```sh
MIX_ENV=test mix run bench/completion_fields.exs OUT_DIR            # 0, 100, 1,000 and 10,000 items
MIX_ENV=test mix run bench/completion_fields.exs OUT_DIR --quick    # 0 and 10,000 items
elixir bench/completion_fields/compare.exs bench/completion_fields v1   # tables below, deferral
elixir bench/completion_fields/compare.exs bench/completion_fields c3   # tables below, ASCII mapping
elixir bench/completion_fields/compare.exs bench/completion_fields h1   # hash once (#3952)
```

Each run writes `samples.csv` (gzipped here), `summary.json` and `identity.json` (commit, dirty `lib/` paths, a hash of the two completion sources, OTP, Elixir, schedulers, architecture). The bench uses only public functions present on every compared commit, so the same script runs on the baseline and on each candidate. To rerun a candidate, apply its patch on the baseline: `git apply bench/completion_fields/rejected-deferral.patch` or `git apply bench/completion_fields/rejected-ascii-mapping.patch` (the second also adds the contract tests).

Measured on Apple M1, 8 cores, 16 GB, macOS 27.2, Elixir 1.20.5 / OTP 29, `ERL_FLAGS='+S 4:4'`, `MIX_ENV=test`, from clean `lib/` trees. Baseline is `aa61483a5`, which adds only this bench to `ee23dd518` (`main`); its `lib/` is `main`'s. Candidate commits were `bee4f19ce` (deferral, `v1`), `256bfd2d1` (deferral plus ASCII mapping, `x-c2`, one run), `ff8b7737e` (ASCII mapping on the baseline, `x-c3`, one run) and `caeccbe35` (ASCII mapping plus contract tests, `c3`). They are not kept on the branch; their diffs are the two patches. The host ran other agents' BEAM processes during every run, so wall times carry outside noise (see [Variation](#variation)); reductions do not.

## Method

**Fixture.** `response/1` in the bench builds a deterministic `CompletionList` of N items, N = 0, 100, 1,000 and 10,000. Labels rotate through ASCII (`handle_event_7`), Latin with accents (`handle_évènement_7`), CJK (`handle_字段_7`), an uppercase start with an emoji (`Handle😀Emoji_7`) and Greek capitals (`handleΣΑΣ_7`). Every 7th item has a `filterText` different from its label, so its label gets no match ranges. Documentation is about 3.3 KB of markdown with surrounding whitespace; every 5th item has none (it needs `completionItem/resolve`) and every 13th has a plaintext string. Edits are snippet `textEdit`s, an `InsertReplaceEdit` on every 3rd item and snippet `insertText` on every 9th. Every even item has `additionalTextEdits`; every item has `detail`, `kind`, `sortText`, `insertTextFormat` and `data`. Every 50th item is followed by a true duplicate, which the index collapses. Item 42 is preselected.

**Stages.** One sample replays the response through the production topology. A fresh process stands in for the completion Task and another for the Editor, as in `MingaEditor.CompletionHandling`:

| Stage | Process | Work |
|---|---|---|
| `parse` | Task | `ProviderBatch.from_response/6` on the raw response |
| `transfer` | both | sending the batch to the Editor process, which copies it, until the receiver acknowledges |
| `install` | Editor | `Session.accept_batch/2`, then `Completion.new/3` and `Completion.filter/2` with the typed prefix `h` (`install_session_completion/3`) |
| `visible` | Editor | `CompletionBuilder.build/1` and `CompletionEncoder.encode/2` for the first popup |
| `filter` | Editor | one keystroke: `Completion.filter/2` plus the popup model and its encoding. Seven keystrokes per sample: `ha` through `handle_`, then the fuzzy query `hdlev` |
| `select` | Editor | one selection move: `Completion.move_down/1` plus the popup model and its selection-only encoding. 20 moves per sample |
| `accept` | Editor | `Completion.accept/1` and the resulting `Minga.Buffer.apply_edit/6` on a started buffer |

Each stage records wall microseconds and the reductions of the process that does the work, a deterministic work count. `parse` and `install` also record the flat heap size of their result in words (retained memory). Transient allocation is not measured. Two warm-up samples precede up to 40 (N ≤ 100), 30 (1,000) or 20 (10,000) samples per item count. Percentiles are nearest-rank. "Response to visible popup" sums `parse`, `transfer`, `install` and `visible` per sample.

**Result check.** Every sample builds a digest of what the consumer sees: the ranked items with pid-free identities, labels, kinds, match ranges, details, documentation, insert text, text edits and preselect flags after installation and after each keystroke; the popup model (selected id, offset, documentation, visible rows); the selected item and its documentation after each move; the accepted edit; and the edited buffer content. A run fails if two samples disagree. All 10 kept runs (four baseline, six candidate) report the same digest for each item count, so ranking, identity, filtering, displayed details and documentation and the final edit are identical.

**Order.** Each candidate ran in two pairs with alternating order: pair A baseline first, pair B candidate first. `x-c2` and `x-c3` are single exploratory runs.

## What parsing prepares

`Item.from_lsp/2` prepares these fields for every item in the response:

| Field | Read by | Needed before display or acceptance | Cost at 10,000 items |
|---|---|---|---|
| `search.filter_to_label` (label mapping) | `Index.snapshot/4`, for retained items with a non-empty query | No: at most 200 items per snapshot read it | 30% to 36% of parse reductions (measured by `v1`) |
| `insert_text`, `text_edit.new_text` (snippet markers stripped by regex) | item identity and duplicate collapse, `Completion.accept/1` | Yes: part of `Item.id` | about 20% of parse call time (profile) |
| `search.label`, `search.filter_text`, `search.sort_text` (lowercase) | ranking | Yes | |
| `source` (`"lsp:" <> inspect(pid)` per item) | ranking tie-break (`Ranker.rank_key/2`) and every visible row | Yes | 13 ms per 10,000 items (scratch timing) |
| `documentation` (trimmed) | the selected item's preview and the resolve gate (`documentation != ""` skips `completionItem/resolve`) | Only for the selected item | 3 ms per 10,000 items (scratch timing), about 1% |
| `detail`, `kind`, `preselect`, `id` | ranking, identity and visible rows | Yes | map lookups |
| `raw` | resolve requests; keeps `additionalTextEdits` and `command` | No preparation | none; large binaries are shared, not copied |

`additionalTextEdits` and `command` are not prepared at all, so there is nothing to defer there (they are also not applied on acceptance; see below). Only the label mapping is both expensive and unused before display, so it is the only deferral candidate.

## Candidate 1: defer the label mapping (rejected)

[`rejected-deferral.patch`](completion_fields/rejected-deferral.patch) removes `filter_to_label` from `Item.Search` and derives the mapping in `Item.with_normalized_match_ranges/2`, with the same function and conditions, only when the ranges are not empty. All times in milliseconds.


Pair A

| Items | Stage | n | Baseline ms p10 / p50 / p90 / p95 | Candidate ms p10 / p50 / p90 / p95 | p50 change | Baseline reductions p50 | Candidate reductions p50 | Ratio | Retained words p50 baseline / candidate |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | parse | 40 / 40 | 1.12 / 1.18 / 1.33 / 1.54 | 0.90 / 0.94 / 1.27 / 1.45 | -21% | 66,927 | 46,976 | 0.70 | 43,715 / 41,073 |
| 100 | transfer | 40 / 40 | 0.17 / 0.18 / 0.20 / 0.24 | 0.15 / 0.16 / 0.17 / 0.17 | -12% | 0 | 0 | n/a |  |
| 100 | install | 40 / 40 | 1.25 / 1.34 / 1.82 / 2.10 | 1.40 / 1.49 / 1.61 / 1.63 | 11% | 65,801 | 84,547 | 1.28 | 94,502 / 89,220 |
| 100 | visible | 40 / 40 | 0.05 / 0.06 / 0.07 / 0.08 | 0.03 / 0.04 / 0.05 / 0.06 | -30% | 2,524 | 2,238 | 0.89 |  |
| 100 | filter | 280 / 280 | 0.40 / 0.64 / 0.90 / 1.02 | 0.63 / 0.91 / 1.23 / 1.28 | 42% | 30,336 | 52,140 | 1.72 |  |
| 100 | select | 800 / 800 | 0.02 / 0.03 / 0.08 / 0.24 | 0.02 / 0.03 / 0.21 / 0.26 | -4% | 2,318 | 2,316 | 1.00 |  |
| 100 | accept | 40 / 40 | 0.05 / 0.06 / 0.09 / 0.10 | 0.05 / 0.06 / 0.08 / 0.10 | 2% | 76 | 76 | 1.00 |  |
| 1,000 | parse | 30 / 30 | 11.01 / 13.23 / 18.78 / 21.53 | 8.66 / 9.25 / 12.35 / 13.62 | -30% | 670,544 | 455,385 | 0.68 | 439,858 / 411,422 |
| 1,000 | transfer | 30 / 30 | 1.05 / 1.23 / 1.93 / 2.74 | 0.97 / 1.09 / 1.25 / 2.22 | -12% | 0 | 0 | n/a |  |
| 1,000 | install | 30 / 30 | 13.70 / 16.10 / 24.09 / 29.60 | 13.22 / 14.21 / 16.09 / 21.37 | -12% | 597,213 | 635,115 | 1.06 | 594,250 / 560,606 |
| 1,000 | visible | 30 / 30 | 0.04 / 0.06 / 0.13 / 0.16 | 0.04 / 0.05 / 0.06 / 0.07 | -13% | 2,219 | 2,219 | 1.00 |  |
| 1,000 | filter | 210 / 210 | 2.97 / 5.29 / 7.66 / 11.96 | 2.77 / 4.96 / 5.70 / 6.04 | -6% | 219,668 | 261,734 | 1.19 |  |
| 1,000 | select | 600 / 600 | 0.03 / 0.03 / 0.18 / 0.24 | 0.03 / 0.03 / 0.15 / 0.18 | -13% | 2,338 | 2,338 | 1.00 |  |
| 1,000 | accept | 30 / 30 | 0.06 / 0.07 / 0.09 / 0.18 | 0.05 / 0.06 / 0.09 / 0.11 | -14% | 77 | 77 | 1.00 |  |
| 10,000 | parse | 20 / 20 | 279 / 304 / 399 / 425 | 160 / 190 / 225 / 228 | -38% | 7,410,061 | 4,803,188 | 0.65 | 4,450,987 / 4,149,235 |
| 10,000 | transfer | 20 / 20 | 13.38 / 16.54 / 23.86 / 24.75 | 10.79 / 12.01 / 14.41 / 15.79 | -27% | 0 | 0 | n/a |  |
| 10,000 | install | 20 / 20 | 145 / 165 / 200 / 207 | 134 / 162 / 174 / 204 | -2% | 5,865,991 | 5,909,889 | 1.01 | 5,199,047 / 4,896,331 |
| 10,000 | visible | 20 / 20 | 0.07 / 0.08 / 0.11 / 0.12 | 0.06 / 0.07 / 0.08 / 0.09 | -16% | 2,219 | 2,219 | 1.00 |  |
| 10,000 | filter | 140 / 140 | 24.04 / 48.37 / 59.34 / 64.51 | 22.30 / 45.82 / 56.84 / 63.75 | -5% | 1,991,968 | 2,050,129 | 1.03 |  |
| 10,000 | select | 400 / 400 | 0.03 / 0.03 / 0.21 / 0.37 | 0.02 / 0.03 / 0.12 / 0.25 | -12% | 2,335 | 2,335 | 1.00 |  |
| 10,000 | accept | 20 / 20 | 0.06 / 0.06 / 0.08 / 0.09 | 0.06 / 0.06 / 0.08 / 0.08 | -6% | 77 | 77 | 1.00 |  |

Pair B

| Items | Stage | n | Baseline ms p10 / p50 / p90 / p95 | Candidate ms p10 / p50 / p90 / p95 | p50 change | Baseline reductions p50 | Candidate reductions p50 | Ratio | Retained words p50 baseline / candidate |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | parse | 40 / 40 | 1.06 / 1.12 / 1.22 / 1.31 | 0.83 / 0.85 / 0.93 / 0.95 | -25% | 66,927 | 46,976 | 0.70 | 43,715 / 41,073 |
| 100 | transfer | 40 / 40 | 0.16 / 0.17 / 0.18 / 0.19 | 0.13 / 0.14 / 0.15 / 0.16 | -21% | 0 | 0 | n/a |  |
| 100 | install | 40 / 40 | 1.20 / 1.29 / 1.35 / 1.52 | 1.21 / 1.23 / 1.30 / 1.33 | -5% | 65,814 | 84,577 | 1.29 | 94,500 / 89,222 |
| 100 | visible | 40 / 40 | 0.05 / 0.05 / 0.06 / 0.06 | 0.02 / 0.03 / 0.03 / 0.03 | -47% | 2,523 | 2,238 | 0.89 |  |
| 100 | filter | 280 / 280 | 0.36 / 0.59 / 0.76 / 0.79 | 0.49 / 0.75 / 1.02 / 1.04 | 28% | 30,432 | 52,001 | 1.71 |  |
| 100 | select | 800 / 800 | 0.02 / 0.03 / 0.05 / 0.22 | 0.02 / 0.02 / 0.16 / 0.20 | -16% | 2,316 | 2,316 | 1.00 |  |
| 100 | accept | 40 / 40 | 0.05 / 0.06 / 0.07 / 0.08 | 0.04 / 0.05 / 0.06 / 0.06 | -21% | 76 | 76 | 1.00 |  |
| 1,000 | parse | 30 / 30 | 10.25 / 10.94 / 12.07 / 13.47 | 7.85 / 8.86 / 11.82 / 15.67 | -19% | 670,088 | 455,385 | 0.68 | 439,858 / 411,422 |
| 1,000 | transfer | 30 / 30 | 0.93 / 1.07 / 1.26 / 1.66 | 0.88 / 0.99 / 1.21 / 1.44 | -8% | 0 | 0 | n/a |  |
| 1,000 | install | 30 / 30 | 12.54 / 13.13 / 15.54 / 16.27 | 11.78 / 13.39 / 15.83 / 17.99 | 2% | 593,840 | 632,720 | 1.07 | 594,248 / 560,610 |
| 1,000 | visible | 30 / 30 | 0.04 / 0.05 / 0.06 / 0.08 | 0.04 / 0.05 / 0.06 / 0.07 | 0% | 2,219 | 2,219 | 1.00 |  |
| 1,000 | filter | 210 / 210 | 2.16 / 4.46 / 5.01 / 5.54 | 2.65 / 4.67 / 5.58 / 6.02 | 5% | 219,394 | 261,487 | 1.19 |  |
| 1,000 | select | 600 / 600 | 0.02 / 0.03 / 0.14 / 0.15 | 0.02 / 0.03 / 0.13 / 0.16 | 0% | 2,338 | 2,338 | 1.00 |  |
| 1,000 | accept | 30 / 30 | 0.06 / 0.06 / 0.07 / 0.07 | 0.05 / 0.06 / 0.08 / 0.09 | 3% | 77 | 77 | 1.00 |  |
| 10,000 | parse | 20 / 20 | 221 / 291 / 347 / 348 | 147 / 164 / 229 / 256 | -44% | 7,388,257 | 4,734,068 | 0.64 | 4,450,987 / 4,149,235 |
| 10,000 | transfer | 20 / 20 | 10.96 / 13.30 / 15.42 / 16.14 | 9.32 / 11.34 / 14.08 / 16.32 | -15% | 0 | 0 | n/a |  |
| 10,000 | install | 20 / 20 | 126 / 142 / 186 / 188 | 124 / 134 / 158 / 167 | -6% | 5,849,453 | 5,885,277 | 1.01 | 5,199,029 / 4,896,361 |
| 10,000 | visible | 20 / 20 | 0.06 / 0.08 / 0.11 / 0.26 | 0.06 / 0.07 / 0.08 / 0.10 | -16% | 2,219 | 2,219 | 1.00 |  |
| 10,000 | filter | 140 / 140 | 21.02 / 40.67 / 50.85 / 52.76 | 19.74 / 37.57 / 46.64 / 50.56 | -8% | 2,005,314 | 2,049,989 | 1.02 |  |
| 10,000 | select | 400 / 400 | 0.02 / 0.03 / 0.15 / 0.26 | 0.02 / 0.02 / 0.11 / 0.16 | -15% | 2,335 | 2,335 | 1.00 |  |
| 10,000 | accept | 20 / 20 | 0.05 / 0.06 / 0.08 / 0.12 | 0.05 / 0.06 / 0.08 / 0.09 | -10% | 77 | 77 | 1.00 |  |

Response to visible popup (parse + transfer + install + visible), ms p10 / p50 / p90 / p95

| Items | A baseline | A candidate | B baseline | B candidate |
|---:|---:|---:|---:|---:|
| 100 | 2.61 / 2.79 / 3.40 / 3.79 | 2.51 / 2.67 / 3.19 / 3.24 | 2.48 / 2.64 / 2.86 / 2.96 | 2.19 / 2.25 / 2.43 / 2.46 |
| 1,000 | 26.68 / 29.97 / 45.20 / 66.82 | 22.75 / 24.60 / 29.23 / 37.20 | 24.16 / 25.37 / 28.67 / 30.80 | 20.94 / 23.05 / 29.87 / 33.90 |
| 10,000 | 448 / 484 / 621 / 636 | 306 / 365 / 406 / 452 | 364 / 458 / 535 / 548 | 282 / 314 / 390 / 419 |

Parsing gets 30% to 36% cheaper in reductions and 19% to 44% faster at p50, and the parsed batch is 6% to 7% smaller, so it also copies faster into the Editor. At 10,000 items the response reaches a visible popup 119 to 144 ms sooner (25% to 31%). But the Editor process now builds the mapping for every retained item on every snapshot: `install` takes 1.28 times the reductions at 100 items and 1.06 times at 1,000, and every keystroke takes 1.71 to 1.72 times the filter reductions at 100 items, 1.19 times at 1,000 and 1.02 to 1.03 times at 10,000. At 100 items the keystroke p50 rises from 0.59 to 0.64 ms to 0.75 to 0.91 ms. Small and medium lists are the common case, and the Editor is the process the user waits on, so this is a material regression on the critical path. Selection, popup building and acceptance are unchanged, and the 0-item control is identical in every stage.

Adding the ASCII mapping below to the deferral (`x-c2`, one run) shrinks but does not remove the regression: filter reductions are 1.46 times the baseline at 100 items (44,505 against 30,432), 1.10 times at 1,000 and 1.02 times at 10,000, and `install` is 1.14 times at 100 items.

Retaining a computed mapping per item to avoid the repeat would be a cache, which the ticket excludes, and it would not survive the immutable index without writing results back on every snapshot.

## Candidate 2: cheaper eager mapping (rejected)

[`rejected-ascii-mapping.patch`](completion_fields/rejected-ascii-mapping.patch) keeps the mapping eager and lowercases ASCII codepoints directly in `map_normalized_prefix/4`; other codepoints still go through `String.downcase/1`. Lowercasing one ASCII codepoint has no context and needs no Unicode tables, so the mapping is identical.


Pair A

| Items | Stage | n | Baseline ms p10 / p50 / p90 / p95 | Candidate ms p10 / p50 / p90 / p95 | p50 change | Baseline reductions p50 | Candidate reductions p50 | Ratio | Retained words p50 baseline / candidate |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | parse | 40 / 40 | 1.10 / 1.19 / 1.96 / 2.27 | 0.92 / 0.98 / 1.20 / 1.28 | -18% | 66,927 | 57,259 | 0.86 | 43,715 / 43,715 |
| 100 | transfer | 40 / 40 | 0.17 / 0.18 / 0.37 / 0.40 | 0.14 / 0.15 / 0.17 / 0.17 | -15% | 0 | 0 | n/a |  |
| 100 | install | 40 / 40 | 1.22 / 1.34 / 1.91 / 2.90 | 1.08 / 1.16 / 1.24 / 1.27 | -14% | 65,814 | 65,913 | 1.00 | 94,500 / 94,506 |
| 100 | visible | 40 / 40 | 0.05 / 0.06 / 0.13 / 0.14 | 0.04 / 0.05 / 0.05 / 0.06 | -25% | 2,523 | 2,520 | 1.00 |  |
| 100 | filter | 280 / 280 | 0.41 / 0.66 / 1.25 / 1.74 | 0.32 / 0.52 / 0.67 / 0.72 | -22% | 30,441 | 30,504 | 1.00 |  |
| 100 | select | 800 / 800 | 0.02 / 0.03 / 0.10 / 0.25 | 0.02 / 0.02 / 0.04 / 0.17 | -18% | 2,316 | 2,316 | 1.00 |  |
| 100 | accept | 40 / 40 | 0.06 / 0.07 / 0.09 / 0.10 | 0.04 / 0.05 / 0.07 / 0.07 | -25% | 76 | 76 | 1.00 |  |
| 1,000 | parse | 30 / 30 | 10.66 / 11.57 / 14.71 / 17.28 | 8.21 / 8.36 / 8.80 / 8.94 | -28% | 670,360 | 564,294 | 0.84 | 439,858 / 439,858 |
| 1,000 | transfer | 30 / 30 | 0.96 / 1.20 / 1.50 / 1.57 | 0.81 / 0.89 / 1.08 / 1.15 | -26% | 0 | 0 | n/a |  |
| 1,000 | install | 30 / 30 | 13.06 / 16.68 / 19.34 / 20.38 | 10.52 / 10.76 / 11.50 / 11.72 | -35% | 595,798 | 590,412 | 0.99 | 594,248 / 594,252 |
| 1,000 | visible | 30 / 30 | 0.05 / 0.06 / 0.09 / 0.16 | 0.03 / 0.04 / 0.04 / 0.05 | -41% | 2,219 | 2,219 | 1.00 |  |
| 1,000 | filter | 210 / 210 | 3.16 / 5.22 / 7.28 / 8.84 | 1.77 / 3.73 / 4.17 / 4.32 | -28% | 219,329 | 218,577 | 1.00 |  |
| 1,000 | select | 600 / 600 | 0.03 / 0.03 / 0.18 / 0.25 | 0.02 / 0.02 / 0.12 / 0.13 | -33% | 2,338 | 2,338 | 1.00 |  |
| 1,000 | accept | 30 / 30 | 0.06 / 0.06 / 0.09 / 0.10 | 0.05 / 0.06 / 0.06 / 0.07 | -14% | 77 | 77 | 1.00 |  |
| 10,000 | parse | 20 / 20 | 226 / 279 / 372 / 398 | 234 / 586 / 986 / 989 | 110% | 7,345,485 | 6,511,511 | 0.89 | 4,450,987 / 4,450,987 |
| 10,000 | transfer | 20 / 20 | 11.40 / 14.20 / 17.72 / 19.95 | 11.91 / 19.43 / 39.67 / 42.15 | 37% | 0 | 0 | n/a |  |
| 10,000 | install | 20 / 20 | 129 / 160 / 195 / 213 | 133 / 261 / 739 / 751 | 63% | 5,876,147 | 5,897,258 | 1.00 | 5,199,029 / 5,199,075 |
| 10,000 | visible | 20 / 20 | 0.06 / 0.08 / 0.10 / 0.11 | 0.06 / 0.09 / 0.80 / 1.00 | 25% | 2,219 | 2,219 | 1.00 |  |
| 10,000 | filter | 140 / 140 | 21.95 / 43.01 / 55.70 / 58.70 | 37.12 / 79.68 / 219 / 254 | 85% | 2,003,607 | 1,988,901 | 0.99 |  |
| 10,000 | select | 400 / 400 | 0.02 / 0.03 / 0.14 / 0.22 | 0.02 / 0.06 / 0.39 / 0.68 | 115% | 2,335 | 2,336 | 1.00 |  |
| 10,000 | accept | 20 / 20 | 0.06 / 0.06 / 0.08 / 0.08 | 0.06 / 0.09 / 0.25 / 0.31 | 33% | 77 | 77 | 1.00 |  |

Pair B

| Items | Stage | n | Baseline ms p10 / p50 / p90 / p95 | Candidate ms p10 / p50 / p90 / p95 | p50 change | Baseline reductions p50 | Candidate reductions p50 | Ratio | Retained words p50 baseline / candidate |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | parse | 40 / 40 | 0.94 / 1.00 / 1.15 / 1.20 | 0.93 / 1.13 / 1.94 / 2.03 | 13% | 66,927 | 57,259 | 0.86 | 43,715 / 43,715 |
| 100 | transfer | 40 / 40 | 0.14 / 0.16 / 0.18 / 0.19 | 0.14 / 0.18 / 0.24 / 0.31 | 15% | 0 | 0 | n/a |  |
| 100 | install | 40 / 40 | 1.05 / 1.13 / 1.32 / 1.52 | 1.08 / 1.36 / 2.48 / 2.61 | 20% | 65,749 | 65,806 | 1.00 | 94,504 / 94,506 |
| 100 | visible | 40 / 40 | 0.04 / 0.05 / 0.06 / 0.06 | 0.05 / 0.06 / 0.12 / 0.14 | 20% | 2,524 | 2,523 | 1.00 |  |
| 100 | filter | 280 / 280 | 0.33 / 0.52 / 0.67 / 0.73 | 0.41 / 0.64 / 1.05 / 1.29 | 23% | 30,345 | 30,408 | 1.00 |  |
| 100 | select | 800 / 800 | 0.02 / 0.02 / 0.04 / 0.19 | 0.02 / 0.03 / 0.11 / 0.22 | 23% | 2,317 | 2,316 | 1.00 |  |
| 100 | accept | 40 / 40 | 0.05 / 0.05 / 0.07 / 0.08 | 0.05 / 0.06 / 0.09 / 0.10 | 21% | 76 | 76 | 1.00 |  |
| 1,000 | parse | 30 / 30 | 8.76 / 9.88 / 10.53 / 11.26 | 8.21 / 9.67 / 13.27 / 15.68 | -2% | 669,900 | 564,294 | 0.84 | 439,858 / 439,858 |
| 1,000 | transfer | 30 / 30 | 0.78 / 0.94 / 1.30 / 1.55 | 0.90 / 1.12 / 1.76 / 1.92 | 19% | 0 | 0 | n/a |  |
| 1,000 | install | 30 / 30 | 10.79 / 11.66 / 14.00 / 14.81 | 11.32 / 13.28 / 20.36 / 23.73 | 14% | 593,048 | 593,570 | 1.00 | 594,252 / 594,246 |
| 1,000 | visible | 30 / 30 | 0.03 / 0.04 / 0.05 / 0.05 | 0.04 / 0.05 / 0.07 / 0.11 | 21% | 2,219 | 2,219 | 1.00 |  |
| 1,000 | filter | 210 / 210 | 1.97 / 4.07 / 4.48 / 4.56 | 2.42 / 4.50 / 6.19 / 8.10 | 11% | 219,075 | 219,656 | 1.00 |  |
| 1,000 | select | 600 / 600 | 0.02 / 0.02 / 0.13 / 0.14 | 0.02 / 0.03 / 0.14 / 0.20 | 17% | 2,338 | 2,340 | 1.00 |  |
| 1,000 | accept | 30 / 30 | 0.05 / 0.06 / 0.08 / 0.09 | 0.06 / 0.06 / 0.10 / 0.13 | 9% | 77 | 77 | 1.00 |  |
| 10,000 | parse | 20 / 20 | 215 / 267 / 357 / 441 | 219 / 252 / 342 / 372 | -6% | 7,307,029 | 6,138,475 | 0.84 | 4,450,987 / 4,450,987 |
| 10,000 | transfer | 20 / 20 | 10.71 / 13.62 / 16.69 / 27.45 | 11.38 / 14.18 / 19.05 / 23.75 | 4% | 0 | 0 | n/a |  |
| 10,000 | install | 20 / 20 | 127 / 136 / 230 / 291 | 129 / 148 / 182 / 240 | 8% | 5,864,187 | 5,867,513 | 1.00 | 5,199,059 / 5,199,031 |
| 10,000 | visible | 20 / 20 | 0.06 / 0.07 / 0.13 / 0.33 | 0.06 / 0.08 / 0.12 / 0.12 | 15% | 2,219 | 2,219 | 1.00 |  |
| 10,000 | filter | 140 / 140 | 21.02 / 39.48 / 61.43 / 72.28 | 21.37 / 39.48 / 57.63 / 66.20 | 0% | 2,006,540 | 1,991,635 | 0.99 |  |
| 10,000 | select | 400 / 400 | 0.02 / 0.03 / 0.15 / 0.19 | 0.02 / 0.03 / 0.16 / 0.24 | 12% | 2,335 | 2,335 | 1.00 |  |
| 10,000 | accept | 20 / 20 | 0.06 / 0.06 / 0.08 / 0.09 | 0.05 / 0.07 / 0.17 / 0.20 | 10% | 77 | 77 | 1.00 |  |

Response to visible popup (parse + transfer + install + visible), ms p10 / p50 / p90 / p95

| Items | A baseline | A candidate | B baseline | B candidate |
|---:|---:|---:|---:|---:|
| 100 | 2.58 / 3.00 / 4.30 / 5.09 | 2.21 / 2.34 / 2.58 / 2.71 | 2.19 / 2.39 / 2.73 / 2.78 | 2.22 / 2.85 / 4.46 / 5.05 |
| 1,000 | 24.97 / 29.76 / 33.43 / 38.41 | 19.73 / 20.21 / 21.24 / 21.44 | 20.46 / 22.96 / 26.49 / 27.58 | 20.48 / 23.88 / 37.24 / 37.81 |
| 10,000 | 368 / 458 / 579 / 591 | 385 / 879 / 1652 / 1764 | 369 / 414 / 629 / 647 | 361 / 408 / 563 / 648 |

Parse reductions drop by 11% to 16% at every size, and every other stage stays within 1% in reductions. The wall-time effect is not measurable here: in pair A the candidate's 10,000-item run was slowed by outside load in every stage, including stages the change does not touch (`select` p50 0.06 ms against 0.03 ms, `install` 261 ms against 160 ms), and in pair B the parse p50 moved by 6% at 10,000 items and by 2% at 1,000, inside the variation below. The gain is also confined to the background Task: it does not change any stage the Editor runs. Per the ticket's stop conditions this is rejected rather than promoted.

## Variation

Reductions repeat closely: the two baseline runs of each pair set agree within 0.6% in every stage that runs on the Editor process, and parse reductions agree within 1.4%. Wall p50 does not. Between the two baseline runs of the `c3` pairs, the response-to-visible-popup p50 was 3.00 and 2.39 ms at 100 items, 29.76 and 22.96 ms at 1,000, and 458 and 414 ms at 10,000, a spread of 10% to 30%. Tail percentiles (p90 and p95) move further, because other agents' BEAM processes shared the machine.

## Contract checks

These tests were written for this ticket, recorded on the baseline, and passed on the baseline and on both candidates. They ship only in `rejected-ascii-mapping.patch`, because no production change is promoted.

| Check | Where (in the patch) | What it proves |
|---|---|---|
| Ranking, counts and match ranges | `test/minga_editor/completion_field_contract_test.exs` | A production-shaped response through `ProviderBatch`, `Session`, `Completion.new/3` and `Completion.filter/2`: exact rank order, total and matched counts, label match ranges for prefix and fuzzy queries, no ranges for a `filterText` override, Unicode labels |
| Identity | same | Wire ids equal those of items parsed directly from the raw maps, and a refilter keeps the same selected identity |
| Visible model | same | `CompletionBuilder.build/1` carries each visible row's match ranges and wire id |
| Selected details and documentation | same | Six selection moves each show that item's detail and trimmed documentation, the 4 KiB cap on long docs, and an empty preview for an item that needs resolve |
| Resolve | same | Resolved documentation attaches only to the exact selected identity and request; a superseded request or another item's identity is `:stale`; a resolve for the previous selection is `:stale` after the selection changes; ranking and other items' documentation do not change |
| Acceptance | same | `Completion.accept/1` returns the selected item's snippet-free `textEdit`, the insert range of an `InsertReplaceEdit`, or snippet-free `insertText`; `additionalTextEdits` stay attached to the accepted item |
| Label mapping control | `test/minga/editing/completion/index_test.exs` property (500 runs) | Every retained item's match ranges equal the pre-#3497 mapping, kept verbatim in the test, over labels with precomposed and decomposed accents, `İ`, `Σ`/`ς`, `ß`, `ǅ`, CJK and emoji, and queries that are empty, prefixes, subsequences or random |

Each check was mutated to confirm it fails. Mapping every label regardless of its filter text, or dropping the mapped ranges, fails at least four tests in the two files (the run stops at its failure limit). Showing the first item's documentation instead of the selected item's fails two contract tests; keeping snippet markers in text edits fails two; making resolve a no-op fails one; and not lowercasing ASCII capitals in candidate 2 fails two tests.

## Follow-up: hash each item's wire id once (#3952, shipped)

[#3952](https://github.com/jsmestad/minga/issues/3952) acts on the first finding below. `Item.from_lsp/2` and `Item.from_fields/2` now compute the wire id of the item's identity once, in the completion Task, and carry it on the item. Ranking, snapshots, selection and the popup model read the carried value, so the Editor process no longer hashes any identity when it installs or filters a list.

Runs `h1`: baseline `754c6d315` (`main`), candidate `81a40c50f`, two pairs with alternating order, same machine and method as above. All four runs report the same result digest for every item count, so wire ids, ranking, filtering, selection, documentation and the accepted edit are unchanged.

| Items | Stage | Pair A p50 ms, baseline → candidate | Pair B p50 ms, baseline → candidate | Reductions ratio (A / B) |
|---:|---|---:|---:|---:|
| 100 | install | 1.26 → 0.37 | 1.47 → 0.38 | 0.38 / 0.38 |
| 1,000 | install | 12.65 → 5.44 | 19.82 → 4.30 | 0.38 / 0.37 |
| 10,000 | install | 167 → 66 | 267 → 88 | 0.36 / 0.36 |
| 100 | filter (per keystroke) | 0.56 → 0.17 | 0.67 → 0.17 | 0.53 / 0.53 |
| 1,000 | filter (per keystroke) | 4.21 → 1.54 | 5.81 → 1.36 | 0.44 / 0.44 |
| 10,000 | filter (per keystroke) | 43.3 → 11.3 | 65.9 → 14.2 | 0.38 / 0.38 |
| 10,000 | parse (completion Task) | 299 → 379 | 468 → 553 | 1.12 / 1.11 |

- **Editor process:** installation does 36% to 38% of the baseline's work at every size, and each keystroke's filter 38% to 53%. Visible-popup and selection-move work also fall, by 30% to 39%. Accept is unchanged.
- **Completion Task:** parsing does 10% to 15% more work. This is the one hash per item that moved off the Editor, which is the trade the ticket asks for: it runs once, in the background, instead of two or three times per item on every install and keystroke.
- **Response to visible popup:** parse, transfer, install and visible together are about the same end to end at 1,000 and 10,000 items, within this host's run-to-run noise. The total barely moves because the work moved; what changed is that it now runs on the background Task, not on the Editor where it blocks keystrokes.
- **Bench change:** the `accept` stage now places the edit as `CompletionHandling.apply_completion_edit/2` does (LSP UTF-16 columns, half-open byte range), because since [#3953](https://github.com/jsmestad/minga/pull/3953) `Completion.accept/1` on `main` returns the accepted item instead of a bare edit, and the old stage no longer ran. Its digest keeps the item's pid-free wire id. Both sides of `h1` ran this same script.

## Findings outside this ticket

- **Identity hashing dominates installation.** Installing a 10,000-item batch scans the whole index three times (`Session.accept_batch/2` picks the default selection with a 1-item snapshot, then `Completion.new/3` and `Completion.filter/2` each take a 200-item snapshot), and every scored item computes `Item.wire_id/1`, a `term_to_binary` plus SHA-256 plus Base64 of its identity, twice (`Ranker.rank_key/2` and the snapshot entry). That is 58,828 hashes per install and about half of its call time in a profile of the baseline. Each keystroke repeats one full scan with two hashes per matching item. This is identity and ranking work, not an unused field, so it is out of scope here. [#3952](https://github.com/jsmestad/minga/issues/3952) computes each item's wire id once per batch, in the Task; see the follow-up section above.
- **Accepting a `textEdit` deletes one character too many.** `CompletionHandling.apply_completion_edit/2` passes the LSP range, whose end is exclusive, to `Minga.Buffer.apply_edit/6`, whose end is inclusive. Replacing `han` in `    han(1)` with `handle` produces `    handle1)`; at the end of a line it joins the next line. The LSP `character` offsets are also used as columns without UTF-16 conversion. [#2753](https://github.com/jsmestad/minga/issues/2753) owns coherent acceptance.
- **`additionalTextEdits` are never applied.** Items keep them in `raw`, and `Minga.LSP.Client` advertises them as resolvable, but acceptance applies only the primary edit. This is also [#2753](https://github.com/jsmestad/minga/issues/2753).
