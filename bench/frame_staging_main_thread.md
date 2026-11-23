# Main-thread frame staging, freeze, and publish

Receipt for [#3652](https://github.com/jsmestad/minga/issues/3652). Staging is cheap for scrolling and typing: at most 0.014 ms at p95, about 60 times below the proposed 0.8 ms threshold. A long Agent conversation that streams is a different case. Every streamed text batch makes the BEAM send a full replace of the 10,000-entry transcript, and staging that replace takes about 360 ms on the main thread. Frames that carry only an append still take about 1 ms to stage at p95.

## What was measured

`CommandDispatcher` now emits three signpost intervals in the `com.minga.editor` subsystem, `Render` category, each with the message `frame=<frameSeq>`:

| Interval | Covers |
|---|---|
| `FrameStage` | Seeding the `PreparedFrameTransactionBuilder` at `begin_frame` and staging every command of the frame. One interval per frame and packet; it closes at `commit_frame`, at a rejection, or at the end of the packet. |
| `FrameFreeze` | `PreparedFrameTransactionBuilder.freeze`. |
| `FramePublish` | `CommandDispatcher.publish`, the committed-state publication. |

Per-frame dispatch time below is the harness's thread CPU time for the whole packet on the main thread. It also includes commit validation, latency bookkeeping, and the post-commit callbacks, which no interval covers.

## Method

1. `MIX_ENV=test mix run bench/frame_staging_capture.exs DIR` drives a real Editor at 220x60 with native GUI, semantic UI capabilities and records every packet that the Editor admits to the frontend. Packets are the exact `Port.command/3` payloads that `ProtocolReader` decodes. No provider HTTP request is made: the Agent stream comes from the request-bound provider fixture used by `bench/keystroke_latency_baseline.exs`.
2. `NativeRenderPerformance --frame-staging-replay` decodes every packet first, as the reader thread does, then dispatches each packet to the production `CommandDispatcher` on the main thread. The target builds in the Release configuration with `-O`. Any rejected frame fails the replay.
3. `scripts/measure_frame_staging` runs each workload five times in three conditions per run, interleaved:
   - `baseline`: the harness built with `frameTransactionSignposter = OSSignposter.disabled`, as a reference with no signpost work.
   - `idle`: the committed signposts with no tool recording.
   - `recorded`: the committed signposts under `xcrun xctrace record --instrument os_signpost`. The intervals come from `xcrun xctrace export` of the `OSSignpostIntervals` table, summed per frame.

| Workload | Size | Inputs | Measured frames |
|---|---|---|---|
| Scroll a large file | 50,000-line Elixir file, 2,026,679 bytes, full-document resident store (3.6 MB keyframe) | 20 warmup, 300 measured trackpad `scroll_batch` intents of 3 lines | 300 |
| Long Agent conversation while it streams | 10,000 retained transcript entries plus the streaming reply | 20 warmup, 100 measured streamed text chunks | 167 |
| Plain typing | 2,000-line Elixir file, 77,876 bytes, Insert mode | 20 warmup, 300 measured printable keys | 300 |

Capture revision: `5e45c34aeb7aec0e28ac09d4a79ecc6b2ca2fa52` (the parent of this change; the capture uses no changed code). Machine: Apple M1, 16 GB, macOS 27.2, Xcode 27.2 (Swift 6.4.2), Elixir 1.20.5 / OTP 29.

## Results

Interval figures are wall-clock signpost durations from the five `recorded` runs, summed per frame. Each cell is the median of the five per-run percentiles, with the lowest and highest run in parentheses. Times are in milliseconds.

| Workload | Frames per run | Interval | p50 ms | p95 ms |
|---|---:|---|---|---|
| Scroll | 300 | `FrameStage` | 0.0048 (0.0048 to 0.0050) | 0.0054 (0.0053 to 0.0060) |
| Scroll | 300 | `FrameFreeze` | 0.0034 (0.0034 to 0.0035) | 0.0037 (0.0036 to 0.0037) |
| Scroll | 300 | `FramePublish` | 0.0053 (0.0052 to 0.0055) | 0.0095 (0.0081 to 0.0095) |
| Scroll | 300 | Freeze plus publish | 0.0087 (0.0086 to 0.0090) | 0.0130 (0.0127 to 0.0133) |
| Typing | 300 | `FrameStage` | 0.0108 (0.0107 to 0.0111) | 0.0121 (0.0114 to 0.0140) |
| Typing | 300 | `FrameFreeze` | 0.0035 (0.0035 to 0.0036) | 0.0046 (0.0037 to 0.0061) |
| Typing | 300 | `FramePublish` | 0.0088 (0.0087 to 0.0090) | 0.0134 (0.0130 to 0.0134) |
| Typing | 300 | Freeze plus publish | 0.0123 (0.0122 to 0.0126) | 0.0169 (0.0165 to 0.0170) |
| Agent stream, all frames | 167 | `FrameStage` | 357.86 (357.23 to 358.37) | 361.69 (360.34 to 368.66) |
| Agent stream, all frames | 167 | `FrameFreeze` | 0.0193 (0.0190 to 0.0196) | 0.0231 (0.0230 to 0.0245) |
| Agent stream, all frames | 167 | `FramePublish` | 1.231 (1.221 to 1.276) | 1.337 (1.297 to 1.401) |
| Agent stream, all frames | 167 | Freeze plus publish | 1.252 (1.241 to 1.296) | 1.358 (1.321 to 1.421) |
| Agent stream, full transcript replace | 100 | `FrameStage` | 358.56 (357.87 to 359.16) | 362.55 (361.56 to 377.28) |
| Agent stream, full transcript replace | 100 | Freeze plus publish | 1.279 (1.274 to 1.317) | 1.375 (1.329 to 1.462) |
| Agent stream, append only | 67 | `FrameStage` | 0.688 (0.685 to 0.699) | 1.025 (1.014 to 1.038) |
| Agent stream, append only | 67 | `FrameFreeze` | 0.0056 (0.0055 to 0.0057) | 0.0092 (0.0072 to 0.0098) |
| Agent stream, append only | 67 | `FramePublish` | 0.0110 (0.0108 to 0.0113) | 0.0210 (0.0202 to 0.0241) |
| Agent stream, append only | 67 | Freeze plus publish | 0.0167 (0.0163 to 0.0170) | 0.0278 (0.0265 to 0.0303) |

Freeze plus publish is summed per frame before taking percentiles, so it is not the sum of the two rows above it.

Every measured Agent chunk produced one frame that replaced the whole transcript: `gui_agent_transcript` mode 0 with all 10,003 messages, about 430 KB per packet. The other 67 frames appended only the streaming reply (mode 1, base 10,001, two messages). The Agent rows therefore describe two different costs, and the split rows keep them apart.

### Why the Agent stream is expensive

Two defects cause the full-replace cost. Neither is in the staging design itself.

1. **The BEAM replaces the whole transcript on every streamed text batch.** `MingaEditor.Agent.StreamEventWorkflow.batch/2` calls `Panel.bump_message_version/1` for every batch that contains a `text_delta`. `TranscriptProjection.presentation_epoch/1` hashes `{generation, display_start, version}`, so the epoch changes on every batch. `AgentTranscriptEncoder.select_delta/5` treats an epoch change as structural and emits a full replace. The epoch is documented as a token that changes only on structural change, and an appended text delta is not structural.
2. **Swift measures each replaced message with runtime reflection.** A 45-second `sample` of the Agent replay puts 98% of main-thread samples in `AgentChatState.prepareTranscript` and 87% in the recursive `Mirror`-based `FrameResourceWeight.measuringOwnedPayload` that it calls while it builds the transcript store. Staging a full replace costs about 36 microseconds per message.

Append-only frames show what streaming would cost without defect 1: about 0.69 ms at p50 and 1.03 ms at p95 for 10,000 retained entries. This receipt did not profile the append path separately.

### Per-frame dispatch time

Thread CPU time for the whole packet, measured by the harness in each condition. Same median and run-range format.

| Workload | Condition | p50 ms | p95 ms |
|---|---|---|---|
| Scroll | baseline | 0.0159 (0.0157 to 0.0165) | 0.0208 (0.0202 to 0.0225) |
| Scroll | idle | 0.0164 (0.0161 to 0.0166) | 0.0217 (0.0212 to 0.0239) |
| Scroll | recorded | 0.0164 (0.0161 to 0.0168) | 0.0227 (0.0217 to 0.0240) |
| Typing | baseline | 0.0257 (0.0253 to 0.0260) | 0.0307 (0.0296 to 0.0326) |
| Typing | idle | 0.0265 (0.0259 to 0.0273) | 0.0333 (0.0325 to 0.0349) |
| Typing | recorded | 0.0264 (0.0259 to 0.0270) | 0.0330 (0.0308 to 0.0348) |
| Agent stream, all frames | baseline | 358.49 (357.77 to 358.99) | 361.20 (360.58 to 362.27) |
| Agent stream, all frames | idle | 357.84 (357.11 to 359.36) | 360.58 (359.50 to 387.64) |
| Agent stream, all frames | recorded | 359.08 (358.43 to 359.58) | 362.86 (361.41 to 369.93) |
| Agent stream, append only | baseline | 0.706 (0.705 to 0.713) | 1.045 (1.030 to 1.067) |
| Agent stream, append only | idle | 0.712 (0.710 to 0.774) | 1.045 (1.029 to 1.135) |
| Agent stream, append only | recorded | 0.711 (0.706 to 0.725) | 1.047 (1.035 to 1.063) |

## Signpost overhead

The Stop Condition asks whether the intervals change the timings they measure by more than the run-to-run spread. Compare the `baseline` rows, which do no signpost work, with the `idle` and `recorded` rows.

| Workload | Statistic | Shift from baseline median | Baseline run range |
|---|---|---|---|
| Scroll | p50 | +0.0005 ms (idle and recorded) | 0.0008 ms |
| Scroll | p95 | +0.0009 ms idle, +0.0019 ms recorded | 0.0023 ms |
| Typing | p50 | +0.0008 ms idle, +0.0007 ms recorded | 0.0007 ms |
| Typing | p95 | +0.0026 ms idle, +0.0023 ms recorded | 0.0030 ms |
| Agent stream, append only | p50 | +0.006 ms idle, +0.005 ms recorded | 0.008 ms |
| Agent stream, all frames | p50 | -0.66 ms idle, +0.59 ms recorded | 1.22 ms |

The shift is inside the spread everywhere except typing p50, where the idle shift (0.0008 ms) equals the spread (0.0007 ms) to measurement precision. That is the limit of this receipt: on the smallest frames the signposts cost about 0.0008 ms per frame, about 3% of the typing dispatch time, and the typing interval figures may be high by up to that amount. The cost is the same whether or not a tool records, because the `Render` category emits signposts unconditionally. It is 1,000 times smaller than the 0.8 ms threshold, so it cannot change any gate outcome below.

## Decision gates at 0.8 ms (proposed, pending owner confirmation of the threshold)

The gates in the ticket's Developer Notes, applied to the `FrameStage` p95 column with the proposed 0.8 ms threshold:

| Workload | `FrameStage` p95 | Over 0.8 ms | Freeze plus publish p95 | Staging larger |
|---|---|---|---|---|
| Scroll | 0.0054 ms | No | 0.0130 ms | No |
| Typing | 0.0121 ms | No | 0.0169 ms | No |
| Agent stream, all frames | 361.69 ms | Yes | 1.358 ms | Yes |
| Agent stream, append only | 1.025 ms | Yes | 0.0278 ms | Yes |

**Gate outcome: Promote.** Staging exceeds the threshold on the Agent stream workload and is larger than freeze plus publish there. The outcome is the same if the full-replace frames are excluded.

**Recommendation, proposed and pending owner confirmation of the threshold:** fix the two defects above before acting on the promotion. Moving staging to the reader thread does not make a 360 ms full replace acceptable: with the single-slot handoff, the reader would still deliver each streamed frame about 360 ms late, and the main thread would still publish a 10,003-message transcript. The BEAM epoch defect removes the full replace from streaming, and typed measurement removes the reflection cost from any remaining replace. Then re-run this receipt. If append-only staging is still above the confirmed threshold at p95, promote with the constraints listed in the ticket. Scroll and typing need no staging change.

## Limits

- **Replay, not the shipping app.** The harness drives the production `CommandDispatcher` and Release build settings, but no SwiftUI view observes `GUIState`. In the app, `FramePublish` also notifies registered observation trackers, so publish may cost more there. Staging and freeze do not touch observed state, so the staging figures and the gate outcome do not depend on this.
- **Main-thread contention is absent.** The replay dispatches packets back to back with nothing else on the main thread. In the app, rendering, input, and SwiftUI updates share that thread, so these are lower bounds on wall time per interval.
- **Capture environment.** The capture runs under `MIX_ENV=test`, where `Minga.Parser.Manager` is not running, so rows carry no tree-sitter highlight spans. Highlighted rows add spans to row deltas and keyframes, which would raise scroll and typing staging somewhat. The capabilities advertise monospace text and wcwidth widths instead of the app's proportional text and Unicode 15 widths; no BEAM code reads the text-rendering field, and every fixture character is ASCII.
- **One size per workload.** The Agent figures are for 10,000 retained entries. The full-replace cost scales with the transcript length, so a shorter conversation costs proportionally less per replace.
- **Signpost cost on small frames.** See the overhead section: up to about 0.0008 ms per frame on typing.
- **Run count.** Five runs per condition; one machine (Apple M1).

## Reproduce

```sh
MIX_ENV=test mix run bench/frame_staging_capture.exs /tmp/frame-staging/captures
MINGA_NATIVE_RENDER_SWIFT_CONDITIONS="MINGA_SNAPSHOT_RENDERER MINGA_TRANSCRIPT_ACCOUNTING" scripts/check_native_render_performance --build _build/native-render-performance
scripts/measure_frame_staging --build _build/native-render-performance --captures /tmp/frame-staging/captures --runs 5 --output /tmp/frame-staging/runs
```

For the `baseline` condition, build a second harness directory with `frameTransactionSignposter = OSSignposter.disabled` in `macos/Sources/Instrumentation.swift` and pass it as `--baseline-build`. `--report-only --output DIR` rebuilds `summary.json` and `frames.csv` from an existing run directory.

## Raw data

`frame_staging_main_thread/summary.json` holds each run's percentiles. `frame_staging_main_thread/frames.csv` holds every measured frame of every recorded run: interval durations and dispatch time. The `*.capture.json` files are the capture manifests: sizes, input counts, measured packet bytes, and the first measured packet. The packet captures (53 MB), replay JSON for every condition, the 15 `.trace` bundles, their interval exports (122 MB together), and the `sample` call tree are too large to commit. They are kept outside the repository in the worktree's ignored `_build/frame-staging-evidence/` directory and can be regenerated with the commands above.
