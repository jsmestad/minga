# Multiline indentation in one buffer edit

Receipt for [#3499](https://github.com/jsmestad/minga/issues/3499) (parent backlog [#3501](https://github.com/jsmestad/minga/issues/3501)). Shifting a selection with `>` or `<` used to cost one buffer edit per line (one per removed character for `<`). Every line edit rebuilt the line index and became its own undo patch, so undo and redo rebuilt the whole document once per line. On a 100,000-line file, shifting 1,000 lines took about 2 s, and undoing it took 6.6 to 17.7 s, past the 5 s `GenServer.call` timeout the Editor waits for. The candidate applies the whole shift as one buffer edit. It shifts 1,000 lines in about 5.7 ms and undoes in about 11 ms, at every selection size.

**Decision: ship.** Every multiline cell improved by two to four orders of magnitude in edit, undo, and redo time. Undo history retains less memory, and the externally visible contract is unchanged. The one regression is a single-line `<` edit, which went from 0.08 ms to 0.43 ms (p50) on a 3.3 MB file. The cause is understood and bounded, and undoing that same edit got 3.4 times faster. See [Regressions](#regressions).

## What changed

`Buffer.shift_lines/5` runs the shift inside the buffer process, which remains the only writer:

- `Operation.shift_lines/4` reads only the selected lines and plans the edit in one pass. It returns one undo patch spanning the selected lines. It also returns one delta per changed line, in the coordinates a line-by-line edit would have produced.
- `Document.replace_line_span/4` replaces that span. When the gap is at the span start, it does not copy the rest of the document. It adjusts the line index instead of rebuilding it: O(1) for one line, O(line count) once for many.
- `ChangeLog.record_changes/2` records the batch with one retention trim instead of one trim per delta. Before this, trimming was 89% of the candidate's buffer time at 10,000 lines.
- Each delta still advances the version and the change sequence, and queues its own `:buffer_changed` event. LSP sync drops any delta whose version is not newer than the previous one, so one version per batch would lose edits. Decorations and the conflict index are adjusted per delta, as before.

The editor command keeps its cursor rules. It still moves the cursor to the first shifted line before the edit, so undo restores the cursor there as before.

## Reproduce

```sh
MIX_ENV=test mix run bench/multiline_indent.exs -- --label candidate --round 1
MIX_ENV=test mix run bench/multiline_indent.exs -- --summarize bench/multiline_indent
```

Baseline: `4888e28659567ef651a3f7e75dacd1e9d3e94828` (`main` at `082783a6e` plus the benchmark and contract tests). Candidate: `4b4cadc9448fd794e53b21c639de92065026515d`. Both ran from clean trees in separate worktrees with the same build mode (`MIX_ENV=test`) on an Apple M1 (8 schedulers), macOS 27.2, Elixir 1.20.5, OTP 29. Rounds ran in ABBA order: candidate, baseline, baseline, candidate, with a 240 s cap on each phase. Baseline round 2 skipped the two 100,000-line cells, because round 1 had already shown that they exceed the cap. Raw samples are in `bench/multiline_indent/*.json`.

The fixture is a deterministic 100,000-line, 3.3 MB document (SHA-256 `9f39b0ae…`). It repeats ten line shapes: blank lines, whitespace-only lines, Unicode (Latin-1, CJK, Devanagari, Thai, emoji), tab-indented lines, lines indented with 2, 4, 6, or 8 spaces, and mixed tab-then-space indentation. The single-line case targets a 4-space line in the middle of the document. Larger selections are centered in the document.

Each sample uses a fresh buffer process and a fresh caller process. The caller runs the real `MingaEditor.Commands.Editing.execute/2` command with a Visual Line selection, then calls `Buffer.undo/1` and `Buffer.redo/1` exactly as the Editor does. The text is checked after each phase. The benchmark records two times. The first is when the call returns (`edit_us`). The second, `*_complete_us` and `settle_us`, is when the buffer has drained everything the call queued, including the `:buffer_changed` events. A phase still running at the cap is killed and recorded as `aborted`. Percentiles are nearest rank over the raw samples. Cells with 1 and 1,000 lines have one unrecorded warm-up sample.

## Results

Times are p10/p50/p90 in milliseconds. Undo and redo are measured to buffer completion. "Exit" means that the Editor-side `GenServer.call` would have exited at 5 s in every sample.

### Core cells, 4-space indentation

| Selection | Op | n (B/C) | Edit, baseline | Edit, candidate | Undo, baseline | Undo, candidate | Redo, baseline | Redo, candidate |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | `>` | 42/42 | 0.31/0.39/0.55 | 0.33/0.42/0.81 | 9.1/9.9/11.5 | 9.1/9.8/14.9 | 9.6/10.4/12.0 | 9.8/10.3/14.8 |
| 1 | `<` | 42/42 | 0.07/0.08/0.11 | 0.31/0.43/0.74 | 31.5/33.1/37.1 | 9.0/9.6/14.1 | 31.2/32.1/36.5 | 9.6/12.2/15.2 |
| 1,000 | `>` | 14/14 | 1,812/2,007/2,112 | 5.2/5.8/8.3 | 6,269/6,657/6,871 (exit) | 10.5/11.4/16.9 | 6,456/6,601/6,947 (exit) | 9.2/9.6/13.6 |
| 1,000 | `<` | 14/14 | 1,227/1,278/1,363 | 4.5/5.2/7.7 | 13,082/13,573/14,624 (exit) | 10.7/11.3/17.4 | 13,121/13,423/14,794 (exit) | 9.4/9.6/15.5 |
| 10,000 | `>` | 6/6 | 24,123/24,862/32,361 | 31.9/32.5/77.0 | 68,162/68,775/78,538 (exit) | 13.0/13.1/21.6 | 72,139/74,650/80,313 (exit) | 9.5/9.9/15.2 |
| 10,000 | `<` | 6/6 | 15,869/16,247/18,266 | 26.7/28.3/36.3 | 141,132/153,189/161,192 (exit) | 12.6/13.2/26.6 | 151,088/155,738/172,692 (exit) | 9.4/9.5/16.8 |
| 100,000 | `>` | 1/2 | aborted at 240 s | 437/660 | not reached | 12.5/19.5 | not reached | 7.9/12.6 |
| 100,000 | `<` | 1/2 | 161,872 | 427/578 | aborted at 240 s | 11.7/20.7 | not reached | 7.2/11.4 |

The 100,000-line candidate cells list both samples.

### Indentation widths

| Selection | Op | Style | Edit p50, B → C | Undo p50, B → C | Redo p50, B → C |
|---:|---|---|---:|---:|---:|
| 1 | `>` | 2 spaces | 0.40 → 0.41 | 10.7 → 9.6 | 11.3 → 10.1 |
| 1 | `<` | 2 spaces | 0.07 → 0.41 | 20.5 → 9.7 | 19.0 → 10.3 |
| 1 | `>` | tabs (width 8) | 0.36 → 0.41 | 10.6 → 10.2 | 11.3 → 13.4 |
| 1 | `<` | tabs (width 8) | 0.09 → 0.41 | 36.6 → 10.1 | 36.3 → 10.8 |
| 1,000 | `>` | 2 spaces | 2,191 → 6.0 | 7,057 (exit) → 11.2 | 6,994 (exit) → 9.7 |
| 1,000 | `<` | 2 spaces | 1,274 → 5.7 | 9,063 (exit) → 9.6 | 9,106 (exit) → 9.5 |
| 1,000 | `>` | tabs (width 8) | 2,185 → 5.6 | 7,269 (exit) → 11.4 | 7,249 (exit) → 9.8 |
| 1,000 | `<` | tabs (width 8) | 1,344 → 5.8 | 17,747 (exit) → 10.1 | 17,847 (exit) → 9.6 |

### Work, memory, and history

Values are p50 per sample. Reductions are the buffer process's reductions for the edit. "GC words" is the system-wide garbage-collector reclaim across the edit, which approximates allocation. Retained undo is the undo history's heap words plus the binaries it owns.

| Cell | Buffer reductions, B → C | GC words, B → C | Retained undo, B → C | Versions / deltas, B → C | Undo entries |
|---|---:|---:|---:|---:|---:|
| `>` 1 | 19.6 k → 15.8 k | 687 → 942 | 336 B → 424 B | 1 → 1 | 1 → 1 |
| `<` 1 | 3.0 k → 15.8 k | 417 → 1,097 | 768 B → 416 B | 4 → 1 | 1 → 1 |
| `>` 1,000 | 316 M → 0.46 M | 301 M → 0.58 M | 144 KB → 71 KB | 1,000 → 1,000 | 1 → 1 |
| `<` 1,000 | 253 M → 0.44 M | 243 M → 0.54 M | 288 KB → 65 KB | 2,000 → 800 | 1 → 1 |
| `>` 10,000 | 3,188 M → 1.6 M | 3,025 M → 4.2 M | 1.44 MB → 0.71 MB | 10,000 → 10,000 | 1 → 1 |
| `<` 10,000 | 2,549 M → 1.4 M | 2,451 M → 3.8 M | 2.88 MB → 0.65 MB | 20,000 → 8,000 | 1 → 1 |
| `>` 100,000 | aborted → 13.5 M | aborted → 36.6 M | n/a → 7.0 MB | n/a → 100,000 | n/a → 1 |
| `<` 100,000 | 25,424 M → 11.7 M | 24,525 M → 33.0 M | 28.8 MB → 6.4 MB | 200,000 → 80,000 | 1 → 1 |

Indent deltas are the same as before: one insertion at the start of each line, with the same bytes and positions. Dedent now sends one deletion per line instead of one per removed character. The deletions cover the same bytes and replay to the same text, and each delta still advances the version once. Settle time, which is mostly the queued change events, fell at every multiline size. For example, `<` over 10,000 lines dropped from 9.1 ms to 1.3 ms (p50). Single-line settle time stayed within 0.03 to 0.06 ms of baseline.

## Regressions

**Single-line `<` edit: 0.08 → 0.43 ms (p50) on a 3.3 MB document.** The old path removed indentation with `Document.delete_at/1`, which only drops bytes after the gap. The new path writes the replacement span after the text before the gap. When that text is not appendable, the BEAM copies it, about 1.6 MB here. A single-line `>` has always paid this same copy (0.39 ms before, 0.42 ms after). The cost grows with the bytes before the cursor, not with the selection, and it is well under a frame. The same `<` now undoes in 9.6 ms instead of 33 ms, because the old path recorded one patch per removed character. As a result, a single-line `<` followed by undo is faster overall in every width tested.

**Single-line `>`, tail.** p50 changed from 0.39 to 0.42 ms, inside the run-to-run spread. The single-line candidate p90 is wider in both edit (0.81 vs 0.55 ms) and undo (14.9 vs 11.5 ms). The candidate undo applies the same single patch the baseline undo does. The wider p90 appears in both candidate rounds, but it is not tied to a phase that changed, so it is recorded here and not explained further.

**Retained undo for a single-line `>`: 336 → 424 bytes.** The single patch now holds the line's old and new text instead of only the inserted indent.

## Contract evidence

Every item in the ticket's Required contract is checked at the consumer boundary. All checks pass on both the baseline (control) and the candidate.

- `test/minga_editor/commands/editing_shift_lines_test.exs` runs the real command with real buffers. It checks blank, Unicode, tab, and mixed lines; configured widths; tabs versus spaces; cursor placement, including a cursor inside removed indentation; one undo step with the cursor restored to the first shifted line; redo; and one step after an earlier edit. It checks that the deltas replay to the new text, one line start at a time. It checks one `:buffer_changed` event per line, each with a newer version and sequence. It also checks that highlights move with their text, that a selection with nothing to dedent makes no edit or version change, and that read-only buffers are unchanged.
- `test/minga_editor/shift_lines_keys_test.exs` drives real keys: `3>>`, dot repeat, undo per shift, and Visual Line `>` and `<`.
- Property tests check that `Operation.shift_lines/4` matches a line-by-line reference, replays its deltas, and undoes in one patch for any gap position and pending line index. `Document.replace_line_span/4` matches a rebuilt document, and `ChangeLog.record_changes/2` matches recording each delta in turn, including past the retention cap.

Mutation checks against the candidate confirmed that the new tests fail when the contract breaks:

- Advancing the version once per batch fails the event test.
- Dropping the per-delta byte offset fails both replay tests.
- Skipping the cursor move before the edit fails the undo-cursor test.
- Sending one spanning delta instead of per-line deltas fails the replay, event, and highlight tests.

## Limits

- The benchmark measures the BEAM command path, not frontend presentation or parser and LSP processing of the deltas. Above 1,000 deltas, change-log consumers still fall back to a full sync (`:reset_required`), exactly as before. A single spanning delta would keep them incremental, but it would also change how decorations inside the selection are adjusted. That trade-off needs its own decision.
- The 100,000-line candidate edit is one 0.43 to 0.66 s call. That is inside the 5 s call timeout on this machine, but it is a blocking call to the buffer.
- The separate `:dedent_line` command ("Dedent line", not the `<` operator) still deletes one character at a time. It was out of scope.
