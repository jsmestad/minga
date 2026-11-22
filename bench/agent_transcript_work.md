# Active Agent transcript work baseline

At 10,000 retained entries, changing one streaming message returned 10,001 entries from Session and sent only 111 transcript bytes to the frontend. The wire delta did not make the producer incremental: the Editor rebuilt about 149 KB of Markdown and the renderer visited all 10,000 input entries. Revising a tool result in the middle sent 175,128 transcript bytes because the encoder sent the changed suffix. [#3611](https://github.com/jsmestad/minga/issues/3611) tracks the producer repair design.

## Reproduce

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test MINGA_BENCH_TRANSCRIPT_WORK=1 mix run bench/keystroke_latency_baseline.exs
```

Measured on Apple M1 arm64, macOS 27.2, Elixir 1.20.5/OTP 29.1.2 with `ERL_FLAGS='+S 4:4'`, against `3e698863e209412692c2967f782d935f3b6fda84`. The optimized BEAM runs the normal semantic GUI encoder at 220×60 and commits through `HeadlessPort`. The fixture holds a real admitted Native request open at its transport boundary. It creates exactly 100 or 10,000 Session entries, including an active tool at the midpoint, through request-bound provider events. The tool result and subsequent collapse and pin changes address that same entry. No tool executes and no provider HTTP request is made.

The work probe takes one observation of each mutation at each size. It counts actual Session calls from the Editor. Returned entries count logical entry versions from the change query plus the full snapshot when both are used. Display entries count inputs to transcript display, Markdown bytes count the assembled display string, and restyled counts misses that run assistant or tool-result styling. Chat visits and encoded entries count inputs at their respective stages for the selected committed frame; the encoder can inspect an extra entry for the editor notice. Transcript bytes include the resident command's opcode and length field; frame bytes include all encoded frame commands, but not the outer port envelope. A pin within the displayed history can change Session metadata without sending new transcript bytes.

Probes run only in the diagnostic mode. The separate non-traced latency run from [#3854](https://github.com/jsmestad/minga/pull/3854) measures typing while real text batches are forwarded. Neither run measures physical presentation, hosted model latency, or provider caching.

## Observed counts

| Entries | Mutation | Session calls | Entries returned | Display entries | Markdown bytes | Restyled | Chat visits | Encoder entries | Transcript bytes | Frame bytes |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | Tail text | 2 | 101 | 100 | 1,328 | 1 | 100 | 101 | 109 | 677 |
| 100 | Middle result | 2 | 101 | 100 | 1,359 | 1 | 100 | 101 | 1,780 | 2,329 |
| 100 | Collapse | 2 | 101 | 100 | 1,359 | 1 | 100 | 101 | 1,780 | 2,329 |
| 100 | Pin | 2 | 100 | 100 | 1,359 | 0 | 100 | 0 | 0 | 549 |
| 10,000 | Tail text | 2 | 10,001 | 10,000 | 148,926 | 1 | 10,000 | 10,001 | 111 | 679 |
| 10,000 | Middle result | 2 | 10,001 | 10,000 | 148,957 | 1 | 10,000 | 10,001 | 175,128 | 175,677 |
| 10,000 | Collapse | 2 | 10,001 | 10,000 | 148,957 | 1 | 10,000 | 10,001 | 175,128 | 175,677 |
| 10,000 | Pin | 2 | 10,000 | 10,000 | 148,957 | 0 | 10,000 | 0 | 0 | 549 |

The benchmark writes the individual observations as JSON to the path it prints. The first exploratory attempt traced both the preceding and target render, so its transcript bytes sometimes exceeded the selected frame size. The recorded run matches renderer work to the selected frame sequence, checks that the headless frontend accepted it, and rejects impossible byte totals. History setup drains the event log between batches so startup saturation does not contaminate the mutations.

## Renderer transfer after #3856

The Editor now sends the renderer only the exact display changes, and the renderer derives and sizes only changed entries. A one-entry update transfers the same number of flat BEAM words at 100 and at 10,000 retained entries. The GUI adapter still enumerates and encodes the whole selected resident suffix; [#3857](https://github.com/jsmestad/minga/issues/3857) owns that wire work.

The same command collects these counts. The fixture pads seeded text to a fixed width, so matched updates carry identical bodies at both sizes. Measured on Apple M1 arm64 with `ERL_FLAGS='+S 4:4'`.

- **Kinds** are the transcript updates admitted in the window (`unchanged` or `changes`); no case sends a seed.
- **Entries** counts keyed entry payloads transferred.
- **Words** is the flat size of the largest transcript-bearing submission, including chrome.
- **Derived / Sized** count renderer conversions and wire-size calls. Footer and decoration re-derivations were zero in every case.
- **Index visits / copies** count resident trie nodes. The bound is `4 × (K+B+1) × (H+1)`, with `H` 7 at 100 entries and 14 at 10,000. Cap evictions were zero; the append admitted one new entry.
- **Adapter entries** counts entries enumerated at the unmigrated adapter boundary, once per rendered frame in the window.

| Entries | Mutation | Kinds | Entries | Words | Derived / Sized | Index visits / copies (bound) | Adapter entries | Encoder entries |
|---:|---|---|---:|---:|---:|---:|---:|---:|
| 100 | Tail text | unchanged, changes | 1 | 30,520 | 1 / 1 | 10 / 7 (64) | 200 | 101 |
| 100 | Middle result | unchanged ×2, changes | 1 | 30,506 | 1 / 1 | 10 / 7 (64) | 300 | 101 |
| 100 | Collapse | unchanged, changes | 1 | 30,506 | 1 / 1 | 10 / 7 (64) | 200 | 101 |
| 100 | Pin in display | unchanged ×2 | 0 | 30,409 | 0 / 0 | 0 / 0 | 200 | 0 |
| 100 | Append, all pinned | unchanged, changes | 1 | 35,622 | 1 / 1 | 10 / 7 (96) | 201 | 102 |
| 100 | Composer only | unchanged | 0 | 35,596 | 0 / 0 | 0 / 0 | 101 | 0 |
| 10,000 | Tail text | unchanged, changes | 1 | 30,520 | 1 / 1 | 17 / 14 (120) | 20,000 | 10,001 |
| 10,000 | Middle result | unchanged ×2, changes | 1 | 30,506 | 1 / 1 | 17 / 14 (120) | 30,000 | 10,001 |
| 10,000 | Collapse | unchanged, changes | 1 | 30,506 | 1 / 1 | 17 / 14 (120) | 20,000 | 10,001 |
| 10,000 | Pin in display | unchanged ×2 | 0 | 30,409 | 0 / 0 | 0 / 0 | 20,000 | 0 |
| 10,000 | Append, all pinned | unchanged, changes | 1 | 35,622 | 1 / 1 | 17 / 14 (180) | 20,001 | 10,002 |
| 10,000 | Composer only | unchanged | 0 | 35,596 | 0 / 0 | 0 / 0 | 10,001 | 0 |

The paired active-session keystroke run (`MINGA_BENCH_ACTIVE_AGENT=1`, 120 inputs per size) measured p50/p99 of 4.224/10.241 ms at 100 entries and 187.805/1,777.889 ms at 10,000 on the base commit `022b4abe3`, against 3.832/10.329 ms and 41.365/1,725.153 ms with this change. At 10,000 entries the adapter still encodes every resident entry whenever the transcript changes (encoder entries above), which #3857 owns.
