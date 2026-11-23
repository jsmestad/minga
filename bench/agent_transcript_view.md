# Agent transcript view construction

Receipt for [#3572](https://github.com/jsmestad/minga/issues/3572).

**Conclusion:** the earlier view-only mechanisms regressed CPU because of how SwiftUI reads row identities, not because the rows were lazy. `ForEach` reads the identity of every row about four times per committed frame. When each row element is `(offset, ChatMessageEntry)` and identity is `\.element.id`, every read copies a whole message out of the store. The chosen design keeps one immutable snapshot per view body, replaces the treap with the persistent weighted B+ sequence the ticket specifies, and changes the row element to a plain `{id, offset}` value. The view reads message content and the divider predecessor from the same snapshot only when a row is realized. On the predeclared gate this design uses **0.71x (default) and 0.70x (narrow)** of the baseline process CPU at 10,000 messages. The one-sided 95% upper bounds are 0.729 and 0.699, so both pass the 1.00 gate.

This design departs from one locked Developer Note. The note says to keep `ForEach(AgentTranscriptRows(messages), id: \.element.id)` with a tuple element. Measured over the new B+ store, that exact adapter costs **1.27x** CPU. Measured over the treap, it costs **1.34x**. The tuple element is the regression mechanism. Every other locked decision stands: one immutable snapshot, B+ storage owned by `AgentTranscriptStore`, no mirror array, no identity cache, no mutable cursor, and no new writable owner.

### How this was measured

`NativeRenderPerformance --agent-transcript-view-replay` is a new mode in the existing Release harness. It hosts the shipping `AgentChatView` in an `NSHostingView` inside an offscreen window. It seeds 0, 100, or 10,000 resident messages and sets an unfinished insert-mode draft. Each frame then applies one transcript operation through the production `prepareTranscript` and `publishTranscript`. There is no BEAM, no protocol decode, and no provider call. For each frame, the harness records thread CPU separately for three stages:

- Store preparation (`prepareTranscript`).
- Publication plus the SwiftUI update that `layoutSubtreeIfNeeded()` forces. This stage includes the view body, `ForEach` identity and edit passes, and lazy-stack layout.
- `displayIfNeeded()`.

The harness also records process CPU (`getrusage`, user plus system) over the measured window. A probe view counts processed transcript revisions. All runs had zero unprocessed frames.

The harness has two scenarios:

- **file_change:** one `edit_file` tool-call entry is appended per frame. At 10,000 messages the oldest entry is trimmed in the same frame, so the resident count stays fixed. This is the steady state of a byte-capped history.
- **stream:** the trailing assistant message is replaced per frame with one more word. The count is unchanged.

Host: Apple M1 MacBook Air (fanless), macOS 27.2, Release, `CODE_SIGNING_ALLOWED=NO`. "Before" is `main` at `0551a6e94` plus the harness commit. "After" is the candidate branch.

### (a) Application-owned enumeration and tuple construction per committed frame

The counts come from a temporary counting probe. It was applied to two scratch copies and never committed. Values are averaged over 40 warmed frames at default geometry.

| Messages | Scenario | Body evaluations | Before: tuple array elements | Before: full enumerations | After: tuple array elements | After: enumerations | After: SwiftUI row-identity reads | After: message reads (realized rows and dividers) |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 0 | file_change | 2 | 2 | 2 | 0 | 0 | 15 | 3 |
| 100 | file_change | 2 | 200 | 2 | 0 | 0 | 382 | 63 |
| 100 | stream | 2 | 202 | 2 | 0 | 0 | 402 | 53 |
| 10,000 | file_change | 2 | 20,000 | 2 | 0 | 0 | 39,982 | 63 |
| 10,000 | stream | 2 | 20,002 | 2 | 0 | 0 | 40,002 | 53 |

The baseline builds two complete tuple arrays per frame, one per body evaluation. This matches the 10,002-entry pair reported in the issue. After the change, the application enumerates nothing and allocates no history-sized storage. SwiftUI still reads about four identities per resident row per frame: two body evaluations, each with an update pass and an edits pass. That traversal is SDK access. This change makes each read cheap. It cannot make the number of reads independent of history size without virtualization, which this ticket rejects.

### (b) CPU per frame by stage, 10,000 messages

Medians are over the predeclared gate runs. Store preparation is in microseconds; the other columns are in milliseconds.

| Stage | Before | After |
|---|---:|---:|
| Store preparation (`prepareTranscript`), µs | 11 | 16 to 17 |
| Publish plus SwiftUI update, ms, p50 | 16.9 | 11.7 |
| Display pass, ms | under 0.1 | under 0.1 |

A `sample` of the update stage attributes the before cost as follows:

| Work | Share of the update | Per frame |
|---|---:|---:|
| View body (the two tuple arrays) | 6.5% | about 1.1 ms |
| `ForEachState` identity and edit passes | 68% | about 11.6 ms |
| Lazy-stack measurement and placement | 27% | about 4.6 ms |

Inside the `ForEachState` share, generic `KeyPath` projection through the tuple, together with `initializeWithCopy` and `destroy` of `ChatMessageEntry`, is the largest application-shaped cost. After the change, the body's own cost is about 0.2% of the update. Store preparation rises by about 6 µs because the B+ store copies boundary leaves, which the treap did not do. That rise is three orders of magnitude smaller than the update saving.

### Candidates measured against the issue's mechanism

Each candidate below was measured at 10,000 messages, default geometry, with four ABBA pairs. The ratio is after/before process CPU.

| Candidate | Store | Row element and identity | Ratio range | Outcome |
|---|---|---|---:|---|
| Developer Notes adapter | treap | `(offset, ChatMessageEntry)`, `\.element.id` | 1.32 to 1.36 | Reproduces the prior regression |
| Developer Notes adapter | B+ (32/16) | `(offset, ChatMessageEntry)`, `\.element.id` | 1.26 to 1.29 | Still regresses: the per-read message copy dominates |
| Identity rows | treap | `{id, offset}`, `\.id` | 0.80 to 0.87 | Passes, but keeps the treap, which the ticket rejects |
| **Identity rows, in-place identity read (chosen)** | B+ (32/16) | `{id, offset}`, `\.id`, read from the leaf slot without copying the entry | 0.69 to 0.79 (gate) | **Passes** |

An intermediate version of the chosen design returned the whole stored entry from the tree before reading its `id` field. It measured 0.78 to 0.82. Reading the stored `id` in place from the leaf slot saved another 14% (paired ratio 0.856, upper bound 0.871). The gate below was rerun from scratch on that final build.

### Chosen design

- **`AgentTranscriptStore`:** a persistent weighted B+ sequence replaces the implicit treap.
  - Leaves hold at most 32 entries and branches hold at most 32 child records of `(child, cumulative count)`. Every non-root node holds at least 16. Redundant roots collapse, and empty storage has no root.
  - Nodes are immutable `nonisolated` classes with cached count, height, and exact logical weight. A leaf's weight is its entries' payloads plus one collection entry per message, which keeps the admission equation unchanged.
  - Construction is bottom-up with even group sizes, O(m).
  - The trim-front, keep-base, append-suffix operation is implemented as `dropFirst`, then `takeFirst`, then `concatenate`. It shares untouched subtrees and rebuilds only boundary leaves and the spine down to the shorter tree's height.
  - Checked aggregate weight is computed before the new sequence is built. Before-seed, epoch-mismatch, desync, and resource-policy outcomes are unchanged.
  - The treap's priorities, ordinals, one-node-per-entry layout, and split/merge/Cartesian build are deleted.
- **`AgentTranscriptMessages`:** remains the immutable read façade.
  - Indexed access descends in O(height) without allocating.
  - `identity(at:)` reads the stored `id` in place.
  - The in-order iterator walks leaves with its own stack, so independent iterators over old snapshots stay valid.
- **`AgentTranscriptRows`:** a module-internal, value-semantic `RandomAccessCollection` over exactly one snapshot.
  - Its element is `AgentTranscriptRow {id, offset}`. Constructing rows, reading `count`, and moving indexes visit no entries.
  - `message(at:)` and `showsDivider(before:)` read content and the divider predecessor from the same snapshot. Rows that SwiftUI evaluates after a newer frame therefore still describe their own snapshot. The original code read the predecessor from the live `state.messages`.
  - The divider rule is unchanged and stays in the single enclosing `VStack`.
- **View body:** `let rows = AgentTranscriptRows(state.messages)` is captured once, followed by `ForEach(rows, id: \.id)`. The adapter adds no `@State`, cache, actor, mutable cursor, or identity owner.

### Structural work per ordinary delta

Values come from the accounting counters in the focused tests.

| Operation | Entries (height) | Nodes created | Branch slots written | Entry slots copied into boundary leaves |
|---|---|---:|---:|---:|
| Tail replacement | 100 (1) | 6 | 11 | 49 |
| Append | 100 (1) | 3 | 4 | 26 |
| Front trim plus append | 100 (1) | 6 | 11 | 50 |
| Tail replacement | 10,000 (2) | 9 | 121 | 61 |
| Append | 10,000 (2) | 4 | 41 | 32 |
| Front trim plus append | 10,000 (2) | 9 | 123 | 63 |

A 10,000-message keyframe creates exactly 324 nodes (313 leaves, 10 branches, and 1 root). The treap created 10,000.

### CPU gate and result

The gate is the one declared in the ticket:

- 12 matched ABBA pairs for each warmed 10,000-message geometry.
- Paired log process-CPU ratios.
- The one-sided 95% Student-t upper bound on the geometric mean ratio must be at most 1.00 for each geometry separately.
- Geometries are not pooled, and no samples were added after a result was seen.

Result on the final build (120 measured frames after 12 warmup frames per run):

| Geometry | Pairs | Ratio range | Geometric mean | Upper 95% bound | Gate |
|---|---:|---:|---:|---:|---|
| default (900 × 820) | 12 | 0.686 to 0.787 | 0.713 | 0.729 | pass |
| narrow (420 × 820) | 12 | 0.683 to 0.712 | 0.695 | 0.699 | pass |

The remaining strata used 3 pairs each. "Cold" is the first frame in a fresh process; it is not a flushed-cache claim. Process CPU medians are in ms.

| Stratum | Geometry | Messages | Before | After | Ratio range |
|---|---|---:|---:|---:|---:|
| file_change warm | default | 0 | 294.3 | 293.4 | 0.942 to 1.103 |
| file_change warm | default | 100 | 574.3 | 564.4 | 0.954 to 0.983 |
| file_change warm | default | 10,000 | 2047.0 | 1426.3 | 0.689 to 0.713 |
| file_change warm | narrow | 0 | 300.5 | 349.5 | 0.997 to 1.179 |
| file_change warm | narrow | 100 | 572.5 | 544.1 | 0.941 to 0.964 |
| file_change warm | narrow | 10,000 | 2212.4 | 1448.9 | 0.635 to 0.800 |
| file_change cold | default | 0 | 6.5 | 6.5 | 0.986 to 1.022 |
| file_change cold | default | 100 | 5.6 | 5.6 | 0.958 to 1.193 |
| file_change cold | default | 10,000 | 18.0 | 12.4 | 0.662 to 0.713 |
| file_change cold | narrow | 0 | 6.6 | 6.5 | 0.978 to 1.003 |
| file_change cold | narrow | 100 | 5.7 | 5.4 | 0.928 to 0.979 |
| file_change cold | narrow | 10,000 | 17.1 | 12.2 | 0.683 to 0.741 |
| stream warm | default | 0 | 253.3 | 252.3 | 0.913 to 1.008 |
| stream warm | default | 100 | 353.8 | 358.6 | 0.963 to 1.030 |
| stream warm | default | 10,000 | 1836.7 | 1349.9 | 0.629 to 0.819 |
| stream warm | narrow | 0 | 279.8 | 275.8 | 0.944 to 1.036 |
| stream warm | narrow | 100 | 470.5 | 375.4 | 0.798 to 1.059 |
| stream warm | narrow | 10,000 | 1839.6 | 1413.0 | 0.662 to 0.790 |

The warmed narrow stratum at 0 messages had two of three pairs at 1.17 to 1.18, so I ran a separate diagnostic outside the predeclared count: 12 more pairs at the same stratum. Those pairs gave a median ratio of about 1.00 and a geometric mean of 1.029, with an upper bound of 1.057. Every excess is main-thread CPU, and it appears as a heavier tail late in a run. Long 600-frame runs of both builds showed the host moving between phases of about 2.4 ms and about 4.7 ms per frame partway through a run, for before and after alike. This is consistent with thermal or core-placement changes on a fanless host. In that state, a single 3-pair stratum at 0 messages cannot separate a few hundred microseconds from host drift. I do not claim an improvement at 0 messages. I also do not see a mechanism for a regression there: with one resident row, the change replaces a one-element array with a one-row identity read. The 10,000-message gate is unaffected, because its pairs are interleaved and its ratios are 0.68 to 0.79.

### Risks and limits

- **Harness, not the shipping app.** The replay hosts the real `AgentChatView` and the production store path, but offscreen and with no BEAM traffic, protocol decode, or other workspace chrome. Ratios in the full app will be smaller because unrelated work dilutes them. This receipt does not claim a latency gain.
- **SwiftUI still reads every row identity.** The reads are about 40,000 identity descents per frame at 10,000 messages, each O(height=2). Removing that cost needs virtualization or fewer body evaluations, which are outside this ticket.
- **Boundary copies.** Ordinary deltas now copy up to about 64 entry slots into boundary leaves. The treap copied none. Preparation cost rises by microseconds, and the count is bounded independent of history size.
- **Deviation from a locked Developer Note.** The note's tuple-element adapter is measured to regress, and it is the regression mechanism. The `{id, offset}` element preserves message identity, divider behavior, and one-snapshot semantics. This needs owner acknowledgement.
- **AC 4.** A hosted test covers the draft, cursor, and mode across a 10,000-message file-change frame at default and narrow width. In-process accessibility queries return no elements for an offscreen `NSHostingView`, so visible-content and accessibility checks need the live app.

## Reproduce

```sh
mix protocol.gen
(cd macos && xcodegen generate)
xcodebuild build -project macos/Minga.xcodeproj -scheme NativeRenderPerformance -configuration Release \
  -derivedDataPath _build/after CODE_SIGNING_ALLOWED=NO MINGA_NATIVE_RENDER_SKIP_PROTOCOL_GEN=1
mkdir -p _build/after/Build/Products/Frameworks
ln -sfn ../Release/MingaProtocol.framework _build/after/Build/Products/Frameworks/MingaProtocol.framework
ln -sfn ../Release/MingaUI.framework _build/after/Build/Products/Frameworks/MingaUI.framework
# Build the base revision with the harness commit the same way into _build/before, then:
scripts/measure_agent_transcript_view _build/before _build/after /tmp/atv/gate 12 10000 default file_change 120 12
scripts/measure_agent_transcript_view _build/before _build/after /tmp/atv/gate 12 10000 narrow file_change 120 12
scripts/measure_agent_transcript_view _build/before _build/after /tmp/atv/cold 3 100 default file_change 1 0
```

The base build is `main` at `0551a6e94` with the harness commit applied, which leaves the production view and store unchanged.

## Raw data

`agent_transcript_view/*.json` holds every pair's process CPU, ratio, and per-run medians for the gate, the warm, cold, and streaming strata, and the 0-message diagnostic. The per-frame replay JSON and the `sample` call trees are not committed. The counting probe that produced table (a) was applied only to scratch copies and is not part of the tree.
