# Protocol decode cost per frame

Receipt for [#3654](https://github.com/jsmestad/minga/issues/3654), updated for [#3906](https://github.com/jsmestad/minga/issues/3906). Decode is not a small share of arrival-to-publish on any frame type: it is 29% to 84% at p95, far above the proposed 5% threshold. The first receipt found that a 50,000-line window-content keyframe spent 86% of its 170 ms decode building the resident row store index. #3908 built that index in one pass, and the window-content row reader change in #3906 then read rows straight from the packet bytes. Together they take the keyframe decode p95 from 170.10 ms to 15.67 ms, under the 30 ms target of #3906. For row deltas and Agent transcript frames, nothing changed: reading the wire through the `Data` helpers is still the largest single part, and per-reservation resource accounting is the second.

## Changes since the first receipt

Each column is a separate measurement with this receipt's method. The first column is the original receipt at `26ebfa8`. The second is `9776bde`, after [#3908](https://github.com/jsmestad/minga/pull/3908) built the resident row index in one pass. The third is `bae9ab7`, after the #3906 row reader change described below. The second and third columns replay the same fresh captures with the same harness build settings. Each cell is the median of five per-run percentiles, in milliseconds.

| Frame type | Decode p95: `26ebfa8` | Decode p95: `9776bde` (#3908) | Decode p95: `bae9ab7` (#3906) | Arrival to publish p95: `26ebfa8` | Arrival to publish p95: `9776bde` (#3908) | Arrival to publish p95: `bae9ab7` (#3906) |
|---|---|---|---|---|---|---|
| Window content, 50,000-line keyframe | 170.10 | 31.47 | 15.67 | 202.58 | 40.44 | 25.52 |
| Window content, 2,000-line keyframe | 12.06 | 3.85 | 1.08 | 13.25 | 4.91 | 1.81 |
| Row delta, scroll | 0.0155 | 0.0155 | 0.0158 | 0.0556 | 0.0535 | 0.0540 |
| Row delta, typing | 0.0182 | 0.0181 | 0.0183 | 0.0664 | 0.0625 | 0.0616 |
| Agent transcript replace, 10,002 messages | 6.15 | 10.39 | 7.38 | 8.78 | 12.36 | 8.73 |
| Agent transcript delta, streaming | 0.0301 | 0.0304 | 0.0303 | 0.0705 | 0.0721 | 0.0701 |

The #3906 row reader change touches only the window-content row decoder, which row deltas also use for their full rows. Its effects:

- **50,000-line keyframe:** decode p50 falls from 30.44 ms to 14.78 ms and p95 from 31.47 ms to 15.67 ms. An earlier pair of five-run measurements of the same two builds gave 30.32 ms and 14.51 ms at p95.
- **Row deltas and Agent frames:** no change beyond run-to-run noise. Row-delta medians moved by at most 0.0003 ms. Agent frames do not use the changed code. Their p95 differences between columns are machine noise: the earlier pair measured the Agent transcript replace p95 at 6.89 ms at `9776bde` and 6.49 ms at `bae9ab7`.
- **2,000-line keyframe:** the `9776bde` runs were bimodal (decode p95 1.19 ms to 3.94 ms across runs). The earlier pair gave 1.74 ms and 1.00 ms.

### What the row reader change did

Before the change, `decodeWindowContentRows` built every row's text with `String(bytes:encoding:)` over a `Data` slice, read every integer field through a new `ByteCursor` over `Data`, and read the `@TaskLocal` accounting builder on every reservation, several times per row. A `sample` of the `9776bde` keyframe attributed about 80% of the remaining decode to that row reading.

Now the row decoder reads a whole row section through one borrowed byte buffer and decodes text with `String(validating:as:)`. It keeps the previous text exactly: one leading byte order mark is dropped, as Foundation did, and invalid UTF-8 still becomes an empty row after its wire bytes are reserved. Every read stays behind the same explicit section guards, so malformed rows fail with the same errors. The accounting builder is resolved once per row section through `FrameDecodeAccounting.currentUsage`, and reservations keep their order and amounts. `WindowRowDecodeTests` pins all of that, and passed against the previous decoder before the change.

## What was measured

| Term | Meaning |
|---|---|
| Arrival | The protocol reader thread holds the complete payload. This is the point of the existing `ProtocolPayloadReceived` signpost. |
| Decode | The production `decodeFrame(from:)` call on the reader thread, measured around the call. The decoder's own `FrameDecodeMetrics.decodeDuration` is reported beside it and agrees to within 0.0006 ms at p50 on small frames and 0.01 ms on keyframes. |
| Handoff | Decode end to the start of main-thread dispatch, through the production `ProtocolEventHandoff` and `MainRunLoopAction`. |
| Dispatch to publish | Main-thread dispatch start to the `.applied` transaction result, which `CommandDispatcher` reports right after `FramePublish` ends. |
| Arrival to publish | Arrival to the `.applied` result: decode, handoff, and dispatch to publish for the same packet. |

## Method

1. `MIX_ENV=test mix run bench/frame_staging_capture.exs DIR` captured the packets that a real Editor sends to a native GUI frontend at 220x60 for three workloads, as in the [frame staging receipt](frame_staging_main_thread.md). The current capture ran at `9776bde`, after #3904, so the Agent stream sends transcript deltas instead of a full replace per chunk. No Elixir code changed between `9776bde` and `bae9ab7`, so both builds replay the same packets.
2. `NativeRenderPerformance --protocol-decode-replay` writes the captured packets into a pipe and reads them with the production `ProtocolReader` on its own thread. The reader decodes each payload with the production `decodeFrame` and hands it to the main thread through the production `ProtocolEventHandoff`. The main thread runs its run loop and dispatches each frame to the production `CommandDispatcher`. The replay timestamps arrival and decode end in the reader's decoder closure, and dispatch start and the `.applied` result on the main thread. Any rejected frame fails the replay.
3. A keyframe arrives once per session. To get a distribution for keyframes, every run also replays each capture's largest window-content packet and largest transcript-replace packet in 30 fresh sessions. Each session dispatches the packets before the keyframe untimed and records only the keyframe.
4. `scripts/measure_protocol_decode` runs five runs, with the three workloads interleaved within each run. Each cell below is the median of the five per-run percentiles, with the lowest and highest run in parentheses.
5. `scripts/measure_protocol_decode --profile` runs `--protocol-decode-loop`, a decode-only loop over one frame type's packets, under `sample` for 10 seconds per frame type. The script attributes every sample below `decodeFrame` to one component (see [Where decode time goes](#where-decode-time-goes)).

The harness is the Release configuration (`-O`, whole module) with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=MINGA_SNAPSHOT_RENDERER`. `MINGA_TRANSCRIPT_ACCOUNTING` is off because the shipping app does not set it.

Current figures: capture at `9776bde63e1254922f61824e3d17b30f093d53f1`, harness at `bae9ab73fe3063a91aca492d59ae108cf019716e`, with the `9776bde` harness for the comparison column. The first receipt used `26ebfa8715b0d212c814ad744f9e69c07cab95d1` for capture and harness. Machine: Apple M1, 16 GB, macOS 27.2, Xcode 27.2 (Swift 6.4.2), Elixir 1.20.5 / OTP 29.

| Frame type | Source | Packet size | Frames per run |
|---|---|---|---:|
| Window content, 50,000-line keyframe | `scroll` capture: full-document resident store of a 50,000-line, 2,026,679-byte Elixir file | 3,647,591 bytes | 30 repeats |
| Window content, 2,000-line keyframe | `typing` capture: full-document resident store of a 2,000-line, 77,876-byte Elixir file | 143,588 bytes | 30 repeats |
| Row delta, scroll | `scroll` capture: measured trackpad `scroll_batch` intents of 3 lines | 880 bytes | 300 |
| Row delta, typing | `typing` capture: measured printable keys in Insert mode | 1,055 to 1,355 bytes (p50 1,205) | 300 |
| Agent transcript replace, 10,002 messages | `agent_stream` capture: the transcript seed of a session with 10,000 retained entries, `gui_agent_transcript` mode 0 | 429,626 bytes | 30 repeats |
| Agent transcript delta, streaming | `agent_stream` capture: measured streamed text chunks, two messages per delta | 1,367 to 4,789 bytes (p50 3,042) | 100 |

## Results

Times are wall-clock milliseconds, at `bae9ab7`.

| Frame type | Decode p50 | Decode p95 | Arrival to publish p50 | Arrival to publish p95 |
|---|---|---|---|---|
| Window content, 50,000-line keyframe | 14.78 (12.88 to 15.09) | 15.67 (15.39 to 15.76) | 24.35 (22.12 to 24.61) | 25.52 (25.22 to 27.98) |
| Window content, 2,000-line keyframe | 0.6754 (0.5443 to 1.2820) | 1.08 (0.59 to 2.05) | 1.21 (0.92 to 2.12) | 1.81 (1.02 to 3.34) |
| Row delta, scroll | 0.0145 (0.0140 to 0.0146) | 0.0158 (0.0153 to 0.0159) | 0.0462 (0.0410 to 0.0465) | 0.0540 (0.0480 to 0.0559) |
| Row delta, typing | 0.0167 (0.0164 to 0.0171) | 0.0183 (0.0178 to 0.0190) | 0.0535 (0.0528 to 0.0570) | 0.0616 (0.0610 to 0.0693) |
| Agent transcript replace, 10,002 messages | 6.13 (6.11 to 6.14) | 7.38 (6.41 to 7.71) | 7.35 (7.32 to 7.36) | 8.73 (7.66 to 9.15) |
| Agent transcript delta, streaming | 0.0240 (0.0240 to 0.0247) | 0.0303 (0.0297 to 0.0307) | 0.0607 (0.0594 to 0.0636) | 0.0701 (0.0700 to 0.0867) |

The rest of arrival to publish:

| Frame type | Decode metric p50 | Handoff p50 | Dispatch to publish p50 | Dispatch to publish p95 |
|---|---|---|---|---|
| Window content, 50,000-line keyframe | 14.78 (12.88 to 15.08) | 0.0452 (0.0434 to 0.0481) | 9.41 (9.01 to 9.52) | 9.84 (9.70 to 14.69) |
| Window content, 2,000-line keyframe | 0.6741 (0.5436 to 1.2797) | 0.0165 (0.0145 to 0.0277) | 0.4622 (0.3606 to 0.8273) | 0.7065 (0.4124 to 1.1128) |
| Row delta, scroll | 0.0139 (0.0134 to 0.0140) | 0.0088 (0.0067 to 0.0088) | 0.0220 (0.0196 to 0.0221) | 0.0282 (0.0254 to 0.0298) |
| Row delta, typing | 0.0161 (0.0158 to 0.0163) | 0.0083 (0.0081 to 0.0097) | 0.0280 (0.0278 to 0.0293) | 0.0348 (0.0334 to 0.0357) |
| Agent transcript replace, 10,002 messages | 6.13 (6.10 to 6.14) | 0.0132 (0.0121 to 0.0157) | 1.21 (1.20 to 1.22) | 1.41 (1.29 to 1.83) |
| Agent transcript delta, streaming | 0.0235 (0.0234 to 0.0240) | 0.0082 (0.0079 to 0.0092) | 0.0270 (0.0262 to 0.0276) | 0.0350 (0.0334 to 0.0373) |

"Decode metric" is `FrameDecodeMetrics.decodeDuration`. It starts after the payload-size guard and the accounting setup, so it is slightly below the decode column on small frames.

## Decision gate at 5% (proposed, pending owner confirmation of the threshold)

The ticket's gate: no change if decode p95 is under 5% of arrival-to-publish on every frame type; otherwise promote, starting with the frame types that exceed it. The first column divides the two p95 figures of each run. The second takes the p95 of the per-frame ratio, which does not depend on how the two percentiles pair up.

| Frame type | Decode p95 / arrival-to-publish p95 | Per-frame decode share p95 | Under 5% | Arrival to publish at which decode p95 would reach 5% |
|---|---|---|---|---|
| Window content, 50,000-line keyframe | 61.5% (55.0 to 61.7) | 61.8% (61.5 to 61.9) | No | 313 ms |
| Window content, 2,000-line keyframe | 60.0% (57.4 to 61.5) | 61.4% (60.5 to 65.7) | No | 22 ms |
| Row delta, scroll | 29.1% (28.4 to 31.9) | 35.1% (34.9 to 36.1) | No | 0.32 ms |
| Row delta, typing | 28.9% (27.4 to 30.0) | 33.5% (32.8 to 34.1) | No | 0.37 ms |
| Agent transcript replace, 10,002 messages | 83.8% (79.9 to 84.6) | 83.8% (83.8 to 84.3) | No | 148 ms |
| Agent transcript delta, streaming | 42.8% (35.5 to 43.3) | 45.8% (45.7 to 46.9) | No | 0.61 ms |

**Gate outcome: Promote, on every frame type.** Both ratios exceed 5% on every run, before and after #3908 and #3906. The last column shows how robust that is: the replay's main thread is idle, so the app's arrival-to-publish is longer, but it would have to be 20 times the decode p95 for any frame type to pass. For row deltas that means more than 0.32 ms of main-thread queueing per frame.

## Where decode time goes

Self-time samples below `decodeFrame`, from the decode-only loop at `bae9ab7`. A sample belongs to the first component in this order whose frames appear between `decodeFrame` and the leaf:

| Component | Frames that select it |
|---|---|
| Model build | `GUIWindowContent.init`, `ResidentRowStore` |
| Resource accounting | `FrameDecodeAccounting.reserve`, `FrameResourceUsageBuilder`, Task-local lookup |
| UTF-8 strings | `decodeUTF8`, `readRequiredUTF8`, `String(bytes:encoding:)`, `String._tryFromUTF8` |
| Wire read helpers | `readU16`/`readU32`/`readU64`, `checkedCursor`, `ByteCursor`, `Data` subscripts |
| Allocation and ARC | Leaf in the allocator, retain/release, or array growth |
| Decoder bodies | Everything else: decode logic plus the byte reads the optimizer inlined |

| Frame type | Samples | Model build | Resource accounting | UTF-8 strings | Wire read helpers | Allocation and ARC | Decoder bodies |
|---|---:|---:|---:|---:|---:|---:|---:|
| Window content, 50,000-line keyframe | 4,485 | 34% | 15% | 0% | 0% | 10% | 40% |
| Window content, 2,000-line keyframe | 4,902 | 33% | 13% | 1% | 2% | 10% | 41% |
| Row delta, scroll | 6,665 | 0% | 10% | 15% | 44% | 7% | 24% |
| Row delta, typing | 6,332 | 0% | 10% | 14% | 42% | 8% | 25% |
| Agent transcript replace, 10,002 messages | 5,622 | 0% | 26% | 8% | 36% | 19% | 10% |
| Agent transcript delta, streaming | 5,932 | 0% | 20% | 26% | 30% | 9% | 15% |

In the first receipt, model build was 86% to 88% of window-content decode, and wire read helpers 7%. For window content, the row reader now inlines its byte reads and UTF-8 validation into the row decoder, so they count under "Decoder bodies". The remaining "Resource accounting" share is `FrameResourceUsageBuilder.reserve` itself, which still runs once per row and once per span; the keyframe profile has no task-local reads left.

What this means for reading through `Span`:

- **Window-content keyframes: already addressed without Span.** The first receipt found the index build at about 140 ms of the 203 ms arrival-to-publish at 50,000 lines, because `ResidentRowStore.indexChunks` inserted every row into the persistent locator table one at a time. #3908 builds that index in one pass. The #3906 row reader then removed most of the row-reading cost, so a 50,000-line keyframe now decodes in about 15 ms, of which about a third is the model build.
- **Row deltas and Agent transcript frames: Span addresses the largest part.** The wire read helpers build a new `ByteCursor` over `Data` for every integer (`checkedCursor`, `ProtocolDecoder.swift:4666`), and they are 30% to 44% of decode, plus an unknown part of the decoder bodies where reads were inlined. The upper bound of what a faster reader can remove is the sum of those two columns: 45% to 68% of decode, or about 0.01 ms per row delta and about 2.8 ms per 10,002-message transcript replace.
- **Resource accounting is a separate cost of 10% to 26%.** `FrameDecodeAccounting.reserve` reads the `@TaskLocal` usage builder on every call (`FrameResourcePolicy.swift:378-380`), and the transcript decoder reserves once per styled run and per line. The window-content row decoder already resolves the builder once per row section through `FrameDecodeAccounting.currentUsage`. The typed-throws and `borrowing Span` signature change would be the natural moment to pass the builder explicitly instead.

## Recommendation (proposed, pending owner confirmation of the threshold)

Promote, but not in the order the ticket proposes, and not as one ticket:

1. **Span implementation ticket for row deltas and Agent transcript frames**, with the Swift constraints listed in #3654. Start with row deltas (`decodeWindowRowsDelta` and its row and overlay sections) and the transcript decoders (`decodeAgentMarkdownBlocks`, `decodeAgentStyledLines`). Window content benefits from the same reader, but its row decoding is a small part of its cost.
2. **A separate ticket for the keyframe cost**: build the `ResidentRowStore` locator index in bulk from the sorted rows of a full replace instead of one persistent insert per row. This is the largest absolute cost measured here, and Span does not touch it.
3. Consider passing the accounting builder explicitly in the same change as item 1, because it touches the same signatures.

The absolute stakes differ sharply. A row delta spends about 0.015 ms in decode, so even a perfect reader saves about 0.01 ms per frame; a 50,000-line keyframe spent about 140 ms building its index. Item 2 shipped as #3908, and the window-content row reader of #3906 took the keyframe the rest of the way under 30 ms without the full Span change. Items 1 and 3 remain open.

## Measurement overhead

The replay adds four clock reads and one locked append per packet. The harness measures that cost in a tight loop at the start of every run: 55 to 91 ns per packet across all 15 runs at `bae9ab7`, which is 0.2% of the smallest arrival-to-publish (0.041 ms) and cannot change any gate outcome. Two independent clocks agree: the replay's own decode timing and the decoder's existing `decodeDuration` differ by at most 0.0006 ms at p50 on small frames and 0.01 ms on keyframes. Run-to-run spread (highest minus lowest run, over the median) was larger in the current measurements than in the first receipt. Decode p50 stayed within 7% for every frame type except the 2,000-line keyframe, which was bimodal in both builds (57% at `9776bde`, 109% at `bae9ab7`). Single runs moved some p95s by up to 36% (for example the Agent transcript replace decode p95 at `9776bde`, 6.88 ms to 10.62 ms), although that decoder did not change. The 50,000-line keyframe decode p95 stayed within 2% across runs in both builds. This is why the comparison above relies on medians and on the earlier repeat pair, and why the target is judged on the 50,000-line keyframe.

The profile uses a separate decode-only loop, so `sample` does not perturb the timed runs.

## Limits

- **Replay, not the shipping app.** The pipeline is the production reader, handoff, decoder, and dispatcher, but the main thread does nothing else and no SwiftUI view observes `GUIState`. In the app, handoff waits behind rendering and input, and publish may notify observers, so arrival-to-publish is longer and the decode share is lower. The gate column above shows how much longer it would have to be.
- **Reader and main thread do not overlap.** The single-slot handoff holds the next read until the main thread finishes a frame, as in the app, and the BEAM's pacing between frames is absent. Arrival-to-publish here never includes waiting for an earlier frame.
- **Capture environment.** As in the frame staging receipt, the capture runs under `MIX_ENV=test`, where the parser is not running, so rows carry no tree-sitter highlight spans. Highlighted rows add spans to keyframes and row deltas and would raise their decode time somewhat.
- **No viewport-sized window content.** Both window-content packets are full-document resident stores, because the captured buffers are neither wrapped nor folded. A windowed `gui_window_content` for a wrapped or folded buffer would be about 60 rows and was not measured.
- **Keyframes are repeated, not captured 30 times.** Each repeat decodes the same packet in a fresh session, so caches are warmer than for a keyframe that arrives once.
- **Profile attribution is approximate.** Byte reads that the optimizer inlined into decoder functions appear under "Decoder bodies", not "Wire read helpers". One machine (Apple M1), five runs.

## Reproduce

```sh
MIX_ENV=test mix run bench/frame_staging_capture.exs _build/protocol-decode-evidence/captures
scripts/check_native_render_performance --build _build/native-render-performance
scripts/measure_protocol_decode --build _build/native-render-performance --captures _build/protocol-decode-evidence/captures --runs 5 --output _build/protocol-decode-evidence/runs
scripts/measure_protocol_decode --profile --build _build/native-render-performance --captures _build/protocol-decode-evidence/captures --output _build/protocol-decode-evidence/profile
```

`--report-only --output DIR` rebuilds `summary.json` and `frames.csv` from an existing run directory.

## Raw data

`protocol_decode/summary.json` holds each run's percentiles for every frame type and the per-run instrumentation cost at `bae9ab7`, and `protocol_decode/summary-9776bde.json` holds the same for the `9776bde` comparison column. `protocol_decode/frames.csv` holds every measured frame of every run at `bae9ab7`: packet size, decode, decoder metric, handoff, dispatch to publish, and arrival to publish. `protocol_decode/profile.json` holds the component shares. The `*.capture.json` files are the capture manifests. The packet captures (6.1 MB), the per-run replay JSON (2.1 MB per build), and the `sample` call graphs (3.8 MB) are kept outside the repository in the worktree's ignored `_build/protocol-decode-evidence/` directory and can be regenerated with the commands above.
