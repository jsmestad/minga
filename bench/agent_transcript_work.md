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
