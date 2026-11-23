# Protocol decode cost per frame

Receipt for [#3654](https://github.com/jsmestad/minga/issues/3654). Decode is not a small share of arrival-to-publish on any frame type: it is 27% to 92% at p95, far above the proposed 5% threshold. The cost is not mainly byte reading, though. For window-content keyframes, 86% to 88% of decode time builds the resident row store index, and reading the wire is about 8%. For row deltas and Agent transcript frames, reading the wire through the `Data` helpers is the largest single part, and per-reservation resource accounting is the second.

## What was measured

| Term | Meaning |
|---|---|
| Arrival | The protocol reader thread holds the complete payload. This is the point of the existing `ProtocolPayloadReceived` signpost. |
| Decode | The production `decodeFrame(from:)` call on the reader thread, measured around the call. The decoder's own `FrameDecodeMetrics.decodeDuration` is reported beside it and agrees to within 0.0006 ms at p50 on small frames and 0.01 ms on keyframes. |
| Handoff | Decode end to the start of main-thread dispatch, through the production `ProtocolEventHandoff` and `MainRunLoopAction`. |
| Dispatch to publish | Main-thread dispatch start to the `.applied` transaction result, which `CommandDispatcher` reports right after `FramePublish` ends. |
| Arrival to publish | Arrival to the `.applied` result: decode, handoff, and dispatch to publish for the same packet. |

## Method

1. `MIX_ENV=test mix run bench/frame_staging_capture.exs DIR` captured the packets that a real Editor sends to a native GUI frontend at 220x60 for three workloads, as in the [frame staging receipt](frame_staging_main_thread.md). The capture ran at this revision, after #3904, so the Agent stream sends transcript deltas instead of a full replace per chunk.
2. `NativeRenderPerformance --protocol-decode-replay` writes the captured packets into a pipe and reads them with the production `ProtocolReader` on its own thread. The reader decodes each payload with the production `decodeFrame` and hands it to the main thread through the production `ProtocolEventHandoff`. The main thread runs its run loop and dispatches each frame to the production `CommandDispatcher`. The replay timestamps arrival and decode end in the reader's decoder closure, and dispatch start and the `.applied` result on the main thread. Any rejected frame fails the replay.
3. A keyframe arrives once per session. To get a distribution for keyframes, every run also replays each capture's largest window-content packet and largest transcript-replace packet in 30 fresh sessions. Each session dispatches the packets before the keyframe untimed and records only the keyframe.
4. `scripts/measure_protocol_decode` runs five runs, with the three workloads interleaved within each run. Each cell below is the median of the five per-run percentiles, with the lowest and highest run in parentheses.
5. `scripts/measure_protocol_decode --profile` runs `--protocol-decode-loop`, a decode-only loop over one frame type's packets, under `sample` for 10 seconds per frame type. The script attributes every sample below `decodeFrame` to one component (see [Where decode time goes](#where-decode-time-goes)).

The harness is the Release configuration (`-O`, whole module) with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=MINGA_SNAPSHOT_RENDERER`. `MINGA_TRANSCRIPT_ACCOUNTING` is off because the shipping app does not set it.

Revision `26ebfa8715b0d212c814ad744f9e69c07cab95d1` for capture and harness; the harness adds only the replay and loop modes, which change no production code. Machine: Apple M1, 16 GB, macOS 27.2, Xcode 27.2 (Swift 6.4.2), Elixir 1.20.5 / OTP 29.

| Frame type | Source | Packet size | Frames per run |
|---|---|---|---:|
| Window content, 50,000-line keyframe | `scroll` capture: full-document resident store of a 50,000-line, 2,026,679-byte Elixir file | 3,647,591 bytes | 30 repeats |
| Window content, 2,000-line keyframe | `typing` capture: full-document resident store of a 2,000-line, 77,876-byte Elixir file | 143,588 bytes | 30 repeats |
| Row delta, scroll | `scroll` capture: measured trackpad `scroll_batch` intents of 3 lines | 880 bytes | 300 |
| Row delta, typing | `typing` capture: measured printable keys in Insert mode | 1,055 to 1,355 bytes (p50 1,205) | 300 |
| Agent transcript replace, 10,002 messages | `agent_stream` capture: the transcript seed of a session with 10,000 retained entries, `gui_agent_transcript` mode 0 | 429,674 bytes | 30 repeats |
| Agent transcript delta, streaming | `agent_stream` capture: measured streamed text chunks, two messages per delta | 1,367 to 4,789 bytes (p50 3,042) | 100 |

## Results

Times are wall-clock milliseconds.

| Frame type | Decode p50 | Decode p95 | Arrival to publish p50 | Arrival to publish p95 |
|---|---|---|---|---|
| Window content, 50,000-line keyframe | 164.08 (163.88 to 164.43) | 170.10 (169.29 to 171.43) | 196.25 (195.89 to 196.57) | 202.58 (201.63 to 203.70) |
| Window content, 2,000-line keyframe | 9.84 (9.62 to 10.51) | 12.06 (11.64 to 12.92) | 10.77 (10.56 to 11.46) | 13.25 (12.83 to 14.07) |
| Row delta, scroll | 0.0144 (0.0144 to 0.0144) | 0.0155 (0.0152 to 0.0158) | 0.0473 (0.0471 to 0.0478) | 0.0556 (0.0543 to 0.0566) |
| Row delta, typing | 0.0165 (0.0164 to 0.0166) | 0.0182 (0.0180 to 0.0187) | 0.0584 (0.0579 to 0.0588) | 0.0664 (0.0653 to 0.0698) |
| Agent transcript replace, 10,002 messages | 6.02 (5.98 to 6.04) | 6.15 (6.11 to 6.24) | 8.53 (8.48 to 8.56) | 8.78 (8.75 to 9.02) |
| Agent transcript delta, streaming | 0.0241 (0.0238 to 0.0243) | 0.0301 (0.0295 to 0.0303) | 0.0622 (0.0605 to 0.0629) | 0.0705 (0.0695 to 0.0720) |

The rest of arrival to publish:

| Frame type | Decode metric p50 | Handoff p50 | Dispatch to publish p50 | Dispatch to publish p95 |
|---|---|---|---|---|
| Window content, 50,000-line keyframe | 164.08 (163.88 to 164.43) | 0.0558 (0.0513 to 0.0600) | 32.00 (31.78 to 32.46) | 33.00 (32.73 to 33.25) |
| Window content, 2,000-line keyframe | 9.83 (9.62 to 10.51) | 0.0191 (0.0182 to 0.0202) | 0.9103 (0.8855 to 0.9629) | 1.22 (1.06 to 1.58) |
| Row delta, scroll | 0.0138 (0.0138 to 0.0138) | 0.0095 (0.0093 to 0.0097) | 0.0224 (0.0221 to 0.0225) | 0.0291 (0.0282 to 0.0301) |
| Row delta, typing | 0.0159 (0.0158 to 0.0160) | 0.0085 (0.0084 to 0.0087) | 0.0324 (0.0321 to 0.0328) | 0.0403 (0.0387 to 0.0404) |
| Agent transcript replace, 10,002 messages | 6.02 (5.98 to 6.04) | 0.0132 (0.0128 to 0.0136) | 2.50 (2.48 to 2.53) | 2.65 (2.59 to 2.77) |
| Agent transcript delta, streaming | 0.0235 (0.0232 to 0.0238) | 0.0085 (0.0084 to 0.0086) | 0.0282 (0.0275 to 0.0287) | 0.0347 (0.0334 to 0.0357) |

"Decode metric" is `FrameDecodeMetrics.decodeDuration`. It starts after the payload-size guard and the accounting setup, so it is slightly below the decode column on small frames.

## Decision gate at 5% (proposed, pending owner confirmation of the threshold)

The ticket's gate: no change if decode p95 is under 5% of arrival-to-publish on every frame type; otherwise promote, starting with the frame types that exceed it. The first column divides the two p95 figures of each run. The second takes the p95 of the per-frame ratio, which does not depend on how the two percentiles pair up.

| Frame type | Decode p95 / arrival-to-publish p95 | Per-frame decode share p95 | Under 5% | Arrival to publish at which decode p95 would reach 5% |
|---|---|---|---|---|
| Window content, 50,000-line keyframe | 84.0% (84.0 to 84.4) | 84.0% (84.0 to 84.2) | No | 3,402 ms |
| Window content, 2,000-line keyframe | 91.7% (90.6 to 92.3) | 92.1% (91.9 to 92.2) | No | 241 ms |
| Row delta, scroll | 27.8% (27.5 to 28.6) | 34.0% (33.9 to 34.2) | No | 0.31 ms |
| Row delta, typing | 27.4% (26.2 to 28.3) | 31.0% (30.6 to 31.2) | No | 0.36 ms |
| Agent transcript replace, 10,002 messages | 69.7% (68.9 to 70.2) | 70.9% (70.7 to 71.2) | No | 123 ms |
| Agent transcript delta, streaming | 42.5% (41.6 to 43.4) | 46.3% (45.3 to 46.5) | No | 0.60 ms |

**Gate outcome: Promote, on every frame type.** Both ratios exceed 5% on every run. The last column shows how robust that is: the replay's main thread is idle, so the app's arrival-to-publish is longer, but it would have to be 20 times the decode p95 for any frame type to pass. For row deltas that means more than 0.31 ms of main-thread queueing per frame.

## Where decode time goes

Self-time samples below `decodeFrame`, from the decode-only loop. A sample belongs to the first component in this order whose frames appear between `decodeFrame` and the leaf:

| Component | Frames that select it |
|---|---|
| Model build | `GUIWindowContent.init`, `ResidentRowStore` |
| Resource accounting | `FrameDecodeAccounting.reserve`, `FrameResourceUsageBuilder`, Task-local lookup |
| UTF-8 strings | `decodeUTF8`, `readRequiredUTF8`, `String(bytes:encoding:)` |
| Wire read helpers | `readU16`/`readU32`/`readU64`, `checkedCursor`, `ByteCursor`, `Data` subscripts |
| Allocation and ARC | Leaf in the allocator, retain/release, or array growth |
| Decoder bodies | Everything else: decode logic plus the byte reads the optimizer inlined |

| Frame type | Samples | Model build | Resource accounting | UTF-8 strings | Wire read helpers | Allocation and ARC | Decoder bodies |
|---|---:|---:|---:|---:|---:|---:|---:|
| Window content, 50,000-line keyframe | 4,470 | 86% | 3% | 2% | 7% | 1% | 1% |
| Window content, 2,000-line keyframe | 4,486 | 88% | 2% | 2% | 7% | 1% | 1% |
| Row delta, scroll | 6,532 | 0% | 10% | 15% | 45% | 7% | 23% |
| Row delta, typing | 6,451 | 0% | 12% | 15% | 45% | 7% | 22% |
| Agent transcript replace, 10,002 messages | 5,733 | 0% | 25% | 9% | 35% | 20% | 11% |
| Agent transcript delta, streaming | 6,077 | 0% | 21% | 27% | 28% | 9% | 14% |

What this means for reading through `Span`:

- **Window-content keyframes: Span cannot move them much.** `GUIWindowContent.init` builds a `ResidentRowStore` on the reader thread, and `ResidentRowStore.indexChunks` inserts every row into the persistent locator table one at a time (`LocatorTable.setting`, `ResidentRowStore.swift:1094-1110`). Each insert copies a 32-slot node at each of 13 levels, so a 50,000-row keyframe allocates and copies about 650,000 nodes and then releases most of them. That index build is about 140 ms of the 203 ms arrival-to-publish at 50,000 lines. Wire reading is 7% of decode, about 12 ms.
- **Row deltas and Agent transcript frames: Span addresses the largest part.** The wire read helpers build a new `ByteCursor` over `Data` for every integer (`checkedCursor`, `ProtocolDecoder.swift:4586`), and they are 28% to 45% of decode, plus an unknown part of the decoder bodies where reads were inlined. The upper bound of what a faster reader can remove is the sum of those two columns: 42% to 68% of decode, or about 0.01 ms per row delta and about 2.8 ms per 10,002-message transcript replace.
- **Resource accounting is a separate cost of 10% to 25%.** `FrameDecodeAccounting.reserve` reads the `@TaskLocal` usage builder on every call (`FrameResourcePolicy.swift:375-377`), and the transcript decoder reserves once per styled run and per line. The typed-throws and `borrowing Span` signature change would be the natural moment to pass the builder explicitly instead.

## Recommendation (proposed, pending owner confirmation of the threshold)

Promote, but not in the order the ticket proposes, and not as one ticket:

1. **Span implementation ticket for row deltas and Agent transcript frames**, with the Swift constraints listed in #3654. Start with row deltas (`decodeWindowRowsDelta` and its row and overlay sections) and the transcript decoders (`decodeAgentMarkdownBlocks`, `decodeAgentStyledLines`). Window content benefits from the same reader, but its row decoding is a small part of its cost.
2. **A separate ticket for the keyframe cost**: build the `ResidentRowStore` locator index in bulk from the sorted rows of a full replace instead of one persistent insert per row. This is the largest absolute cost measured here, and Span does not touch it.
3. Consider passing the accounting builder explicitly in the same change as item 1, because it touches the same signatures.

The absolute stakes differ sharply. A row delta spends about 0.015 ms in decode, so even a perfect reader saves about 0.01 ms per frame; a 50,000-line keyframe spends about 140 ms building its index. If the owner wants the gate to weigh absolute time as well as share, item 2 comes first.

## Measurement overhead

The replay adds four clock reads and one locked append per packet. The harness measures that cost in a tight loop at the start of every run: 54 to 75 ns per packet across all 15 runs, which is 0.16% of the smallest arrival-to-publish (0.047 ms) and cannot change any gate outcome. Two independent clocks agree: the replay's own decode timing and the decoder's existing `decodeDuration` differ by at most 0.0006 ms at p50 on small frames and 0.01 ms on keyframes. Run-to-run spread (highest minus lowest run, over the median) is at most 4% for every p50 and 7% for every p95, except the 2,000-line keyframe, where it is 8% to 11%.

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

`protocol_decode/summary.json` holds each run's percentiles for every frame type and the per-run instrumentation cost. `protocol_decode/frames.csv` holds every measured frame of every run: packet size, decode, decoder metric, handoff, dispatch to publish, and arrival to publish. `protocol_decode/profile.json` holds the component shares. The `*.capture.json` files are the capture manifests. The packet captures (6.1 MB), the per-run replay JSON (2.1 MB), and the `sample` call graphs (19 MB) are kept outside the repository in the worktree's ignored `_build/protocol-decode-evidence/` directory and can be regenerated with the commands above.
