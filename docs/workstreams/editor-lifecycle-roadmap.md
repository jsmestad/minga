# Editor Lifecycle Execution Roadmap

This ledger drives every actionable finding from `FINDINGS.md` through freshness triage, decision, implementation, and merge evidence. `FINDINGS.md` remains the immutable audit record. This file owns execution status, locked specifications, validation evidence, and discoveries made after the audit.

The audit merged in [PR #2974](https://github.com/jsmestad/minga/pull/2974) at `c0bb98042b9ffaf75392727e7934c8af60f85cb9`. Do not repeat the 537-file audit. Reproduce only the selected finding against current main before promoting it.

## Governing principle

Elegant Elixir wins. Each unit must remove a failure with the fewest new concepts, preserve explicit state ownership, and prefer existing functions and data shapes over new machinery. Correctness is the floor, not a reason to add speculative edge cases, wrappers, compatibility paths, or generic lifecycle abstractions.

Production line count is a guardrail rather than a code-golf target:

- Target a net-neutral or net-negative diff under `lib/`.
- Lock a maximum production-line increase before implementation. More than 50 net new production lines requires replanning and a named human decision.
- Count test and documentation lines separately.
- Add no process, dependency, behaviour, protocol, registry, adapter, manager, generic wrapper, configuration flag, public API, compatibility shim, or parallel data shape unless the READY specification proves it is required.
- Delete obsolete branches and compatibility code made unnecessary by the correction.
- Never compress clear code into opaque expressions to meet a line budget.

The cumulative target across the full accepted program is net-negative production code.

## Program scope

The independent Ponytail gate produced 91 `ACCEPT`, 28 `ROUTE`, 11 `PRESERVE`, and 9 `REJECT` verdicts. W001 through W006 resolved only the first six accepted findings. They are a verified initial tranche, not completion of the audit program.

Current accepted inventory:

- **VERIFIED:** L01, L02, L04, L05, L10, L12
- **CANDIDATE, lifecycle:** L11, L13, L14, L15, L16, L19, L20, L22, L23, L24, L25, L26, L27, L28, L29, L30
- **CANDIDATE, deletion:** D05, D06, D08, D09, D10, D11, D13, D14, D15, D18, D19, D20, D21, D22, D23, D24, D25, D26, D27, D28, D29, D30, D31, D32, D34, D35, D36, D39, D40
- **CANDIDATE, shrink:** S03, S04, S05, S06, S07, S09, S11, S12, S14, S15, S18, S20, S21, S22, S23, S25, S26, S28, S29, S32, S33, S34, S35
- **CANDIDATE, craftsmanship:** E02, E03, E05, E08
- **CANDIDATE, data shape:** ES03, ES05, ES07, ES08, ES09, ES10, ES12, ES14, ES16, ES17, ES18, ES21, ES24

### Freshness wave at `6e175b87764145577999a1c04a532960cb89222f`

Eleven independent read-only GPT-5.5 `medium` batches checked all 85 remaining `ACCEPT` IDs against the same current-main source commit. Seventy-nine remain reproducible with the accepted direction intact. Six remain concerns but have drifted enough to require a high planner before promotion. None was already resolved, and none introduced a new architecture decision.

- **STILL_REPRODUCIBLE, lifecycle:** L11, L13, L14, L15, L16, L19, L20, L22, L23, L24, L25, L26, L27, L28, L29, L30
- **STILL_REPRODUCIBLE, deletion:** D05, D06, D08, D09, D10, D11, D14, D15, D18, D19, D20, D21, D22, D23, D24, D25, D26, D27, D28, D29, D30, D31, D32, D34, D35, D39
- **STILL_REPRODUCIBLE, shrink:** S03, S04, S05, S06, S07, S09, S11, S12, S15, S18, S20, S21, S22, S23, S25, S26, S28, S29, S32, S33, S34, S35
- **STILL_REPRODUCIBLE, craftsmanship:** E02, E03, E05, E08
- **STILL_REPRODUCIBLE, data shape:** ES03, ES05, ES07, ES09, ES10, ES12, ES14, ES16, ES17, ES18, ES24
- **DRIFTED:** D13, D36, D40, S14, ES08, ES21

Drift evidence:

- **D13:** No-op compatibility paths remain, but the live `MingaEditor.State.BufferLifecycle` owner now shares the old module name and the highlight call path changed. Rescope without touching the live owner.
- **D36:** Dormant Tool Manager placement remains, but the shared footer surface registry is now an explicit numbered placement and focus contract. Rescope the removable local branch.
- **D40:** Agent-chat prefetch and `WindowCache.boundary_snapshot/1` remain dead, while `DisplayMap` queries and row-rasterization telemetry named by the old aggregate are now live. Split only current dead surfaces.
- **S14:** Several picker preview callbacks are already optional, while cancel, prompt, effect, and input callbacks remain mandatory. Re-evaluate each remaining callback separately.
- **ES08:** Parser and semantic-token producers now construct `Minga.Language.Highlight.Span`; only mixed map acceptance in editor highlight storage remains. Relock the remaining conversion boundary.
- **ES21:** Typed semantic status-bar structs now exist beside the legacy snapshot maps. Relock which projection remains redundant instead of introducing a second typed model.

Decision inventory:

- **ROUTE, lifecycle:** L03, L06, L07, L08, L09, L17, L18, L21
- **ROUTE, deletion:** D01, D02, D03, D07, D17
- **ROUTE, shrink:** S01, S08, S10, S13, S16, S17, S27, S30, S31
- **ROUTE, craftsmanship:** E01
- **ROUTE, data shape:** ES01, ES02, ES06, ES19, ES20

### Architecture decision wave at `6e175b87764145577999a1c04a532960cb89222f`

Ten independent read-only `archie` reviews at `xhigh` resolved all 28 routed findings against the same production source. The later roadmap-only merge at `c375b8dcebcc0b6bc7cb0edecb3d2af8f802ef5e` did not change the inspected code. Twenty-three findings may proceed to high-planner scoping, four are preserved, and one is dropped because focused decisions fully subsume it. These are architecture dispositions, not READY promotions.

| ID | Disposition | Locked owner and boundary |
| --- | --- | --- |
| L03 | `APPROVE_DIRECT` | Derive one ordered live-plus-tab buffer inventory in the existing buffer lifecycle workflow. Keep actual retirement atomic in `MingaEditor.State.remove_buffer/2`. |
| L06 | `APPROVE_DIRECT` | `MingaEditor.State.LSP.PendingRequests` owns captured request identity; `LspEventHandler` takes each response once and delegates accepted results. |
| L07 | `APPROVE_DIRECT` | Completion request authority uses the same typed pending-request owner and must validate captured buffer, version, client, and completion generation. |
| L08 | `APPROVE_DIRECT` | Code-lens and inlay-hint requests use the same captured identity contract; result stores remain with their existing presentation owners. |
| L09 | `APPROVE_DIRECT` | Parser highlighting owns syntax, `State.LSP` owns semantic spans and correlation, and the pure content boundary composes them for rendering. |
| L17 | `APPROVE_DIRECT` | Workspace remains agent lifecycle authority; `TabBar` atomically projects Workspace values onto associated agent tabs. |
| L18 | `APPROVE_DIRECT` | Persist remote server, session, and committed replay cursor in `Workspace.RemoteSession`; never persist live connection status or runtime values. |
| L21 | `APPROVE_DIRECT` | `Input.Interrupt` coordinates existing focus owners, cancels pending input, preserves durable panel visibility, and derives the surviving scope from the active window. |
| D01 | `PRESERVE` | Keep `FeatureState` as documented, tab-scoped extension state with source cleanup. Absence of a bundled writer is not evidence against an out-of-tree contract. |
| D02 | `APPROVE_DIRECT` | Retire the orphaned Change Summary semantic and protocol surface in one synchronized protocol change. Do not redirect it to live review state. |
| D03 | `APPROVE_DIRECT` | Retire the unused native Tool Manager panel and keep the existing semantic picker as the sole presentation. Preserve Tool Manager services. |
| D07 | `PRESERVE` | Keep `Frontend.Adapter` as the transport-process contract implemented by Manager and test frontends. Remove only independently proven dead leaves. |
| D17 | `PRESERVE` | Keep `MingaEditor.UI` and `MingaEditor.Frontend` as documented public facades and retain every live export. |
| S01 | `APPROVE_DIRECT` | `Commands.Formatting` owns one asynchronous formatting lifecycle; BufferManagement owns save intent and the post-format write or close continuation. |
| S08 | `APPROVE_DIRECT` | Split Router only at a complete key-local routing seam. The outer event envelope still performs universal housekeeping exactly once. |
| S10 | `PRESERVE` | Keep separate prompt and file-tree temporary-target workflows over the shared `Buffers.set_active_override/2` leaf because their restore and failure invariants differ. |
| S13 | `APPROVE_DIRECT` | `TabBar` represents no active tab as `active_id: nil`; do not use a valid-looking sentinel or invent a launchpad pseudo-tab. |
| S16 | `APPROVE_DIRECT` | Consolidate only authorized-path open-or-activate mechanics in `Handlers.BufferRegistry`; sources retain authorization, cursor, preview, and failure policy. |
| S17 | `APPROVE_DIRECT` | `PromptUI` owns successor-safe callback sequencing through `ModalWorkflow`; context-aware handlers may open a successor modal without it being dismissed. |
| S27 | `APPROVE_DIRECT` | Enforce the one generated frontend protocol version at Manager admission and remove packet layouts that the admitted version cannot send. |
| S30 | `APPROVE_DIRECT` | `RenderPipeline.Intent` is the sole cache-free Editor-to-Renderer contract; renderer-local working values remain nested, frame-local, and renderer-owned. |
| S31 | `DROP` | L17, L18, ES02, ES19, and ES20 fully decompose the aggregate duplication concern. No umbrella owner or standalone cleanup is allowed. |
| E01 | `APPROVE_DIRECT` | Extract pure lane-value transitions under `EffectScheduler`; keep one scheduler mailbox and all timers, monitors, tasks, leases, and terminal outcomes in the existing engine. |
| ES01 | `APPROVE_DIRECT` | Keep `WindowIntent` as the explicit transfer DTO and pare renderer working windows to semantic input plus renderer-mutated state. Do not share live structs. |
| ES02 | `APPROVE_DIRECT` | Preserve nested Intent identity through renderer materialization and emit; stop reconstructing Editor-shaped broad maps. |
| ES06 | `APPROVE_DIRECT` | One typed, Editor-global `State.LSP.PendingRequests` collection owns semantic request authority. Transport correlation and sync ordering stay in Layer 1. |
| ES19 | `APPROVE_DIRECT` | `Session.State` owns active agent UI and the agent Workspace payload owns inactive agent UI; transfer authority on activation instead of mirroring. |
| ES20 | `APPROVE_DIRECT` | Add kind-specific payloads inside existing Tab and Workspace owners. Do not share one payload type or create a generalized tagged-state abstraction. |

Dependency order from the decisions is mandatory: ES06 before L06, L06 before L07 and L08, and L06 before L09; ES20 before L18 and ES19; L17 before L18; ES19 before ES02, ES02 before S30, and S30 before ES01. Same-owner work remains serialized even where no hard dependency exists.

Retained constraints:

- **PRESERVE:** D04, D12, D16, D33, D38, S02, S24, E04, E06, E07, ES13
- **REJECT:** D37, S19, E09, E10, ES04, ES11, ES15, ES22, ES23

The program is complete only when every `ACCEPT` ID is VERIFIED or DROPPED with current-main evidence, every `ROUTE` ID has a recorded decision and any accepted follow-on is terminal, every retained constraint has survived the resulting diffs, and the final ledger is merged. A completed tranche never closes the program.

## Status model

- **CANDIDATE:** An accepted finding that is not sufficiently specified.
- **READY:** The implementation shape, tests, boundaries, validation, and complexity budget are locked.
- **ACTIVE:** The unit is currently being implemented.
- **BLOCKED:** The unit requires a named decision or dependency.
- **VERIFIED:** The implementation PR merged and the ledger contains validation evidence.
- **DROPPED:** The unit is no longer appropriate, with a recorded rationale.

Queue rules:

- Ponytail `ACCEPT` findings and routed findings with an `APPROVE_DIRECT` architecture disposition may become implementation work.
- Other `ROUTE` findings require a recorded architecture decision before implementation.
- `PRESERVE` and `REJECT` findings cannot enter the implementation queue.
- A lower-cost implementation model executes only READY work.
- The controller or a human promotes direct work to READY from current-source evidence.
- One owner area may have only one READY or ACTIVE implementation at a time.
- Every implementation PR updates this ledger.
- A completed PR does not automatically promote the next candidate.
- Scope the next candidate against current main only after the preceding unit merges.
- A unit becomes VERIFIED only after merge.

## Definition of Ready

A candidate becomes READY only when every condition passes:

1. The Ponytail verdict is `ACCEPT`, or the routed finding has an `APPROVE_DIRECT` architecture disposition.
2. The finding remains reproducible on current main.
3. One independently verifiable outcome is locked.
4. The authoritative state, process, protocol, or persistence owner is known.
5. The exact target return shape, struct, tagged state, tuple, or transition contract is specified.
6. Expected files, symbols, producers, and consumers are named.
7. The exact test layer, test file, assertions, and edge cases are specified.
8. Non-goals and retained constraints are explicit.
9. Dependencies are merged and no overlapping-owner work is active.
10. Exact focused and broad validation commands are listed.
11. The production-line and concept budgets are locked.
12. No unresolved question remains for the implementer.
13. The work fits in one reviewable PR.

If any condition fails, keep the unit CANDIDATE or mark it BLOCKED.

## OMP orchestration contract

Freshness triage uses the read-only `editor-lifecycle-freshness` profile on GPT-5.5 at `medium`. It classifies only whether the current finding still fits current main. The `editor-lifecycle-planner` profile uses GPT-5.5 at `high` when a reproducible finding needs a locked specification. Escalate that planner invocation to `xhigh` only after a `DRIFTED` high plan remains unresolved, a worker returns `NEEDS_REPLAN`, or a recorded architecture decision requires it. `ROUTE` findings require an xhigh architecture decision before planning. Repository-local profiles pin routine implementation and specialist review to GPT-5.5 at `medium`.

| Responsibility | Agent | Model | Thinking | Access |
| --- | --- | --- | --- | --- |
| Classify current-main freshness | `editor-lifecycle-freshness` | `openai-codex/gpt-5.5` | `medium` | Read-only |
| Lock a direct implementation contract | `editor-lifecycle-planner` | `openai-codex/gpt-5.5` | `high` | Read-only |
| Resolve architecture ownership | `archie` | Project profile | `xhigh` | Read-only |
| Implement one READY unit | `editor-lifecycle-worker` | `openai-codex/gpt-5.5` | `medium` | One worktree, no delegation |
| Ponytail, Elixir, and bug-hunt review | `editor-lifecycle-reviewer` | `openai-codex/gpt-5.5` | `medium` | Read-only |
| Final acceptance | `reviewer` | Project profile | Project profile | Read-only |

### Promotion and replanning

Run `editor-lifecycle-freshness` first. `ALREADY_RESOLVED` becomes DROPPED only with exact current-main evidence. `STILL_REPRODUCIBLE` may proceed to a high planner. `DRIFTED` requires the high planner to relock the specification and escalates to xhigh only if the contract remains ambiguous. `NEEDS_DECISION` and every `ROUTE` finding require an xhigh architecture decision. No classification alone promotes work to READY.

### Implementer

The worker executes one READY unit exactly as written, adds the locked tests, validates the observable outcome, and updates this ledger. It may not redesign architecture, ownership, persistence, protocols, or scope. It returns `NEEDS_REPLAN` instead of improvising when the specification is invalid.

### Adversarial review

After the first working diff and focused tests pass, launch two independent read-only reviews in one task batch:

1. **Ponytail and Elixir:** Falsify the smallest-correct-slice claim, count production and test deltas separately, identify deletion or reuse opportunities, and inspect changed Elixir for canonical data shapes, pattern-matched control flow, owner APIs, fitting OTP primitives, types, and removable ceremony.
2. **Correctness bug hunt:** Inspect logic, state flow, process identity, races, stale messages, failure handling, silent fallthroughs, owner boundaries, and acceptance drift.

Add `silent-failure-hunter` only when a diff materially changes error handling, recovery, fallback, catch, shutdown, persistence, or ignored-result behavior beyond the locked direct behavior. Send accepted fixes to the existing worker through `hub`; do not spawn a replacement worker. A unit cannot advance while either review has an unresolved finding. Architecture or contract changes return `NEEDS_REPLAN`.

Use the normal project reviewer once after all review fixes and required validation. A BLOCKED verdict permits one targeted re-review of the named blockers.

Do not use TaskExecute for planner or implementer work.

## Per-unit lifecycle

1. Synchronize with current `origin/main`.
2. Run medium freshness triage and record its SHA and evidence.
3. For a reproducible candidate, create a dedicated feature worktree and run the high planner to lock every Definition of Ready field. Escalate only unresolved contracts.
4. Mark the unit ACTIVE and run one worker.
5. Run focused tests and measure production and test line deltas.
6. Run the combined Ponytail and Elixir review plus the correctness bug hunt in parallel.
7. Return accepted in-scope fixes to the existing worker.
8. Run required focused and broad validation.
9. Run the normal project reviewer.
10. Update evidence, commit, push, and open the implementation PR.
11. Merge after required checks, mark VERIFIED, synchronize main, then freshen the next candidate in that owner area.

### CI pipelining

CI is a background merge gate, not an idle barrier. After opening a PR, start one background check watcher and immediately continue read-only freshness, architecture decisions, or planning for disjoint owner areas. A separate implementation may proceed only when it has no owner, file, contract, protocol, persistence, or dependency overlap with the PR in CI.

Do not start a same-owner or dependency-successor implementation from an unmerged branch. Do not stack speculative branches merely to avoid waiting. A CI failure interrupts the affected slice for diagnosis, while independent work may continue. Merge only after required checks pass, synchronize main, and re-run freshness for any downstream candidate whose evidence may have changed.

Pause only for a named architecture or product decision, an unavailable dependency or credential, a plan requiring more than 50 net new production lines, three failed focused attempts on the same failure, or explicit user instruction.

## Completion evidence template

Every unit reserves these fields:

- **Status:**
- **PR URL:**
- **Planning profile:**
- **Implementation profile:**
- **Freshness commit SHA:**
- **Commit SHA:**
- **Merge SHA:**
- **Focused tests:**
- **Broad validation:**
- **Ponytail verdict:**
- **Bug-hunt verdict:**
- **Elixir craftsmanship verdict:**
- **Final reviewer verdict:**
- **Production lines added/removed:**
- **Test lines added/removed:**
- **Concepts added/removed:**
- **Findings resolved:**
- **Discoveries affecting later work:**
- **Completion date:**

## Queue

### W001: Frame rejection reaches renderer recovery

- **Status:** VERIFIED
- **Audit ID:** L01
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.6-sol`, `xhigh`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.6-luna`, `high`
- **Freshness basis:** Reproduced against `c0bb98042b9ffaf75392727e7934c8af60f85cb9`, the merge commit for audit PR #2974.

#### Observable outcome

A correlated frontend `frame_rejected` event reaches the existing renderer acknowledgement lifecycle immediately. Retryable, adapted-retry, and terminal dispositions retain their existing renderer behavior. Wrong correlation remains ignored. `MingaEditor` forwards the canonical status without mutating Editor state or interpreting recovery policy.

#### Current producer-to-consumer failure path

1. macOS and Go encode protocol-v12 frame rejection events with reason and disposition.
2. `MingaEditor.Frontend.Protocol.decode_event/1` returns `{:frame_rejected, generation, frame_seq, last_applied_frame_seq, reason, disposition}`. Protocol-v11 input is normalized to the same six-element runtime tuple.
3. `MingaEditor.Frontend.Manager.handle_info/2` broadcasts the decoded value as `{:minga_input, event}`.
4. `MingaEditor.handle_info/2` forwards only the obsolete five-element rejection shape.
5. The canonical six-element event reaches the generic `{:minga_input, _}` clause and `MingaEditor.Handlers.HighlightHandler.handle/2`, which ignores it.
6. `MingaEditor.Renderer.Server.frame_status/2`, `FrameHandler.dispatch/2`, and `AckHandler.handle/2` are never reached.

No production sender emits a five-element Elixir `:frame_rejected` tuple. The remaining five-element constructors are direct renderer tests.

#### Authoritative owners and locked shape

`MingaEditor.Frontend.Protocol` owns the canonical runtime event:

```elixir
{:frame_rejected,
 generation,
 frame_seq,
 last_applied_frame_seq,
 reason,
 disposition}
```

`MingaEditor` owns ordered mailbox routing. When `state.render.renderer` is a PID, it forwards the inner tuple unchanged to `MingaEditor.Renderer.Server.frame_status/2` and returns `{:noreply, state}`.

`MingaEditor.Renderer.State` remains authoritative for acknowledgement credit, resident state, recovery generation, pending frames, and terminal failure. Existing transition policy remains in `MingaEditor.Renderer.AckHandler`, `MingaEditor.Renderer.RecoveryHandler`, and `MingaEditor.Renderer.State`.

#### Exact files and symbols

Production changes:

- `lib/minga_editor.ex`, `MingaEditor.handle_info/2`
- `lib/minga_editor/renderer/ack_handler.ex`, `MingaEditor.Renderer.AckHandler.handle/2`

Test changes:

- `test/minga_editor/renderer/server_test.exs`

Contract sources that must not change:

- `lib/minga_editor/frontend/protocol.ex`
- `lib/minga_editor/frontend/manager.ex`
- `lib/minga_editor/renderer/server.ex`
- `lib/minga_editor/renderer/frame_handler.ex`
- `lib/minga_editor/renderer/recovery_handler.ex`
- `test/minga_editor/frontend/protocol_test.exs`
- `docs/protocol_schema.toml`
- `docs/PROTOCOL.md`
- macOS and Go frontend sources

#### Locked implementation shape

1. Split the shared five-element rejection/window-reference handler in `MingaEditor.handle_info/2`.
2. Add one exact six-element `:frame_rejected` clause that forwards the unchanged tuple when the renderer is a PID.
3. Keep the existing five-element `:window_ref_miss` behavior as a separate exact clause.
4. Delete `AckHandler.handle/2`'s five-element rejection normalization clause and compatibility comment.
5. Update four renderer tests that construct five-element rejection tuples to use the canonical six-element shape.
6. Add one decoder-to-Editor-to-renderer regression test in the existing renderer server test file.
7. Confirm no production or test caller constructs a five-element `:frame_rejected` tuple. Keep protocol-v11 wire normalization at the decoder boundary.

No new module, process, dependency, behaviour, protocol, registry, public API, configuration, compatibility shim, or data representation is allowed.

#### Required tests

Use `test/minga_editor/renderer/server_test.exs` at the Renderer GenServer integration layer. Add `"decoded retryable frame rejection reaches renderer recovery"` with these assertions:

1. Start an acknowledgement-enabled renderer with the existing helper.
2. Submit frame 20 and observe generation 1, base 0, and keyframe status.
3. Queue frame 21 as the latest pending intent.
4. Decode `<<0x0B, 1::32, 20::32, 0::32, 4, 1>>` through the real decoder.
5. Assert the canonical six-element retryable tuple.
6. Build a valid Editor state whose renderer field contains the renderer PID.
7. Call the real `MingaEditor.handle_info/2` callback with the decoded input.
8. Assert `{:noreply, ^state}`.
9. Assert frame 21 runs with generation 2, base 0, and `keyframe? == true`.
10. Refute a successful receipt for rejected frame 20.

Retain existing assertions for retryable recovery, adapted retry, terminal failure, stale generation, last-applied mismatch, and protocol-v11 wire normalization.

#### Validation

Focused:

```bash
mix test.debug test/minga_editor/frontend/protocol_test.exs test/minga_editor/renderer/server_test.exs
```

Broad:

```bash
make lint
mix test.llm
```

No Swift, Go, Zig, protocol generation, or snapshot validation is required because the wire format and frontend behavior do not change.

#### Non-goals and retained constraints

- No opcode, schema, protocol version, reason, or disposition changes.
- No frontend sender changes.
- No removal of protocol-v11 wire decoding.
- No change to `request_keyframe`, `frame_applied`, `window_ref_miss`, output-pressure acknowledgement, timeout recovery, or renderer correlation policy.
- No Editor state transition and no new renderer transition.
- One Editor mailbox remains the ordered event authority.
- Renderer State remains the sole writer for acknowledgement and recovery state.
- The Editor forwards status unchanged and does not interpret disposition.
- Missing renderer PID behavior remains unchanged.

#### Dependencies and budget

- **Dependencies:** None. Protocol-v12 dispositions and renderer handling are merged.
- **Maximum production files:** 2
- **Maximum net production-line delta:** `+5`
- **Expected production delta:** Zero or negative after deleting the runtime compatibility clause.
- **Maximum test delta:** `+25`
- **New concepts:** None
- **Removed concept:** Five-element runtime `:frame_rejected` compatibility
- **Implementer questions:** None

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2978
- **Commit SHA:** `db9163c5c`
- **Merge SHA:** `e902f97844570e1525424bfa8d3243ae550ea6d4`
- **Focused tests:** `mix test.debug test/minga_editor/frontend/protocol_test.exs test/minga_editor/renderer/server_test.exs` — 179 passed
- **Broad validation:** `make lint` passed (Credo: 3 changed source files, no issues; compile and incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 8:8' mix test.llm` passed (58 doctests, 98 properties, 9,839 tests, 0 failures, 1 skipped, 574 excluded; max_cases 16); all required PR checks passed
- **Ponytail verdict:** LEAN, including targeted helper recheck
- **Bug-hunt verdict:** PASS, correctness including targeted helper recheck
- **Elixir craftsmanship verdict:** IDIOMATIC, including targeted helper recheck
- **Final reviewer verdict:** PASS
- **Production lines added/removed:** 11 added / 10 removed, net +1
- **Test lines added/removed:** 32 added / 8 removed, net +24
- **Concepts added/removed:** None added; removed five-element runtime `:frame_rejected` compatibility
- **Findings resolved:** L01 routed canonical correlated frame rejection from `MingaEditor` to renderer recovery without Editor state mutation
- **Discoveries affecting later work:** Silent-failure review: PASS. Default-concurrency broad runs exposed pre-existing unrelated suite races; seed 30291 reproduced the extension timeout on untouched `origin/main` with 9,838 tests passing, and another run got `:noproc` where an unrelated lifecycle test expected `:killed`; reduced scheduler count produced a clean full pass. No later-work contract discovery
- **Completion date:** 2026-07-18

### W002: Failed saves prevent shutdown

#### Status and provenance

- **Status:** VERIFIED
- **Audit ID:** L02
- **Roadmap unit:** W002, Failed saves prevent shutdown
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.6-sol`, `xhigh`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.6-luna`, `high`
- **Freshness SHA:** `1134ddaa7a25052546ef23789fa926d1685ebb44`
- **Freshness basis:** Current `HEAD` and `origin/main` both resolve to the freshness SHA. The failure was reproduced by tracing the current source. No build or test was run, as required by the read-only constraint.

#### Observable outcome

For ordinary buffer-backed saves:

- `:wq` closes the current tab or quits only when the active save succeeds.
- `:wqa` invokes the existing shutdown path only when every dirty buffer in `state.workspace.buffers.list` saves successfully.
- A save error or process exit returns the current Editor state without closing or shutting down.
- Active-save failure feedback remains in the returned state.
- Save-all stops at the first failure. Saves completed before that failure remain committed; there is no rollback.
- Successful behavior remains unchanged: `:wq` saves and delegates to `close_tab_or_quit/1`; `:wqa` saves all currently enumerated dirty buffers and delegates to `shutdown_editor/1`.

This outcome intentionally covers only the active workspace inventory already used by `save_all_buffers/1`.

#### Current producer-to-consumer failure path

The path remains present at the freshness SHA:

1. `Minga.Command.Parser` produces `{:save_quit, []}` for `wq` and `{:save_quit_all, []}` for `wqa`.
2. `MingaEditor.Commands.execute/2` routes both ex tuples directly to `MingaEditor.Commands.BufferManagement.execute/2`.
3. `execute(state, :save)` applies pre-save transforms and calls `Minga.Buffer.save/1`.
4. `Buffer.save/1` produces `:ok` or `{:error, reason}`. `BufferManagement` converts either result into an `EditorState` with the corresponding notice or conflict presentation, losing the success tag.
5. `execute/2` for `{:save_quit, []}` pipes that state directly into `close_tab_or_quit/1`, including states produced by `:no_file_path`, `:file_changed`, or another save error.
6. `save_all_buffers/1` uses `Enum.each/2`, ignores every `Buffer.save/1` return value, catches process exits as `:ok`, and returns the input state.
7. `execute/2` for `{:save_quit_all, []}` pipes that state unconditionally into `shutdown_editor/1`.
8. `shutdown_editor/1` resolves wait requests and calls the configured `:shutdown_fn`, defaulting to `System.stop/1`.

#### Authoritative owners

- **Write outcome and buffer dirty state:** `Minga.Buffer.Process`, exposed through `Minga.Buffer.save/1`.
- **Save, close, and shutdown sequencing:** `MingaEditor.Commands.BufferManagement`. This is the workflow owner under ADR-0002 because it coordinates Buffer process calls, notice state, tab transitions, wait requests, and shutdown effects.
- **Notice and conflict presentation:** Existing `MingaEditor.Shell.Traditional.NoticeWorkflow`, `handle_file_changed_on_save/2`, and remote conflict picker workflow.
- **Tab closing:** Existing `close_tab_or_quit/1` and its current Tab/TabBar workflows.
- **Process shutdown:** Existing `shutdown_editor/1`.
- **Wait-request disposition:** Existing close and shutdown functions. The save workflow must not duplicate or move this responsibility.

No root state, Buffer owner, lifecycle owner, or persistence owner changes.

#### Exact return shape

Add exactly one private tagged result:

```elixir
@typep save_result :: {:ok, state()} | {:error, state()}
```

Semantics:

- `{:ok, state}` means the required save or save set succeeded and the caller may close or shut down.
- `{:error, state}` means at least one required save failed or exited and the caller must return that state unchanged by close or shutdown.
- Active-save errors carry the existing notice, warning, or conflict UI state.
- Save-all retains its current notice behavior and does not introduce a new per-buffer notice.
- The result does not carry a reason. No consumer needs it, and adding `{:error, reason, state}` would duplicate information already projected for active saves.
- `execute/2` continues to return only `EditorState.t()`. The tagged result remains private to this module.

#### Exact files, symbols, producers, and consumers

##### Production change

`lib/minga_editor/commands/buffer_management.ex`

Changed or added symbols:

- `@typep save_result`
- `execute/2`, ordinary `:save` clause
- `execute/2`, `{:execute_ex_command, {:save_quit, []}}` clause
- `execute/2`, `{:execute_ex_command, {:save_quit_all, []}}` clause
- New private `save_active_buffer/1`
- Existing private `save_all_buffers/1`
- New private recursive `save_all_buffers/2`

Retained, unchanged consumers:

- `close_tab_or_quit/1`
- `shutdown_editor/1`
- `complete_active_wait_on_close/1`
- `cancel_active_wait_request/2`
- `Minga.Frontend.WaitRequests`

Retained, unchanged producers:

- `Minga.Buffer.save/1`
- `Minga.Buffer.Process.handle_call(:save, ...)`
- `Minga.Command.Parser`
- `MingaEditor.Commands.execute/2`

##### Test change

Create:

`test/minga_editor/commands/buffer_management_save_quit_test.exs`

A separate file is required because shutdown observation mutates `Application` environment. The existing `buffer_management_frontend_test.exs` is `async: true`; changing it to serialized execution would unnecessarily slow unrelated tests and violate the separate-file rule for global-state tests.

##### Roadmap change

`docs/workstreams/editor-lifecycle-roadmap.md`

Replace the W002 candidate block with this READY specification. Implementation completion evidence remains pending until the PR merges.

##### Contract sources that must not change

- `FINDINGS.md`
- `lib/minga/buffer.ex`
- `lib/minga/buffer/process.ex`
- `lib/minga/api.ex`, including `Minga.API.save/1`
- `lib/minga/command/parser.ex`
- `lib/minga_editor/commands.ex`
- `lib/minga_editor/state.ex`
- `lib/minga_editor/state/tab/context.ex`
- `lib/minga_editor/commands/dired.ex`
- `Minga.Buffer.save_all_dirty/0` and `test/minga/buffer/save_all_dirty_test.exs`

#### Locked implementation shape

##### Active save

1. Keep the existing Dired `execute(state, :save)` clause unchanged.
2. Move the ordinary active-buffer save workflow into `save_active_buffer/1`.
3. The regular helper must preserve this exact order:
   1. `apply_pre_save_transforms/2`
   2. `Buffer.save/1`
   3. Existing success notice, file-changed handling, no-path notice, or generic failure notice
   4. Wrap the resulting state in `{:ok, state}` or `{:error, state}`
4. Catch only process exits from the ordinary active-save workflow. Convert an exit to:
   ```elixir
   {:error, NoticeWorkflow.publish(state, "Save failed: #{inspect(reason)}")}
   ```
   Do not catch exceptions or throws.
5. Add a Dired-specific `save_active_buffer/1` clause that invokes the existing `:dired_apply_changes` command and returns `{:ok, returned_state}`. Dired has no save-success contract, so this preserves current Dired `:wq` behavior rather than inventing one.
6. The public ordinary `execute(state, :save)` clause unwraps either tag and returns only the state:
   ```elixir
   {_status, state} = save_active_buffer(state)
   state
   ```
7. `:wq` calls `save_active_buffer/1` directly:
   ```elixir
   case save_active_buffer(state) do
     {:ok, state} -> close_tab_or_quit(state)
     {:error, state} -> state
   end
   ```

##### Save-all

`save_all_buffers/1` must return `save_result()` and delegate to a private recursive `save_all_buffers/2` over the exact current list:

```elixir
state.workspace.buffers.list
```

The recursive contract is locked:

- Empty list returns `{:ok, state}`.
- A clean live buffer is skipped.
- A dirty buffer returning `:ok` advances to the next buffer.
- A dirty buffer returning `{:error, _reason}` immediately returns `{:error, state}`.
- An exit from either `Buffer.dirty?/1` or `Buffer.save/1` immediately returns `{:error, state}`.
- The traversal does not attempt later buffers after a failure.
- Previously saved buffers remain saved.
- No pre-save transforms, conflict UI, save notice, force-save, deduplication, or alternate inventory is introduced.

`:wqa` branches only on that result:

```elixir
case save_all_buffers(state) do
  {:ok, state} -> shutdown_editor(state)
  {:error, state} -> state
end
```

##### Shared-helper decision

One workflow helper must **not** serve both active save and save-all.

Active save owns pre-save transforms, notices, local and remote conflict presentation, and Dired dispatch. Save-all intentionally performs raw dirty-buffer writes without those behaviors. Sharing one workflow helper would require mode flags or would change existing behavior.

The two paths share only:

- The private `save_result` contract
- Existing `Buffer.dirty?/1` and `Buffer.save/1`
- Existing close and shutdown owners

No generic save wrapper or result framework is allowed.

#### Ordered implementation steps

1. Add the private `save_result` type.
2. Extract the current ordinary `:save` body into tagged `save_active_buffer/1`, preserving branch order and exact notice strings.
3. Add the Dired-specific `save_active_buffer/1` clause that classifies current Dired behavior as successful without changing it.
4. Make public `execute(state, :save)` unwrap the private result and retain its `EditorState.t()` return contract.
5. Replace the `:wq` pipeline with the exact success/error case split.
6. Replace side-effect-only `save_all_buffers/1` with the ordered, first-failure-stopping tagged traversal.
7. Replace the `:wqa` pipeline with the exact success/error case split.
8. Add the dedicated serialized regression test file.
9. Run focused and broad validation.
10. Update W002 completion evidence only after validation and review. Do not alter L03 or claim it resolved.

#### Required tests

##### File and layer

`test/minga_editor/commands/buffer_management_save_quit_test.exs`

Use `Minga.Test.EditorCase` with rendering disabled. This is the cheapest deterministic layer that exercises real Buffer processes, command workflow state, tab closing, notices, and the configured shutdown function.

The module header must include the mandated explanation:

```elixir
# Mutates Application env (:minga, :shutdown_fn); must not run concurrently with other tests.
use Minga.Test.EditorCase, async: false, rendering: :disabled
```

Use `@moduletag :tmp_dir`.

Setup must:

1. Save the previous `Application.get_env(:minga, :shutdown_fn)`.
2. Install a function that synchronously sends `{:shutdown, status}` to the test process.
3. Restore the exact previous value in `on_exit/1`, deleting the key when it was previously absent.
4. Follow the existing `NoGlobalStateInTestCheck` suppression pattern from `test/minga/chaos/editor_fuzzer_test.exs`.

Use no sleeps, polling, `Process.alive?/1`, or foreign struct updates.

##### Assertions

1. **`"failed :wq keeps the active tab open and preserves the save notice"`**
   - Start an editor with a scratch buffer.
   - Add a second unnamed buffer through the existing command API so closing would visibly remove a tab.
   - Execute `{:execute_ex_command, {:save_quit, []}}`.
   - Assert the active buffer PID is unchanged.
   - Assert tab labels are unchanged.
   - Assert the notice is exactly `"No file name — use :w <filename>"`.
   - `refute_received {:shutdown, 0}`.

2. **`"successful :wq saves and closes the active tab"`**
   - Start with one file-backed buffer and open a second file through `MingaEditor.open_file/2`.
   - Edit the second buffer through `Buffer.insert_text/2`.
   - Execute `:wq`.
   - Assert the second file contains the edit.
   - Assert exactly one file tab remains and the closed tab is absent.
   - `refute_received {:shutdown, 0}` because another tab remains.

3. **`"failed :wqa does not shut down and stops before later buffers"`**
   - Make the first buffer in `workspace.buffers.list` a dirty unnamed buffer.
   - Open a writable file-backed buffer second and make it dirty.
   - Execute `:wqa`.
   - `refute_received {:shutdown, 0}`.
   - Assert the later buffer remains dirty.
   - Assert its on-disk content is unchanged.
   - This proves first-failure termination rather than merely suppressing shutdown after continuing all saves.

4. **`"successful :wqa saves every current-workspace dirty buffer and invokes shutdown"`**
   - Use two writable file-backed buffers in the active workspace.
   - Make both dirty through Buffer APIs.
   - Execute `:wqa`.
   - Assert both files contain their edits.
   - Assert both buffers are clean.
   - `assert_received {:shutdown, 0}`.

5. **`"active buffer exit is a failed :wq"`**
   - Capture an owner-created Editor state.
   - Monitor and stop its active Buffer process, then assert the matching `:DOWN`.
   - Call `BufferManagement.execute/2` directly with the captured state and `:wq`.
   - Assert it returns an `EditorState`.
   - Assert the returned notice starts with `"Save failed:"`.
   - `refute_received {:shutdown, 0}`.
   - Do not mutate the captured state.

6. **`"buffer exit stops :wqa without shutdown"`**
   - Capture an owner-created Editor state containing the Buffer PID.
   - Monitor and stop that Buffer, then assert the matching `:DOWN`.
   - Call `BufferManagement.execute/2` directly with the captured state and `:wqa`.
   - Assert it returns an `EditorState` without raising.
   - `refute_received {:shutdown, 0}`.
   - This deterministically exercises the exit path without racing the Editor’s buffer monitor.

Existing `:file_changed`, no-path notice, and input-routing tests remain in place. No snapshot test is required because the rendered model does not change.

#### Validation

Focused:

```bash
mix test.debug test/minga_editor/commands/buffer_management_save_quit_test.exs test/minga_editor/input/handler_test.exs test/minga_editor/input/router_test.exs test/minga/buffer/mtime_test.exs
```

Broad:

```bash
make lint
mix test.llm
```

No Swift, Go, Zig, protocol generation, or snapshot validation is required because the wire format and frontend behavior do not change.

#### Non-goals

- Do not implement L03.
- Do not enumerate buffers from inactive tab contexts, stashed shell state, other workspaces, or root lifecycle monitors.
- Do not add root-level buffer inventory, deduplication, retirement logic, or new ownership APIs.
- Do not change which buffers `:wqa` considers.
- Do not change `:quit`, `:quit_all`, force-quit, or quit-confirmation behavior.
- Do not change `Minga.API.save/1`.
- Do not change `Minga.Buffer.save_all_dirty/0`, whose continue-after-error behavior is a separate contract.
- Do not add transactional save rollback.
- Do not add save retries, telemetry, configuration, or error aggregation.
- Do not introduce new notices for save-all failures.
- Do not change file persistence or Buffer dirty tracking.

#### Retained constraints

- Active `:save` and `:wq` apply pre-save transforms exactly once.
- `:wqa` does not apply pre-save transforms, matching current behavior.
- Local and remote file-conflict handling remains unchanged.
- Existing save notice strings remain unchanged for all current `Buffer.save/1` return values.
- Dired `:save`, Dired `:wq`, and Dired confirmation behavior remain unchanged.
- `:force_save` and Dired force-save behavior remain unchanged.
- Failed save-and-quit paths do not close, cancel, accept, or otherwise resolve wait requests.
- Successful close and shutdown paths retain their existing wait-request behavior.
- `close_tab_or_quit/1` remains the sole close-or-quit decision point.
- `shutdown_editor/1` remains the sole normal shutdown effect owner.
- Save-all retains `state.workspace.buffers.list` order and stops on the first error or exit.
- Inactive-tab-only buffers remain ignored. L03 stays `ROUTE/archie`.

#### Dependencies

- W001 is `VERIFIED`.
- W003 through W006 remain `CANDIDATE`.
- No W002 owner area is currently `READY` or `ACTIVE`.
- Current `HEAD` equals current `origin/main`.
- L03 is not a dependency because this specification explicitly preserves its current behavior and architecture gap.
- No architecture, protocol, frontend, or persistence dependency remains.

#### Line and concept budget

- **Maximum production files:** 1
- **Authorized target net production delta:** `<= +25`
- **Absolute roadmap ceiling:** `+40`; exceeding `+25` requires replanning rather than compressing code, and exceeding `+40` is blocked.
- **Expected production delta:** `[INFERENCE]` Between `+10` and `+25`, primarily the private result type, active-save extraction, and short-circuit branches.
- **Maximum test delta:** `+180`
- **Documentation lines:** Count separately; only the W002 roadmap block changes.
- **New concepts:** Exactly one private `save_result` contract.
- **Reused concepts:** `Buffer.save/1`, `Buffer.dirty?/1`, current notice/conflict workflows, Dired command dispatch, `close_tab_or_quit/1`, `shutdown_editor/1`, WaitRequests, and current active-workspace buffer order.
- **Removed concepts:** State-only implicit save success, unconditional `:wq` close pipeline, side-effect-only `save_all_buffers/1`, ignored save errors, and catch-and-continue save-all exits.
- **Forbidden additions:** New module, process, dependency, behaviour, protocol, registry, public API, configuration, persistence shape, owner, generic wrapper, compatibility shim, or parallel result framework.
- **Review scope:** `[INFERENCE]` One production file, one dedicated test file, and one roadmap update fit one reviewable PR.

#### Definition of Ready

1. The Ponytail verdict is `ACCEPT`.
2. The finding remains reproducible on current main.
3. One independently verifiable outcome is locked.
4. The authoritative state, process, protocol, or persistence owner is known.
5. The exact target return shape, struct, tagged state, tuple, or transition contract is specified.
6. Expected files, symbols, producers, and consumers are named.
7. The exact test layer, test file, assertions, and edge cases are specified.
8. Non-goals and retained constraints are explicit.
9. Dependencies are merged and no overlapping-owner work is active.
10. Exact focused and broad validation commands are listed.
11. The production-line and concept budgets are locked.
12. No unresolved question remains for the implementer.
13. The work fits in one reviewable PR.

#### Implementer-question status

None. The implementer must return `NEEDS_REPLAN` rather than choose a different result shape, inventory, notice policy, helper abstraction, or production budget.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2980
- **Commit SHA:** `e3a981b04`
- **Merge SHA:** `ad4f7dc07`
- **Focused tests:** `mix test.debug test/minga_editor/commands/buffer_management_save_quit_test.exs test/minga_editor/input/handler_test.exs test/minga_editor/input/router_test.exs test/minga/buffer/mtime_test.exs` — 47 passed
- **Broad validation:** `make lint` passed; `ERL_FLAGS='+S 8:8' mix test.llm` passed — 58 doctests, 98 properties, 9,845 tests, 0 failures, 1 skipped, 574 excluded
- **Ponytail verdict:** LEAN
- **Bug-hunt verdict:** PASS
- **Elixir craftsmanship verdict:** IDIOMATIC
- **Final reviewer verdict:** PASS
- **Production lines added/removed:** 60 added / 37 removed, net +23
- **Test lines added/removed:** 140 added / 0 removed, net +140
- **Concepts added/removed:** One private `save_result` contract added; removed implicit state-only save success, unconditional save-and-quit close/shutdown, ignored save errors, and catch-and-continue save-all exits
- **Findings resolved:** L02, failed saves no longer close the active tab or shut down the editor
- **Discoveries affecting later work:** Silent-failure review: PASS. Default-concurrency `mix test.llm` hit five unrelated MingaAgent timeout failures after 8,155 tests; untouched current `main` reproduced the known suite-instability class with an unrelated extension timeout and `erl_child_setup` EPIPE after 9,839 tests. The already-established reduced scheduler count produced a clean full pass. No later-work contract discovery; L03 remains out of scope and W003-W006 were not changed
- **Completion date:** 2026-07-18

### W003: Dirty buffers require explicit destruction

#### Status and provenance

- **Status:** VERIFIED
- **Audit ID:** L04
- **Roadmap unit:** W003, Dirty buffers require explicit destruction
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.6-sol`, `xhigh`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.6-luna`, `high`
- **Freshness SHA:** `ba7c7893db582a7ea99ba2ffe366c3e8d8a2c3c5`
- **Freshness basis:** `HEAD`, `main`, and `origin/main` resolved to the freshness SHA when Sol/xhigh planned this unit. The worktree was clean and L04 was reproduced from current source. Planning ran no build or tests.

#### Observable outcome

Ordinary `:kill_buffer` refuses to destroy the selected live, non-persistent Buffer process when `Buffer.dirty?/1` returns `true`. It leaves the Buffer process, buffer pool, tab, highlighting state, and wait request intact, then publishes this exact notice:

```text
Buffer has unsaved changes. Use SPC b X to force kill.
```

The new `:force_kill_buffer` command explicitly bypasses only the dirty-buffer refusal and runs the existing destruction sequence. It is registered as `command(:force_kill_buffer, "Force kill current buffer", requires_buffer: true)` and bound to `SPC b X`. No Ex command, GUI action, mouse gesture, confirmation prompt, configuration option, or alternate retirement API is added.

#### Current producer-to-consumer failure path

1. `MingaEditor.Commands.BufferManagement.execute/2` receives `:kill_buffer`.
2. `MingaEditor.Shell.Workflow.resolve_active_tab_kind/1` routes agent tabs to `close_agent_tab/1` and every other result to `remove_current_buffer/1`.
3. `remove_current_buffer/1` selects the target with `Enum.at(buffers, active_index)`.
4. Persistent buffers are cleared instead of stopped.
5. Non-persistent buffers proceed without calling `Buffer.dirty?/1`.
6. The workflow completes the active wait request, broadcasts `:buffer_closed`, stops the Buffer process, closes parser/highlight state, logs the close, removes the tab and buffer, and restores a neighbor or enters the launchpad.

L04 therefore remains reproducible at the freshness SHA.

#### Producer inventory

Every current static producer is covered by the command boundary:

1. `Minga.Keymap.Defaults.@leader_bindings`: `SPC b d` emits `:kill_buffer`.
2. `Minga.Keymap.Defaults.@leader_bindings`: `SPC TAB d` emits `:kill_buffer`.
3. `MingaEditor.Mouse.close_tab_by_command/2` switches to the middle-clicked tab and dispatches `:kill_buffer`.
4. `MingaEditor.Handlers.GuiActionHandler.dispatch_action/2` dispatches `:kill_buffer` only for GUI close of the selected last file tab.
5. `MingaEditor.Commands.Dired.close_dired/1` deactivates Dired, restores editor scope, and dispatches ordinary `:kill_buffer`.
6. `MingaEditor.Commands.BufferManagement.close_all_file_tabs/1` removes other file tabs and calls ordinary `:kill_buffer` for the remaining active target.
7. `command(:kill_buffer, ...)` exposes the atom through `Minga.Command.Registry`, generic command execution, and `MingaEditor.UI.Picker.CommandSource`.
8. User and extension keymaps may bind the registered command through existing APIs.

No current producer migrates to force. Tab-only closes remain distinct because `close_file_tab/1`, `close_other_tabs/1`, and `close_tabs_to_right/1` remove views without stopping Buffer processes. GUI close of a non-last file tab continues through `:force_quit`, which closes the tab while retaining the Buffer in the pool.

#### Authoritative owners

- Dirty, persistent, and content state: the selected `Minga.Buffer` process.
- Ordinary versus intentional destruction sequencing: `MingaEditor.Commands.BufferManagement`.
- Refusal feedback: `MingaEditor.Shell.Traditional.NoticeWorkflow`.
- Wait request completion: existing `Minga.Frontend.WaitRequests`.
- Buffer-close events: existing `Minga.Events`.
- Parser/highlight cleanup: existing `MingaEditor.HighlightSync`.
- Tab and buffer-pool transitions: existing `MingaEditor.State.Buffers`, `MingaEditor.State.TabBar`, `MingaEditor.BufferActivation`, and current root lifecycle functions.
- Dead-process cleanup: existing `MingaEditor.Handlers.BufferRegistry.retire_dead_buffer/2` through `MingaEditor.handle_info/2`.
- Command registration, palette discovery, and default binding: existing Registry, CommandSource, and Keymap.Defaults owners.

No owner moves and no new owner is introduced.

#### Locked transition contract

Add one private intent type:

```elixir
@typep kill_intent :: :ordinary | :force
```

Public command execution continues to return `state()`.

| Active target | Intent | Required transition |
| --- | --- | --- |
| Agent tab | Either | Call existing `close_agent_tab/1`; do not query or destroy the file Buffer process. |
| Persistent Buffer | Either | Clear content through `Buffer.replace_generated_content(buffer, "")`, retain PID and tab, and publish the existing persistent notice. |
| Live non-persistent clean Buffer | Ordinary | Run the existing destruction sequence unchanged. |
| Live non-persistent dirty Buffer | Ordinary | Return with only the exact refusal notice; do not complete wait requests, broadcast close, stop the process, close highlighting, remove tabs, alter the pool, or activate a replacement. |
| Live non-persistent Buffer | Force | Do not call `Buffer.dirty?/1`; run the existing destruction sequence unchanged. |
| Buffer exits during persistence or dirty query | Either | Continue stale-process cleanup; do not refuse or crash. |
| Missing or invalid active target | Either | Preserve the existing unchanged-state fallback. |

The persistence and dirty decisions must apply to the exact PID selected by `Enum.at(buffers, active_index)`, which is the PID the workflow would stop.

#### Locked implementation shape

1. In `MingaEditor.Commands.BufferManagement`, make `execute(state, :kill_buffer)` call private `kill_active_tab(state, :ordinary)` and add `execute(state, :force_kill_buffer)` calling `kill_active_tab(state, :force)`.
2. Add `kill_active_tab/2` with an explicit spec. Reuse `Workflow.resolve_active_tab_kind/1`; route `:agent` to `close_agent_tab/1` and file/default results to `remove_current_buffer/2`.
3. Change `remove_current_buffer/1` to `remove_current_buffer/2` with `kill_intent()`.
4. Update the existing `quit_last_file_tab/1` caller to pass `:force`, preserving its existing upstream quit confirmation and configuration behavior without adding another quit-policy owner.
5. Retain the current `buffers` and `active_index` pattern and derive the same target PID.
6. Preserve persistence precedence. Query `Buffer.persistent?/1` with the current exit fallback; persistent targets never run dirty refusal; force never calls `Buffer.dirty?/1`; ordinary live non-persistent targets call it; an exit from either query continues cleanup.
7. Express the decision with direct pattern matching. No `cond`, callback option, policy map, confirmation state, or generic wrapper.
8. Replace the current foreign `:sys.replace_state/2` persistent-buffer mutation with `:ok = Buffer.replace_generated_content(buf, "")`; remove the now-unused `Minga.Buffer.Document` alias.
9. For ordinary dirty refusal, return `NoticeWorkflow.publish(state, "Buffer has unsaved changes. Use SPC b X to force kill.")` before every destructive side effect.
10. For allowed destruction, preserve the exact existing order: display name, active wait completion, path and close event, normal process stop, highlight cleanup, close log, buffer-list removal, tab removal, then neighbor activation or launchpad.
11. Register `:force_kill_buffer` beside `:kill_buffer` with description `"Force kill current buffer"` and `requires_buffer: true`.
12. Add `{~k(b X), :force_kill_buffer, "Force kill buffer"}` beside the existing buffer kill binding.
13. Leave every existing mouse, GUI, Dired, close-all, palette, and keymap producer on ordinary `:kill_buffer`.
14. Do not add an Ex alias such as `:bd!`.

#### Exact files and symbols

Production:

- `lib/minga_editor/commands/buffer_management.ex`: `execute/2`, new `kill_active_tab/2`, `remove_current_buffer/2`, persistence/dirty decision helpers only if needed, `quit_last_file_tab/1`, `command(:force_kill_buffer, ...)`, and removal of `Minga.Buffer.Document` alias.
- `lib/minga/keymap/defaults.ex`: `@leader_bindings` only.

Tests:

- New `test/minga_editor/commands/buffer_management_kill_test.exs` for focused real-Buffer workflow contracts.
- `test/minga/command/registry_test.exs`: required built-in command set.
- `test/minga/keymap/defaults_test.exs`: ordinary, force, and tab kill bindings.

Roadmap:

- `docs/workstreams/editor-lifecycle-roadmap.md`: replace W003 candidate with this locked specification, mark ACTIVE during implementation, and reserve completion evidence.

Verified unchanged producers and consumers include `lib/minga_editor/mouse.ex`, `lib/minga_editor/handlers/gui_action_handler.ex`, `lib/minga_editor/commands/dired.ex`, `lib/minga_editor/commands.ex`, `lib/minga_editor/ui/picker/command_source.ex`, `lib/minga/command/registry.ex`, `lib/minga/frontend/wait_requests.ex`, `lib/minga_editor/highlight_sync.ex`, `lib/minga_editor/handlers/buffer_registry.ex`, and `lib/minga_editor.ex`.

#### Required test layer

Use direct command-workflow tests with real supervised Buffer GenServers and state created through `MingaEditor.Startup.build_initial_state/1`.

- `ExUnit.Case, async: true`.
- No Editor GenServer or HeadlessPort.
- `start_supervised!/1` for Buffer and options processes.
- `Process.monitor/1` plus pinned `assert_receive` or `refute_received` for lifecycle.
- Direct `Minga.Buffer` queries for content and dirty state.
- `NoticeWorkflow.message/1` for feedback.
- Unique real WaitRequests registrations for wait behavior.
- No sleeps, polling, `Process.alive?/1`, `:sys.get_state/1` state assertions, or foreign struct writes.

#### Required tests

Add `test/minga_editor/commands/buffer_management_kill_test.exs` with exactly these five contracts:

1. **`"ordinary kill refuses a dirty buffer without completing its wait request"`**: start a file-backed non-persistent Buffer; build initial Editor state; capture PID, list, and tab ID; modify through `Minga.Buffer`; register a matching wait request; monitor; execute ordinary kill; assert the exact refusal notice; assert active PID, list, tab ID, content, and dirty state are unchanged; refute Buffer `:DOWN`; refute wait completion.
2. **`"ordinary kill destroys a clean buffer and accepts its wait request"`**: start a clean file-backed non-persistent Buffer; register and monitor; execute ordinary kill; assert `%WaitRequestCompletion{outcome: :accepted}`; assert Buffer exits `:normal`; assert active is nil, list empty, and `MingaEditor.State.Launchpad` active.
3. **`"force kill destroys a dirty buffer and cancels its wait request"`**: start and modify a file-backed non-persistent Buffer; register and monitor; execute force kill; assert `%WaitRequestCompletion{outcome: {:cancelled, "closed with unsaved changes"}}`; assert normal Buffer exit; assert empty buffer list and active launchpad.
4. **`"ordinary and force kills clear persistent buffers without stopping them"`**: exercise both commands against separate dirty persistent Buffers; monitor; assert each PID remains active and listed; content becomes `""`; dirty remains true; exact existing notice is `"Buffer is persistent — content cleared"`; refute corresponding `:DOWN`.
5. **`"ordinary kill retires an already-exited buffer"`**: build state around non-persistent Buffer; monitor and stop, consume matching `:DOWN`; execute ordinary kill on captured state; assert no raise; assert stale PID removed and launchpad active; assert dirty-refusal notice absent.

Update registry test to require `:force_kill_buffer`.

Update keymap tests to retain `SPC b d -> :kill_buffer`, assert `SPC b X -> :force_kill_buffer`, and assert `SPC TAB d -> :kill_buffer`.

Existing agent-tab tests remain the proof that ordinary `:kill_buffer` uses the separate agent lifecycle. No new mouse, GUI, Dired, or palette integration test is needed because those producers remain unchanged and converge on the command boundary; registry and keymap tests prove force discovery and its only default producer.

#### Dired retained-behavior constraint

`MingaEditor.Commands.Dired.close_dired/1` remains unchanged. It deactivates Dired and dispatches ordinary `:kill_buffer`; it never calls force. A dirty active Buffer reached through that path is refused. The deactivate-before-dispatch ordering remains. W003 must not inspect or retire `state.workspace.dired.buffer` or repair stale active-buffer versus backing-buffer identity. W004 exclusively owns that targeting and process-death cleanup.

#### Validation

Focused:

```bash
mix test.debug test/minga_editor/commands/buffer_management_kill_test.exs test/minga_editor/launchpad_integration_test.exs
mix test.debug test/minga_editor/commands/agent_split_toggle_test.exs
mix test.debug test/minga/command/registry_test.exs test/minga/keymap/defaults_test.exs
```

Broad:

```bash
make lint
ERL_FLAGS='+S 8:8' mix test.llm
```

No Swift, Go, Zig, protocol generation, snapshot, browser, or frontend build is required.

#### Non-goals and retained constraints

- No confirmation prompt, yes/no state, policy object, new module, process, dependency, behaviour, protocol, registry, adapter, manager, configuration, persistence shape, compatibility shim, or parallel retirement API.
- No L03 root inventory or inactive-context change; no W004 Dired PID ownership change.
- No quit-all, save-all, forced middle-click, forced GUI action, `:force_kill_all_buffers`, or Ex kill aliases.
- No retry, telemetry, delayed cleanup, polling, or async confirmation.
- No event-shape, wait-text, parser, highlighting, tab, window, launchpad, or BufferRegistry ownership change.
- Clean ordinary kills retain current event, wait, stop, parser cleanup, tab removal, activation, and launchpad behavior.
- Forced dirty kills reuse that exact sequence.
- Ordinary refusal occurs before every destructive or close-reporting effect.
- Persistent buffers remain persistent and never stop; agent tabs retain their separate close path; dead PIDs reach cleanup.
- Tab-only closes remain tab-only and may close views of dirty buffers because the Buffer process survives.
- Mouse and GUI routing remains unchanged.
- `BufferManagement` remains workflow owner and `Minga.Buffer` remains the only writer of Buffer state.

#### Dependencies and budget

- W001 and W002 are VERIFIED.
- L03 is not a dependency because W003 checks only the exact existing destruction target.
- W004-W006 remain CANDIDATE and no overlapping owner unit is READY or ACTIVE.
- **Maximum production files:** 2
- **Maximum net production-line increase:** `+30`
- **Expected production delta:** approximately `+15` to `+25`, offset by removing the `Document` alias and direct `:sys.replace_state/2` block.
- **Maximum test files changed:** 3
- **Maximum net test-line increase:** `+150`
- **Maximum documentation files changed:** 1
- **Maximum net documentation-line increase:** `+220`
- **New concepts allowed:** exactly one registered `:force_kill_buffer` command and one private two-value `kill_intent`.
- **Removed concepts:** unguarded ordinary dirty destruction and foreign mutation of Buffer process state.
- **Forbidden additions:** confirmation framework, policy object, new owner, public Elixir API, alternate result struct, protocol action, configuration flag, lifecycle wrapper, force alias, compatibility path, or root inventory.

Exceeding a budget or requiring a new owner or contract returns W003 to BLOCKED for a named decision.

#### Definition of Ready

All 13 conditions pass: accepted verdict; reproduction on current main; one locked outcome; known owners; exact intent and transition table; named files, symbols, producers, and consumers; exact tests and edge cases; explicit non-goals; merged dependencies with no overlap; exact validation; fixed production/test/documentation and concept budgets; no unresolved question; one reviewable PR.

- **Definition of Ready status:** PASS
- **Implementer-question status:** None. The implementer must return `NEEDS_REPLAN` rather than change the command, keybinding, notice, owner, producer behavior, test layer, persistent-buffer semantics, Dired constraint, or any budget.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2982
- **Commit SHA:** `316dfe39fe1e3dc6cea3a21fbacfb62134443222`
- **Merge SHA:** `2a4e20884f4049cd647b5f86a8e99d030963e77a`
- **Focused tests:** `mix test.debug test/minga_editor/commands/buffer_management_kill_test.exs test/minga_editor/launchpad_integration_test.exs` passed (6); `mix test.debug test/minga_editor/commands/agent_split_toggle_test.exs` passed (21); `mix test.debug test/minga/command/registry_test.exs test/minga/keymap/defaults_test.exs` passed
- **Broad validation:** `make lint` exited 0 (format, changed-file Credo, compile, incremental Dialyzer; Credo reported two non-blocking boolean-case refactoring suggestions, including the locked direct-pattern-match decision); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,851 tests, 0 failures, 1 skipped, 574 excluded). The planned `+S 8:8` run and an intermediate `+S 4:4` run each exposed one unrelated 5-second MingaAgent subscription timeout in different modules; both failed cases passed immediately in isolation before the contention-safe full run.
- **Ponytail verdict:** LEAN, no findings after the targeted shrink recheck
- **Bug-hunt verdict:** PASS after the registry-coverage fix; silent-failure review PASS
- **Elixir craftsmanship verdict:** IDIOMATIC
- **Final reviewer verdict:** PASS, 1.00 confidence after the targeted staged-patch recheck; no findings
- **Production lines added/removed:** 2 production files, +91/-73, net +18
- **Test lines added/removed:** 3 test files, +144/-1, net +143
- **Concepts added/removed:** Added the private `kill_intent` (`:ordinary | :force`) and registered `:force_kill_buffer`; removed unguarded ordinary dirty destruction and foreign `:sys.replace_state/2` Buffer mutation
- **Findings resolved:** L04, ordinary dirty-buffer destruction now refuses before destructive effects and explicit force destruction reuses the existing lifecycle
- **Discoveries affecting later work:** W004-W006 remain untouched. Headless focused workflow tests required a module-scoped real `WaitRequests` tracker because the runtime supervisor is not started; request IDs remained unique. Review fixes reduced the kill decision to one catch-scoped query, switched the focused tests to the public `Minga.Buffer` API, restored `:new_buffer` registry coverage, and consolidated ordinary and force keymap coverage. No new discovery affecting later work
- **Completion date:** 2026-07-18

### W004: Dired targets its backing buffer

- **Status:** VERIFIED
- **Audit ID:** L05
- **Roadmap unit:** W004, Dired targets its backing buffer
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** Controller promotion with a GPT-5.5 `medium` read-only contract check
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `7bb5e981fc957f662b0e653eefc6fbedd3091b56`
- **Freshness basis:** `HEAD`, `main`, and `origin/main` resolved to the freshness SHA in a clean worktree. L05 remained reproducible in all three paths below.

#### Observable outcome

Dired save and force-save enter Dired mutation handling only when the workspace active buffer is the exact PID stored in Dired state. Closing Dired stops and retires that stored PID even when another buffer is active. Any deliberate or independent death of the stored PID clears Dired state and restores `:editor` only when the stale scope is `:dired`; unrelated buffer deaths and unrelated scopes remain unchanged.

#### Current producer-to-consumer failure paths

1. `MingaEditor.Commands.BufferManagement.execute/2` and its W002 `save_active_buffer/1` path check only `dired.active?` before routing save to `:dired_apply_changes`; `:force_save` has the same broad public dispatch. A tab or active-buffer switch therefore applies edits from the stored Dired PID instead of saving the current buffer unless every Dired-specific save clause requires exact active identity.
2. `MingaEditor.Commands.Dired.close_dired/1` reads the stored PID, deactivates Dired, then dispatches generic `:kill_buffer`. `MingaEditor.Commands.BufferManagement` resolves that command from the active tab and can retire a different PID.
3. Buffer monitor `:DOWN` reaches `MingaEditor.Handlers.BufferRegistry.retire_dead_buffer/2`, then `MingaEditor.State.remove_buffer/2`. The root transition retires buffer, parser, shell, monitor, Git, and agent-prompt references but never asks the Dired owner to forget an exact backing PID, leaving stale Dired state and scope.

#### Authoritative owners and locked shape

`MingaEditor.State.Dired` owns exact backing identity. Add `retire_buffer/2` with this contract:

```elixir
retire_buffer(%DiredState{buffer: pid} = dired, pid) :: DiredState.deactivate(dired)
retire_buffer(%DiredState{} = dired, other_pid) :: dired
```

`MingaEditor.Session.State` owns the aggregate Dired and keymap-scope invariant. Add `retire_dired_buffer/2`. When the PID matches, it installs the leaf transition and changes `:dired` to `:editor`; every other scope is preserved. A non-matching PID returns the workspace unchanged.

`MingaEditor.State.remove_buffer/2` remains the root exact-identity retirement transition and must call the session aggregate before activating the surviving buffer.
`MingaEditor.State.Buffers` owns active-buffer identity during membership changes. `remove/2` must preserve the exact surviving active PID and recompute its index when a different PID is removed; existing neighbor selection remains unchanged when the active PID itself is removed.

`MingaEditor.Commands.BufferManagement` owns save command dispatch. Its public Dired `:force_save` clause and private Dired `save_active_buffer/1` clause require one PID to match both `workspace.dired.buffer` and `workspace.buffers.active`; public `:save` reuses the generic `save_active_buffer/1` path. All mismatches fall through to the existing normal save or force-save clauses.

`MingaEditor.Commands.Dired` owns deliberate Dired close effects. For an exact stored PID it must synchronously stop that PID, tolerate an already-dead PID, then call the existing `MingaEditor.Handlers.BufferRegistry.retire_dead_buffer/2` workflow before returning. This removes the dead PID and its monitor before the immediate render, reuses parser, highlight, shell, persistence, and root cleanup, and prevents a later duplicate `:DOWN` through the existing `Process.demonitor(ref, [:flush])`.

#### Exact files and symbols

Production:

- `lib/minga_editor/commands/buffer_management.ex`: public Dired `:force_save` clause plus private Dired `save_active_buffer/1`; public `:save` reuses the generic private helper
- `lib/minga_editor/commands/dired.ex`: `close_dired/1` and one private exact-PID stop helper
- `lib/minga_editor/state/dired.ex`: `retire_buffer/2`
- `lib/minga_editor/session/state.ex`: `retire_dired_buffer/2`
- `lib/minga_editor/state.ex`: `remove_buffer/2`
- `lib/minga_editor/state/buffers.ex`: `remove/2` exact surviving-active preservation

Tests:

- `test/minga_editor/commands/dired_mutation_test.exs`
- `test/minga_editor/state/dired_test.exs`
- `test/minga_editor/state/buffers_test.exs`

Producers and consumers:

- Save producers: command registry, Dired keymap scope, ex `:write`, GUI action dispatch
- Close producers: Dired `q` and Escape bindings, command registry, `open_file/2`
- Death producer: Editor-owned buffer monitor in `MingaEditor`
- Consumers: Dired mutation confirmation, ordinary buffer save, Dired state, session keymap scope, buffer registry retirement workflow, immediate renderer state

#### Locked implementation steps

1. Add exact-identity `DiredState.retire_buffer/2`.
2. Add `SessionState.retire_dired_buffer/2` with exact-match scope normalization and no unrelated-scope write.
3. Insert that aggregate transition into `EditorState.remove_buffer/2` before surviving-buffer activation.
4. Update `Buffers.remove/2` to preserve the exact active PID when removing a different member and use existing neighbor selection when removing the active member.
5. Tighten the public Dired force-save clause and private Dired `save_active_buffer/1` clause with one repeated PID pattern and an `is_pid` guard. Let public `:save` fall through to the existing generic `save_active_buffer/1` call rather than retaining a redundant public Dired clause. Do not add a query helper.
6. Replace generic `:kill_buffer` dispatch in `close_dired/1` with exact stored-PID stop followed synchronously by `BufferRegistry.retire_dead_buffer/2`. Treat only `:noproc` as already dead; an unexpected stop exit must retain ownership and publish the failure.
7. Add the locked regression tests and run the focused command.

#### Required tests

`test/minga_editor/commands/dired_mutation_test.exs`:

- Matching active and stored Dired PID: `BufferManagement.execute(state, :save)` enters confirmation for the edited Dired listing.
- Mismatched active PID: `:save` writes the active file buffer and does not enter Dired confirmation or mutate the Dired backing file operations.
- Mismatched active PID: `:force_save` uses the existing active-buffer force-save path rather than Dired mutation handling.
- `:dired_close` with the stored Dired PID before the unrelated active PID in a four-buffer list sends `:DOWN` only for Dired, preserves the exact unrelated active PID and its corrected index in returned state, removes the stored PID, clears Dired, and restores `:editor`.
- `:dired_close` with an already-dead stored PID still returns cleaned state without raising.
- `:dired_close` preserves Dired and buffer ownership when the stop exits unexpectedly instead of retiring a potentially live process.

`test/minga_editor/state/dired_test.exs`:

- Exact backing retirement resets the Dired leaf.
- Unrelated PID retirement returns the Dired leaf unchanged.
- Session exact backing retirement changes stale `:dired` scope to `:editor`.
- Session exact backing retirement preserves a non-Dired scope.
- Root `remove_buffer/2` clears exact Dired ownership while preserving Dired for an unrelated retired PID.

`test/minga_editor/state/buffers_test.exs`:

- Removing a non-active PID before the active PID preserves the exact active PID and recomputes its shifted index.

Tests use exact PID identities, `start_supervised!/1`, `Process.monitor/1`, and `assert_receive {:DOWN, ...}` at the cheapest useful layer. They do not use sleeps, `Process.alive?/1` assertions, or `:sys.replace_state/2`.

#### Validation

- Focused: `mix test.debug test/minga_editor/commands/dired_mutation_test.exs test/minga_editor/state/dired_test.exs test/minga_editor/state/buffers_test.exs`
- Related state boundary: `mix test.debug test/minga_editor/state/root_purity_test.exs`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and retained constraints

- Do not change Dired operation diffing, confirmation, refresh, navigation, listing format, keybindings, or filesystem semantics.
- Do not add a Dired process, monitor, buffer wrapper, generic target resolver, generic retirement facade, protocol, dependency, configuration, compatibility path, or architecture exception.
- Do not change ordinary buffer kill behavior, W003 force-kill behavior, wait-request policy, root buffer inventory, tab ownership, or L03.
- Preserve one Editor mailbox, Editor-owned monitor correlation, synchronous safe returned state, surviving active-buffer identity, shell cleanup, parser and highlight cleanup, persistence, and exact-identity state ownership.
- `MingaEditor.State.Dired` remains the only writer of its struct. `MingaEditor.State.Buffers` owns membership and active identity. `MingaEditor.Session.State` coordinates Dired with keymap scope. `MingaEditor.State` coordinates root retirement. External stop and persistence work remain in the Dired and BufferRegistry workflows.

#### Dependencies and budget

- **Dependencies:** W001-W003 are VERIFIED. No overlapping Dired owner work is active.
- **Allowed concept:** One exact-identity Dired retirement transition across its existing leaf, session aggregate, and root lifecycle.
- **Maximum production delta:** +40 net lines across the six named production files.
- **Maximum test delta:** +150 net lines across the three named test files.
- **Forbidden concepts:** New process, monitor, generic abstraction, wrapper, protocol, registry, adapter, compatibility path, configuration, dependency, or broader buffer inventory.
- **Implementer questions:** None. Return `NEEDS_REPLAN` rather than alter the stop-and-retire sequence, owner boundaries, tests, scope policy, or budgets.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2984
- **Commit SHA:** `d391c76e7512ab033b5088803b8072cd84f9f5c9`
- **Merge SHA:** `cb519c481a1450b5b10b7c6b2b1c320339b8bfba`
- **Focused tests:** `mix test.debug test/minga_editor/commands/dired_mutation_test.exs test/minga_editor/state/dired_test.exs test/minga_editor/state/buffers_test.exs` passed (13); `mix test.debug test/minga_editor/state/root_purity_test.exs` passed (2)
- **Broad validation:** `make lint` passed (format, changed-file Credo, compile, incremental Dialyzer; two non-blocking boolean-case suggestions); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,853 tests, 0 failures, 1 skipped, 574 excluded)
- **Ponytail and Elixir verdict:** `LEAN`; no required findings after the formatting-driven shrink
- **Bug-hunt verdict:** `PASS` after targeted unexpected-stop recheck
- **Final reviewer verdict:** `PASS`, confidence 0.98, no findings
- **Production lines added/removed:** 72 added / 43 removed, net +29
- **Test lines added/removed:** 149 added / 0 removed, net +149
- **Concepts added/removed:** Added one exact-identity Dired retirement transition across existing Dired leaf, session aggregate, and root lifecycle; removed generic Dired close through active-buffer `:kill_buffer`; consolidated repeated notice-owner qualification through one alias
- **Findings resolved:** Focused validation covers L05 exact backing PID targeting for Dired save, force-save, live close, already-dead close, unexpected stop failure, buffer-death retirement, and exact surviving active PID preservation when a different earlier buffer is removed
- **Discoveries affecting later work:** Reviews found the private Dired save path, shifted-index active-buffer drift, and unexpected stop-exit retirement; all were corrected within W004 and do not change later work-unit contracts
- **Completion date:** 2026-07-18

### W005: Picker refresh rebuilds candidates

- **Status:** VERIFIED
- **Audit ID:** L10
- **Roadmap unit:** W005, Picker refresh rebuilds candidates
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** Controller promotion from current source with GPT-5.5 `medium`; no delegated planner
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `470e232435b172e3437baf72acbcf96c4f3d9aae`
- **Freshness basis:** `HEAD`, `main`, and `origin/main` resolved to the freshness SHA. L10 remains reproducible: `PickerUI.refresh_items/1` replaces only `items`, so `Picker.filter/2` scores the previous normalized candidates.

#### Observable outcome

Keep-open picker refresh atomically replaces source items and normalized scoring candidates, reapplies the current query to the new set, and clamps selection to the refreshed filtered count.

#### Authoritative owner and locked shape

`MingaEditor.UI.Picker` owns `items`, `candidates`, `query`, `filtered`, and `selected`. `Picker.replace_items/2` already rebuilds candidates, refilters with the current query, and clamps selection through `refilter/1`. `PickerUI.refresh_items/1` must call that owner transition once and remove its duplicate manual filtering and clamping.

#### Exact files, symbols, producers, and consumers

Production:

- `lib/minga_editor/picker_ui.ex`: `refresh_items/1`

Tests:

- `test/minga_editor/picker_ui_test.exs`: refresh orchestration regression

Producers:

- keep-open `select_single_item/4` after `Source.on_select/4`
- `MingaEditor.maybe_refresh_tool_picker/1`
- `MingaEditor.Handlers.FileEventHandler.maybe_refresh_file_picker/2`

Consumers are the picker renderer and subsequent selection/action dispatch, both of which must see items and scoring candidates from the same source refresh.

#### Locked implementation

1. Fetch fresh items through the existing source and context path.
2. Replace the item-only update, explicit `Picker.filter/2`, and duplicate selection clamp with `Picker.replace_items(picker, items)`.
3. Keep the existing `update_picker/2` modal transition.
4. Add one orchestration test whose old candidates all match the preserved query at selection index two while the refreshed source returns one new matching item. Assert the refreshed item and filtered IDs are new, the query is unchanged, and selection clamps to zero.

#### Validation

- Focused: `mix test.debug test/minga_editor/picker_ui_test.exs test/minga_editor/ui/picker_test.exs`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and budget

- Do not change async picker fetch, source callbacks, keep-open policy, file events, Tool Manager behavior, fuzzy scoring, query editing, modal ownership, or renderer contracts.
- Do not add a refresh protocol, cache owner, candidate abstraction, helper, process, dependency, or compatibility path.
- **Maximum production delta:** 0 net lines in the one production file.
- **Maximum test delta:** +30 net lines in the one test file.
- **Implementer questions:** None.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2987
- **Commit SHA:** `206a5cb8608f0c9f233bb34814f066d30aaf4a6e`
- **Merge SHA:** `d94edbffe1b15d10a0305ec7454e1fb28e3bd942`
- **Focused tests:** `mix format lib/minga_editor/picker_ui.ex test/minga_editor/picker_ui_test.exs` passed; `mix test.debug test/minga_editor/picker_ui_test.exs test/minga_editor/ui/picker_test.exs` passed, 76 tests, seed 161951
- **Broad validation:** `git diff --check` passed; `make lint` passed (Credo, compile, incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,865 tests, 0 failures, 1 skipped, 578 excluded)
- **Ponytail and Elixir verdict:** `LEAN`; no required findings. The one-call `Picker.replace_items/2` owner transition is the smallest natural Elixir shape, and the reused context-fed test source adds no new concept.
- **Bug-hunt verdict:** `PASS`, confidence 0.97; no correctness findings. The test fails on the old stale-candidate path and covers all three unchanged producers through the shared refresh entry point.
- **Final reviewer verdict:** `PASS`, confidence 0.99; staged W005 patch is merge-safe, within line budgets, limited to L10, and keeps all three producers on the unchanged refresh boundary
- **Production lines added/removed:** 1 added / 7 removed, net -6
- **Test lines added/removed:** 29 added / 0 removed, net +29
- **Concepts added/removed:** No concepts added; removed duplicate refresh-side manual filtering and selection clamp
- **Findings resolved:** L10 keep-open picker refresh now uses `Picker.replace_items/2` so items, candidates, filtered results, query preservation, and selection clamp stay in the picker owner transition
- **Discoveries affecting later work:** None
- **Completion date:** 2026-07-18

### W006: Diagnostics picker uses current context

- **Status:** VERIFIED
- **Audit ID:** L12
- **Roadmap unit:** W006, Diagnostics picker uses current context
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** Controller promotion from current source with GPT-5.5 `medium`; no delegated planner
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `a8b2db8b93162810801f20055126a6e666edbe30`
- **Freshness basis:** `HEAD`, `main`, and `origin/main` resolved to the freshness SHA. L12 remains reproducible: the diagnostics source matches full Editor state while `PickerUI.open/3` passes `MingaEditor.UI.Picker.Context`, so the fallback returns no items.

#### Observable outcome

Every registered diagnostics picker name opens the current buffer's diagnostics from `Picker.Context`; populated diagnostics retain severity, byte position, message, and source in the existing item shape, while a current buffer with no diagnostics preserves the existing no-op command behavior.

#### Authoritative owner and locked shape

`MingaEditor.UI.Picker.Context` owns the source-facing projection and exposes `%Context{buffers: %Buffers{active: pid}}`. `MingaEditor.UI.Picker.Sources.Diagnostics` owns conversion to `%Picker.Item{id: {line, byte_col}, label: "SEVERITY line:col  message (source)"}`. Only `candidates/1` changes to consume `Context`; `on_select/2` must continue to receive full Editor state and move the active buffer.

#### Exact files, symbols, producers, and consumers

Production:

- `lib/minga_editor/ui/picker/sources/diagnostics.ex`: `candidates/1`

Tests:

- `test/minga_editor/commands/diagnostics_picker_test.exs`: registered-command regression

Command producers:

- `MingaEditor.Commands.Diagnostics`: `:diagnostic_list`
- `MingaEditor.Commands.Diagnostics`: `:diagnostic_picker`
- `MingaEditor.Commands.UI`: `:diagnostics_list`

The picker modal and `on_select/2` consume the returned items. The three command names are preserved; alias consolidation remains separate Ponytail finding S02.

#### Locked implementation

1. Alias `MingaEditor.UI.Picker.Context`.
2. Change `candidates/1` to accept `%Context{buffers: %{active: buf}}` with the existing PID guard and retain the fallback.
3. Keep path lookup, URI conversion, diagnostics lookup, position encoding, item formatting, selection, and cancellation unchanged.
4. Add an async command-level test that executes all three registered command functions against one current file buffer and published diagnostic. Assert each picker contains exactly `%Item{id: {1, 2}, label: "W 2:3  unused variable (expert)"}`.
5. Add the empty-store edge case through one registered command and assert the command leaves state unchanged.

#### Validation

- Focused: `mix test.debug test/minga_editor/commands/diagnostics_picker_test.exs`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and budget

- Do not consolidate command aliases, alter command registration, add notices, change diagnostics storage, change position encoding, add context adapters, change selection callbacks, or modify picker rendering.
- Do not add a process, protocol, behaviour, dependency, wrapper, projection, cache, or compatibility path.
- **Maximum production delta:** +2 net lines in the one production file.
- **Maximum test delta:** +80 net lines in the one new test file.
- **Implementer questions:** None.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2989
- **Commit SHA:** `8b10467ee49d335b4967ea9383bd2a38d7a34bf6`
- **Merge SHA:** `385d5b460f3b790bf2113e52f6c1974a5a234a4e`
- **Focused tests:** `mix format lib/minga_editor/ui/picker/sources/diagnostics.ex test/minga_editor/commands/diagnostics_picker_test.exs` passed; `mix test.debug test/minga_editor/commands/diagnostics_picker_test.exs` passed, 2 tests, seed 316808
- **Broad validation:** `git diff --check` passed; `make lint` passed (Credo, compile, incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,867 tests, 0 failures, 1 skipped, 578 excluded)
- **Ponytail and Elixir verdict:** `LEAN`; no required findings. The direct `%Picker.Context{}` boundary is the smallest natural Elixir cutover, preserves full state for selection, and adds no adapter or parallel state shape.
- **Bug-hunt verdict:** `PASS`; no correctness findings. All three registered names exercise the real context producer, the populated regression fails on `origin/main`, URI cleanup is isolated, and empty no-op behavior is preserved.
- **Final reviewer verdict:** `PASS`, confidence 0.99 after targeted recheck; the only blocker was stale `BLOCKED` ledger status left by the resolved inline replan, corrected to `ACTIVE`
- **Production lines added/removed:** 3 added / 2 removed, net +1
- **Test lines added/removed:** 67 added / 0 removed, net +67
- **Concepts added/removed:** No concepts added; diagnostics source now consumes the existing `Picker.Context` projection directly
- **Findings resolved:** Populated diagnostics picker commands now read the active buffer from `Picker.Context`; an empty diagnostics store retains the existing no-op command behavior.
- **Discoveries affecting later work:** The worker correctly returned `NEEDS_REPLAN` because the initial empty-store assertion contradicted `PickerUI.open_sync/4`. The controller narrowed that edge to preserve the existing no-op instead of widening picker ownership or W006 scope.
- **Completion date:** 2026-07-18

## Initial tranche completion

- **Status:** VERIFIED
- **Completion date:** 2026-07-18
- **Units verified:** W001 through W006
- **Audit findings resolved:** L01, L02, L04, L05, L10, and L12
- **Cumulative production delta:** 238 lines added / 172 removed, net +66
- **Cumulative test delta:** 561 lines added / 9 removed, net +552
- **Review closure:** Every unit received a final `PASS`; every required review finding was corrected before merge; no accepted review finding remains open.
- **Closure reviewer verdict:** `PASS`, confidence 0.99; W006 merge evidence, cumulative arithmetic, review closure, simplicity closure, and the zero-trace Dired follow-on are truthful and internally consistent.
- **Program status:** ACTIVE; this evidence closes only W001 through W006. Eighty-five accepted findings and twenty-eight routed decisions remained when this correction was recorded.
- **Simplicity closure:** No unit added a process, dependency, protocol, behaviour, adapter, wrapper, cache, compatibility path, or parallel data shape. The only new semantic contracts are the private save outcome, explicit ordinary/force destruction intent, and exact-identity Dired retirement transition required by the accepted behavior. W001, W005, and W006 reused existing owners and removed or avoided duplicate transition logic.

## Extended execution

### W007: Signature Help recognizes Control modifiers

- **Status:** VERIFIED
- **Audit ID:** L20
- **Roadmap unit:** W007, Signature Help recognizes Control modifiers
- **Ponytail verdict:** `ACCEPT/direct`
- **Freshness profile:** `editor-lifecycle-freshness`, `openai-codex/gpt-5.5`, `medium`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `b4c7f30b3b9cc5d3c473c378a8e26c67ac016914`
- **Freshness basis:** `HEAD`, `main`, and `origin/main` changed only roadmap, profile, and route-decision documentation after the medium freshness review at `6e175b87764145577999a1c04a532960cb89222f`. Current source still hardcodes the Alt modifier bit in Signature Help.
- **Implementer questions:** None.

#### Observable outcome

Ctrl-J and Ctrl-K cycle Signature Help overloads when frontends send the canonical Control bit `0x02`. Alt-J remains ordinary input and passes through unchanged.

#### Authoritative owner and locked shape

`MingaEditor.Input` owns modifier constants through `mod_ctrl/0` and `mod_alt/0`. `MingaEditor.Input.SignatureHelp.handle_key/3` consumes those constants. Replace only the private hardcoded `@ctrl 4` value with `MingaEditor.Input.mod_ctrl/0`; no input or protocol contract changes.

#### Exact files, symbols, producers, and consumers

- Production: `lib/minga_editor/input/signature_help.ex`, private `@ctrl` used by `handle_key/3`
- Tests: `test/minga_editor/input/signature_help_test.exs`, Ctrl-J/Ctrl-K cycling and Alt-J collision regression
- Producers: macOS and Go frontends encode Control as `0x02`; `MingaEditor.Frontend.Protocol` decodes the shared modifier mask
- Consumer: `MingaEditor.Input.SignatureHelp`

#### Locked implementation

1. Bind the Signature Help `@ctrl` attribute to `MingaEditor.Input.mod_ctrl/0`.
2. Bind the test modifier to the same canonical helper.
3. Preserve the existing Ctrl-J and Ctrl-K cycling assertions.
4. Add a negative Alt-J assertion that returns `{:passthrough, state}` unchanged.

#### Validation

- Focused: `mix test.debug test/minga_editor/input/signature_help_test.exs`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and budget

- Do not change modifier encoding, frontend protocol values, Signature Help state, cycling behavior, Escape dismissal, or ordinary passthrough.
- Do not add a process, module, dependency, abstraction, compatibility path, or fallback.
- **Maximum production delta:** 0 net lines.
- **Maximum test delta:** +10 net lines.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2993
- **Commit SHA:** `7bbd2730b6631cb2ce84be1da6903d9c0603fd66`
- **Merge SHA:** `fb7aa9d0572bab31047cca77d444acc01782d6c0`
- **Focused tests:** `mix test.debug test/minga_editor/input/signature_help_test.exs` passed, 7 tests
- **Broad validation:** `git diff --check` passed; `make lint` passed (Credo, compile, incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,868 tests, 0 failures, 1 skipped, 578 excluded)
- **Ponytail and Elixir verdict:** `LEAN`; the canonical modifier helper is the smallest natural Elixir cutover, removes one duplicate constant, and introduces no concept.
- **Bug-hunt verdict:** `PASS`; Ctrl-J and Ctrl-K use the canonical Control bit, Alt-J proves the former collision passes through, and Escape plus ordinary passthrough remain covered.
- **Final reviewer verdict:** `PASS`, confidence 0.99; canonical modifier ownership, Ctrl-J/Ctrl-K cycling, Alt-J passthrough, tests, evidence, and budgets are merge-safe.
- **Production lines added/removed:** 1 added / 1 removed, net 0
- **Test lines added/removed:** 8 added / 1 removed, net +7
- **Concepts added/removed:** No concepts added; one incorrect private modifier constant was replaced by the existing input owner.
- **Findings resolved:** Signature Help now recognizes frontend Control modifiers without treating Alt as Control.
- **Discoveries affecting later work:** None.
- **Completion date:** 2026-07-18

### W008: Remove unused picker sources

- **Status:** VERIFIED
- **Audit ID:** D19
- **Roadmap unit:** W008, Remove unused picker sources
- **Ponytail verdict:** `ACCEPT/delete`
- **Freshness profile:** `editor-lifecycle-freshness`, `openai-codex/gpt-5.5`, `medium`, read-only
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `fb7aa9d0572bab31047cca77d444acc01782d6c0`
- **Freshness basis:** Freshly rebased `HEAD`, `main`, and `origin/main` include W007. Current source has no production, test, extension, or documentation reference to either unused picker source outside the two modules and the obsolete Tab Source test.
- **Implementer questions:** None.

#### Observable outcome

Delete the unused Session History and Tab picker source implementations, plus the obsolete test that instantiates Tab Source directly. Registered picker sources, picker orchestration, extension source support, and all user-visible picker behavior remain unchanged.

#### Authoritative owner and locked shape

`MingaEditor.UI.PickerUI` owns picker orchestration and opens explicitly selected source modules. `MingaEditor.UI.Picker.Source` owns the source behaviour and extension contract. Neither owner registers, references, or selects `SessionHistorySource` or `TabSource`. This work removes only those two orphan implementations and their direct unit test; it adds no replacement.

#### Exact files, symbols, producers, and consumers

- Delete `lib/minga_editor/ui/picker/session_history_source.ex`, module `MingaEditor.UI.Picker.SessionHistorySource`
- Delete `lib/minga_editor/ui/picker/tab_source.ex`, module `MingaEditor.UI.Picker.TabSource`
- Delete `test/minga_editor/ui/picker/tab_source_test.exs`, module `MingaEditor.UI.Picker.TabSourceTest`
- Preserve `lib/minga_editor/ui/picker/source.ex`, including the source behaviour and extension contract
- Preserve `lib/minga_editor/ui/picker_ui.ex`, including explicit source selection and picker lifecycle
- Preserve live registered sources under `lib/minga_editor/ui/picker/sources/`

#### Locked implementation

1. Reconfirm no repository caller, registry entry, extension reference, or documentation reference exists for either obsolete module.
2. Delete `session_history_source.ex`.
3. Delete `tab_source.ex`.
4. Delete `tab_source_test.exs`, which tests only the removed module.
5. Add no fallback, alias, compatibility module, registry entry, migration, or replacement test.

#### Validation

- Source reference check: no `SessionHistorySource`, `session_history_source`, `TabSource`, or `tab_source` reference remains outside immutable audit and roadmap history.
- Focused: `mix compile --warnings-as-errors`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and budget

- Do not change `PickerUI`, `Picker.Source`, registered source modules, picker state, keymaps, commands, extensions, session history, tabs, or tab switching behavior.
- Do not add a process, module, dependency, abstraction, behaviour, protocol, cache, compatibility path, or replacement.
- **Expected production delta:** 146 lines removed and 0 added.
- **Expected test delta:** 103 lines removed and 0 added.
- **Maximum added production lines:** 0.
- **Maximum added test lines:** 0.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2994
- **Commit SHA:** `a82bf2ccc4d829ffcfe422373c56e7084c22d038`
- **Merge SHA:** `9d5f97315e7b37e409961c27274b1fcb447d88c0`
- **Focused tests:** `mix compile --warnings-as-errors` passed; post-deletion source reference search found only roadmap evidence.
- **Broad validation:** `git diff --check` passed; `make lint` passed (Credo, compile, incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,862 tests, 0 failures, 1 skipped, 578 excluded).
- **Ponytail and Elixir verdict:** `LEAN`; deleting both orphan implementations and the direct test removes concepts without changing the live source behaviour or picker orchestration.
- **Bug-hunt verdict:** `PASS`; no production, test, extension, registry, command, documentation, dynamic lookup, or compatibility consumer remains.
- **Final reviewer verdict:** `PASS`; the staged diff deletes only the two orphan picker sources and their direct test, preserves live picker contracts, matches line budgets, and carries complete validation evidence.
- **Production lines added/removed:** 0 added / 146 removed, net -146
- **Test lines added/removed:** 0 added / 103 removed, net -103
- **Concepts added/removed:** No concepts added; two unused picker source implementations removed.
- **Findings resolved:** Session History Source and Tab Source no longer remain as unreachable picker implementations.
- **Discoveries affecting later work:** None.
- **Completion date:** 2026-07-18

### W009: Remove unused renderer capability helpers

- **Status:** VERIFIED
- **Audit ID:** D10
- **Roadmap unit:** W009, Remove unused renderer capability helpers
- **Ponytail verdict:** `ACCEPT/delete`
- **Freshness profile:** Targeted controller check against current main; no repeated broad freshness pass
- **Planning profile:** Direct controller promotion; no high-planner escalation because the deletion boundary is fully reproducible and has no unresolved owner, caller, test, or compatibility question
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `9d5f97315e7b37e409961c27274b1fcb447d88c0`
- **Freshness basis:** Freshly rebased `HEAD` and `origin/main` include W008. Current source has no live caller, dynamic lookup, extension reference, configuration reference, or public compatibility consumer for `MingaEditor.Renderer.Caps` or any of its functions.
- **Implementer questions:** None.

#### Observable outcome

Delete the unused renderer capability helper module and its isolated direct test. Remove the stale renderer moduledoc entry. Live renderer capability handling and output remain unchanged.

#### Authoritative owner and locked shape

Live renderer behavior is owned by the renderer pipeline, frontend capabilities, and frontend adapters. `MingaEditor.Renderer.Caps` is not consumed by those owners. Remove the orphan module without moving its functions or adding a replacement API.

#### Exact files, symbols, producers, and consumers

- Delete `lib/minga_editor/renderer/caps.ex`, module `MingaEditor.Renderer.Caps`
- Delete `test/minga_editor/renderer/caps_test.exs`, module `MingaEditor.Renderer.CapsTest`
- Remove the stale `Renderer.Caps` bullet from `lib/minga_editor/renderer.ex`
- Removed public functions: `render_overlays?/1`, `adapt_color/2`, and `send_images?/1`
- Removed private helper: `rgb_to_256/1`
- Preserve all live renderer modules, frontend capability structures, adapters, protocols, and tests

#### Locked implementation

1. Confirm no current repository reference selects or calls the module or any removed function.
2. Delete `renderer/caps.ex`.
3. Delete `renderer/caps_test.exs`, which tests only the removed module.
4. Remove the stale moduledoc bullet.
5. Add no replacement, alias, delegation, fallback, compatibility module, or migration.

#### Validation

- Source reference check: no `MingaEditor.Renderer.Caps`, `Renderer.Caps`, `render_overlays?`, `adapt_color`, `send_images?`, or `rgb_to_256` reference remains outside immutable audit and roadmap history.
- Focused: `mix compile --warnings-as-errors`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and budget

- Do not change renderer behavior, frontend capabilities, color conversion, image rendering, overlays, adapters, protocols, or registered render paths.
- Do not add a process, module, dependency, abstraction, behaviour, protocol, cache, compatibility path, or replacement.
- **Expected production delta:** 0 added / 78 removed.
- **Expected test delta:** 0 added / 52 removed.
- **Maximum added production lines:** 0.
- **Maximum added test lines:** 0.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2995
- **Commit SHA:** `ed77d50b5c5c6d2650b8d909b6903ab2c5f14fb2`
- **Merge SHA:** `db7468ca6cac6da438e05326430070bba155a673`
- **Focused tests:** `mix compile --warnings-as-errors` passed; post-deletion source reference search found no live matches.
- **Broad validation:** `git diff --check` passed; `make lint` passed (Credo, compile, incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,853 tests, 0 failures, 1 skipped, 578 excluded).
- **Ponytail and Elixir verdict:** `LEAN`; the exact three-file deletion removes an orphan module and its isolated tests without introducing or relocating a concept.
- **Bug-hunt verdict:** `PASS`; no production, configuration, documentation, extension, dynamic lookup, or compatibility consumer remains.
- **Final reviewer verdict:** `PASS`; the staged diff matches the locked three-file deletion, line budgets, validation evidence, and live-renderer preservation boundary.
- **Production lines added/removed:** 0 added / 78 removed, net -78
- **Test lines added/removed:** 0 added / 52 removed, net -52
- **Concepts added/removed:** No concepts added; one unused renderer capability helper module removed.
- **Findings resolved:** The orphan renderer capability helper API and its isolated test surface are removed.
- **Discoveries affecting later work:** None.
- **Completion date:** 2026-07-18

### W010: Remove duplicate Diagnostics LSP Info branch

- **Status:** VERIFIED
- **Audit ID:** D29
- **Roadmap unit:** W010, Remove duplicate Diagnostics LSP Info branch
- **Ponytail verdict:** `ACCEPT/delete`
- **Freshness profile:** Targeted controller check against current main; no repeated broad freshness pass
- **Planning profile:** Direct controller promotion; no high-planner escalation because command registration and the surviving owner are explicit
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `db7468ca6cac6da438e05326430070bba155a673`
- **Freshness basis:** Freshly rebased `HEAD` and `origin/main` include W009. `MingaEditor.Commands.Diagnostics` registers only diagnostic commands, has no live `:lsp_info` caller, and still carries an unreachable branch. `MingaEditor.Commands.Lsp` remains registered and owns the live `:lsp_info` command and Ex-command path.
- **Implementer questions:** None.

#### Observable outcome

Remove the unreachable Diagnostics-owned `:lsp_info` branch and its unused aliases. The registered LSP Info command continues to work through `MingaEditor.Commands.Lsp`; diagnostic picker and navigation behavior remain unchanged.

#### Authoritative owner and locked shape

`MingaEditor.Commands.Lsp` owns `:lsp_info`, including registration and execution. `MingaEditor.Commands.Diagnostics` owns only diagnostic navigation and picker commands. Narrow the Diagnostics `execute/2` contract to its registered atoms and remove the duplicate implementation rather than sharing or moving code.

#### Exact files, symbols, producers, and consumers

- Production: `lib/minga_editor/commands/diagnostics.ex`
- Remove `execute(state, :lsp_info)`
- Remove unused aliases `Minga.LSP.Client` and `Minga.LSP.Supervisor`
- Narrow the public `execute/2` spec to `:diagnostic_list | :diagnostic_picker | :next_diagnostic | :prev_diagnostic`
- Preserve `MingaEditor.Commands.Lsp.__commands__/0` and `execute/2`
- Preserve Registry membership, Ex-command routing, keybindings, diagnostic picker, and next/previous navigation

#### Locked implementation

1. Confirm Diagnostics does not register or receive `:lsp_info`.
2. Confirm `MingaEditor.Commands.Lsp` remains the registered live owner.
3. Delete the duplicate Diagnostics branch and now-unused aliases.
4. Narrow the Diagnostics `execute/2` spec to registered diagnostics commands.
5. Change no command names, registration, dispatch, picker behavior, navigation, or LSP status output.

#### Validation

- Focused: `mix test.debug test/minga_editor/commands/diagnostics_picker_test.exs test/minga_editor/commands/lsp_test.exs`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and budget

- Do not consolidate command modules, alter aliases exposed to users, change status formatting, modify LSP clients or supervision, or change diagnostics storage and navigation.
- Do not add a process, module, dependency, abstraction, behaviour, protocol, cache, compatibility path, or replacement.
- **Expected production delta:** 2 added / 28 removed, net -26.
- **Expected test delta:** 0.
- **Maximum added production lines:** 2.
- **Maximum added test lines:** 0.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2996
- **Commit SHA:** `8a050efa3fabf0dfce0a02e1b8de19a54a7bceae`
- **Merge SHA:** `38451d7cf696987d86a5d100ad20c0e308693f7e`
- **Focused tests:** `mix test.debug test/minga_editor/commands/diagnostics_picker_test.exs test/minga_editor/commands/lsp_test.exs` passed, 9 tests.
- **Broad validation:** `git diff --check` passed; `make lint` passed (Credo, compile, incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,853 tests, 0 failures, 1 skipped, 578 excluded).
- **Ponytail and Elixir verdict:** `LEAN`; the one-file cut removes a duplicate unreachable branch while leaving the explicit registered owner intact.
- **Bug-hunt verdict:** `PASS`; no live Diagnostics caller reaches `:lsp_info`, and all registered LSP Info paths continue through `MingaEditor.Commands.Lsp`.
- **Final reviewer verdict:** `PASS`; the staged one-file production cut preserves registered diagnostics and LSP command ownership, matches the locked budget, and carries final-base validation evidence.
- **Production lines added/removed:** 2 added / 28 removed, net -26
- **Test lines added/removed:** 0 added / 0 removed, net 0
- **Concepts added/removed:** No concepts added; one duplicate command implementation removed.
- **Findings resolved:** Diagnostics no longer carries an unreachable alternate LSP Info implementation.
- **Discoveries affecting later work:** None.
- **Completion date:** 2026-07-18

### W011: Remove unreachable Tool Manager footer placement

- **Status:** VERIFIED
- **Audit ID:** D36
- **Roadmap unit:** W011, Remove unreachable Tool Manager footer placement
- **Ponytail verdict:** `ACCEPT/delete`
- **Freshness profile:** `editor-lifecycle-freshness`, `openai-codex/gpt-5.5`, `medium`, read-only
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `38451d7cf696987d86a5d100ad20c0e308693f7e`
- **Freshness basis:** Freshly rebased `HEAD` and `origin/main` include W010. The footer placement list still contains Tool Manager behind a private predicate that always returns false. SurfaceRegistry identity, numeric ID 21, GUI action handling, frontend decoder state, service ownership, and picker behavior remain live and must be preserved.
- **Implementer questions:** None.

#### Observable outcome

Remove only the unreachable Tool Manager footer-overlay producer. Footer placement APIs report the seven active producers and never return a Tool Manager rect, while Tool Manager protocol identity and live frontend/service/picker behavior remain unchanged.

#### Authoritative owner and locked shape

`MingaEditor.Layout.FooterOverlays` owns footer placement production. `MingaEditor.Layout.SurfaceRegistry` separately owns stable surface identity, numeric protocol ID, z order, and hit kind. Delete the dormant producer from the former without changing the latter.

#### Exact files, symbols, producers, and consumers

- `lib/minga_editor/layout/footer_overlays.ex`: remove the `:tool_manager` visibility entry and private `tool_manager_visible?/1`; document seven active producers
- `lib/minga_editor/focus_tree.ex`: update exact active footer-overlay count wording
- `lib/minga_editor/layout/overlay_band.ex`: remove Tool Manager from the active footer-band surface list and retain the seven real surfaces
- `test/minga_editor/layout/footer_band_overlays_test.exs`: assert Tool Manager retains registry identity and ID 21 but has no placement or rect
- Preserve `MingaEditor.Layout.SurfaceRegistry.surface_id/1`, `surface_id_u16/1`, z/hit mappings, protocol encoders/decoders, Tool Manager service, commands, picker sources, and native frontend state

#### Locked implementation

1. Delete `{:tool_manager, tool_manager_visible?(state), :max}` from `FooterOverlays.visible/1`.
2. Delete the private hardcoded-false predicate.
3. Update active-producer documentation from eight to seven and remove Tool Manager from the list.
4. Add a focused regression asserting `surface_id(:tool_manager) == :tool_manager`, `surface_id_u16(:tool_manager) == 21`, no placement ID equals `:tool_manager`, and `rect_for(state, :tool_manager) == nil`.
5. Change no registry, protocol, frontend, service, command, picker, or Tool Manager state code.

#### Validation

- Focused: `mix test.debug test/minga_editor/layout/footer_band_overlays_test.exs`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and budget

- Do not delete or redesign Tool Manager, reclaim ID 21, alter SurfaceRegistry, change footer geometry, or modify any live producer.
- Do not add a process, module, dependency, abstraction, behaviour, protocol, cache, compatibility path, or replacement.
- **Expected production delta:** net non-positive.
- **Expected test delta:** at most +12 net lines.
- **Maximum production-line increase:** 0 net.
- **Maximum test-line increase:** +12 net.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2997
- **Commit SHA:** `7dcd23c20ffd9368e341ce64fa435ea9391cea23`
- **Merge SHA:** `943382f155a13abebec53951a30e5b4c0d1ce9df`
- **Focused tests:** `mix test.debug test/minga_editor/layout/footer_band_overlays_test.exs` passed, 18 tests.
- **Broad validation:** `git diff --check` passed; `make lint` passed (Credo, compile, incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 2:2' mix test.llm` passed (58 doctests, 98 properties, 9,854 tests, 0 failures, 1 skipped, 578 excluded).
- **Ponytail and Elixir verdict:** `LEAN` after one targeted correction; stale eight-surface wording was corrected to the same seven active producers implemented by `FooterOverlays`.
- **Bug-hunt verdict:** `PASS`; Tool Manager registry ID 21, z/hit mapping, GUI actions, frontend decoder state, service, and picker behavior remain live and untouched.
- **Final reviewer verdict:** `PASS`; the staged diff removes only the false placement producer, preserves Tool Manager compatibility boundaries and all live overlays, matches budgets, and carries final-base validation.
- **Production lines added/removed:** 26 added / 36 removed, net -10
- **Test lines added/removed:** 12 added / 2 removed, net +10
- **Concepts added/removed:** No concepts added; one permanently false placement branch removed.
- **Findings resolved:** Tool Manager no longer appears as an unreachable footer-overlay producer.
- **Discoveries affecting later work:** SurfaceRegistry identity is a protocol compatibility boundary independent from footer placement production.
- **Completion date:** 2026-07-18

### W012: Route picker prefix switching through async lifecycle

- **Status:** VERIFIED
- **Audit ID:** L11
- **Roadmap unit:** W012, Route picker prefix switching through async lifecycle
- **Ponytail verdict:** `ACCEPT/direct`
- **Freshness profile:** direct just-in-time source check against current main
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `74f0bf29f1212b2036ceff3ad7a6323d81dcef6b`
- **Freshness basis:** Current `HEAD` and `origin/main` include W011. Prefix switching still called source callbacks synchronously, while initial async picker opening already owned loading state, fetch revision, scheduler admission, latest-wins replacement, cancellation, errors, and stale-result rejection.
- **Implementer questions:** None.

#### Observable outcome

Typing `#` at the start of File or Recent switches to Project Search without running search on the Editor input loop. The picker enters loading state with a fresh revision and scheduler-owned fetch. Backspacing through `#` cancels that resource, restores the original source and picker-open ownership fields, and rejects delayed Project Search results as stale. Synchronous `>` and `@` switching remains immediate.

#### Authoritative owner and locked shape

`MingaEditor.PickerUI` owns source switching and orchestrates the existing `PickerState`, `FetchEffect`, and `EffectScheduler` lifecycle. Async prefix targets must use `open_loading/3`, `FetchEffect.request/4`, and `schedule_fetch/4`; sync targets continue to rebuild candidates directly. Source switches preserve the picker-open `restore`, `restore_theme`, and `context` fields. Returning to a sync source clears the former async fetch revision and loading status.

#### Exact files, symbols, producers, and consumers

- `lib/minga_editor/picker_ui.ex`: `switch_to_source/3`, `switch_back_to_original/1`, local source-switch helpers, `open_loading/3`, `schedule_fetch/4`, `cancel_current_fetch/1`, and `apply_fetch_result/4`
- `test/minga_editor/picker_ui_test.exs`: prefix switching, native full-query edits, loading/revision state, restoration, cancellation, and stale-result rejection
- Existing collaborators remain unchanged: `MingaEditor.State.Picker`, `MingaEditor.UI.Picker.FetchEffect`, `MingaEditor.EffectScheduler`, `MingaEditor.UI.Picker.Source`, and `ProjectSearchSource`

#### Locked implementation

1. Derive the target callback source and select async or sync handling in one local switch path.
2. For async targets, cancel the current resource through `open_loading/3`, retain picker-open ownership fields, mint a revision, build the existing `FetchEffect`, and submit it through `schedule_fetch/4`.
3. For sync targets, cancel any current fetch, rebuild candidates immediately, update source/layout/prefix fields, and clear stale async loading/revision state.
4. Preserve `original_source` while switched and clear it only when returning.
5. Keep native full-query edit acknowledgement and post-prefix query installation unchanged.
6. Add regressions for `#` loading, full `#needle` query handling, restore-index preservation, backspace cancellation, and delayed-result rejection. Preserve existing `>` coverage.

#### Validation

- Focused: `mix test.debug test/minga_editor/picker_ui_test.exs test/minga_editor/ui/picker/fetch_effect_test.exs test/minga_editor/commands/search_async_test.exs`
- Broad: `make lint`
- Full non-heavy: `ERL_FLAGS='+S 2:2' mix test.llm`

#### Non-goals and budget

- Do not remove prefix switching or change prefix mappings.
- Do not add a process, scheduler, fetch abstraction, parallel picker state, compatibility path, retry policy, or new protocol.
- Do not change project-search semantics, filtering, rendering, source callbacks, Editor scheduling, or extension behavior.
- **Maximum production additions:** 80 lines.
- **Maximum test additions:** 120 lines.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/2998
- **Commit SHA:** `b3d700b971ced9ed9d8b421984e415132235fe6c`
- **Merge SHA:** `422ed731c8d4ae984bf78181ec392ed9ca233320`
- **Focused tests:** 40 passed across `picker_ui_test.exs`, `fetch_effect_test.exs`, and `search_async_test.exs`.
- **Broad validation:** `git diff --check` passed; `make lint` passed (Credo, compile, incremental Dialyzer: 0 errors); `ERL_FLAGS='+S 2:2' mix test.llm` passed on the final base (58 doctests, 98 properties, 9,891 tests, 0 failures, 1 skipped, 578 excluded).
- **Ponytail and Elixir verdict:** `LEAN` after a targeted correction; source switching uses local helpers and existing lifecycle primitives, preserves picker-open ownership, clears stale sync-return fetch state, and stays within 76 production additions.
- **Bug-hunt verdict:** Initial review found a lost live-preview restore index; the correction preserves `restore`, `restore_theme`, and `context`, with a targeted recheck confirming callback identity, query correlation, cancellation key, and stale-result guards.
- **Final reviewer verdict:** `PASS`; the staged three-file diff routes `#` through existing async ownership, preserves synchronous prefixes and picker-open state, matches budgets, and carries behavior-level regressions plus final-base validation.
- **Production lines added/removed:** 76 added / 56 removed, net +20
- **Test lines added/removed:** 64 added / 1 removed, net +63
- **Concepts added/removed:** No concepts added or removed; prefix switching now reuses the existing async lifecycle.
- **Findings resolved:** Project Search prefix switching no longer executes synchronous search on the Editor input loop or bypasses async lifecycle ownership.
- **Discoveries affecting later work:** Source switching must preserve picker-open restoration and context independently from per-source query and fetch state. Post-merge Elixir review found that rebuilding through `open_loading/3` and repairing five fields left the transition represented by positional arguments and two independent sentinel fields.
- **Completion date:** 2026-07-18

#### Post-merge ownership refinement

- **Status:** VERIFIED
- **Reason:** User review and a focused `elixir-architect` audit found that `switch_async_source/6` reopened a fresh picker and repaired session-owned fields instead of expressing one owner transition.
- **Owned shape:** `MingaEditor.State.Picker` replaces `original_source` plus `mode_prefix` with `source_switch: :original | {:switched, original_source, prefix}` and owns retargeting through `retarget/4`. `PickerUI` retains callback, cancellation, scheduler, and candidate orchestration.
- **Deletion outcome:** Async and sync switching update the existing picker state through the same transition. The async reopen-and-repair block, six-argument helper, duplicate picker/query arguments, foreign picker-state writes, and invalid sentinel combinations are removed without a new process, protocol, scheduler, or wrapper module.
- **Preserve:** Prefix mappings, synchronous `>` and `@`, asynchronous `#`, query correlation, fetch revisions, scheduler cancellation, stale-result rejection, picker restoration, context, layout, and semantic mode-prefix rendering.
- **Focused tests:** 55 passed across `state/picker_test.exs`, `picker_ui_test.exs`, `picker_builder_test.exs`, `fetch_effect_test.exs`, and `search_async_test.exs`.
- **Broad validation:** `git diff --check`, `make lint`, and `mix test.llm --max-cases 4` passed on current main; full non-heavy result: 58 doctests, 98 properties, 9,906 tests, 0 failures, 1 skipped, 578 excluded.
- **Ponytail verdict:** `LEAN`; after rebasing removed an apparent unrelated diff and `Context.from_editor_state(loading_state)` made the retargeted state the single context owner, the targeted recheck returned `Lean already. Ship.`
- **Production lines added/removed:** 147 added / 118 removed, net +29. Production additions remain below the 200-line slice ceiling.
- **Test lines added/removed:** 88 added / 17 removed, net +71.
- **Concepts added/removed:** One tagged `source_switch` field replaces two nullable/sentinel fields and removes invalid combinations; no new process, protocol, scheduler, or wrapper module.
- **Final reviewer verdict:** `PASS`; the owner transition preserves restoration, context, layout, native correlation, fetch state, prefix behavior, latest-wins rejection, and semantic projection without new architecture or exceeding the production budget.
- **PR URL:** https://github.com/jsmestad/minga/pull/3005
- **Commit SHA:** `a2f432d40`
- **Merge SHA:** `5c965962f31aa89f48b56f477c6d3373f2bb15a9`
- **Completion date:** 2026-07-18

### W013: Clear disabled prettify symbols safely

- **Status:** VERIFIED
- **Audit ID:** L13
- **Roadmap unit:** W013, Clear disabled prettify symbols safely
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `57a37139155812ca0f3e002916b948f17803ee47`
- **Freshness basis:** Current `HEAD` and `origin/main` contain the verified W012 refinement. Disabled scheduling still skipped cleanup, and the effect worker still mutated the Buffer before scheduler claim.

#### Observable outcome

When prettify symbols are disabled, scheduling for a buffer first cancels work owned by `{:prettify_symbols, buffer}`, then synchronously removes only that buffer's `:prettify_symbols` conceal group. Repeated cleanup is idempotent, preserves other conceal groups, and does not increment the decoration version when the target group is already absent. Workers return prepared data; only the Editor's scheduler-claimed completed outcome may mutate the Buffer.

#### Owners and failure path

- `MingaEditor.UI.PrettifySymbolsEffect` owns domain scheduling, disabled cleanup, and domain outcome application.
- `MingaEditor.EffectScheduler` owns admission, cancellation, candidate claim, and worker lifecycle.
- `MingaEditor.UI.PrettifySymbols` owns conceal preparation and atomic update application.
- `Minga.Buffer.Process` owns Buffer decoration mutation; `Minga.Core.Decorations.remove_conceal_group/2` owns idempotent group removal.
- Before this unit, `PrettifySymbolsEffect.schedule/2` returned unchanged state when disabled, leaving installed conceals behind. `run/1` called the mutating `PrettifySymbols.apply/3`, so canceled or stale work could race cleanup.

#### Locked implementation

1. Keep scheduler resource identity `{:prettify_symbols, buffer}` and the existing latest-wins policy.
2. Preserve the enabled path: snapshot highlight and filetype, require usable spans, and schedule through `EffectScheduler`.
3. On the disabled path, call `EffectScheduler.cancel_resource/2` before `PrettifySymbols.clear/1`; treat scheduler unavailability as non-fatal.
4. Split preparation from mutation: `prepare/3` returns `:clear | {:replace, conceals}`, while `apply_update/2` applies that update atomically.
5. Make `run/1` return prepared data. Apply completed data only after the Editor claims the scheduler outcome.
6. Route atomic group removal through `Minga.Buffer.remove_conceal_group/2` and `Minga.Buffer.Process`.
7. Catch only expected stale/dead Buffer exits around cleanup and completed application.

#### Required tests

- `test/minga_editor/ui/prettify_symbols_effect_test.exs`: request identity and latest-wins policy; worker non-mutation; claimed outcome mutation; disabled cancellation before cleanup; group isolation; version idempotence; stale Buffer exit; failed, stale, and canceled outcome non-mutation.
- Preserve rule and decoration contracts through `test/minga_editor/ui/prettify_symbols_test.exs` and `test/minga/buffer/conceal_range_test.exs`.

#### Validation

- Focused: `mix test.debug test/minga_editor/ui/prettify_symbols_effect_test.exs test/minga_editor/ui/prettify_symbols_test.exs test/minga/buffer/conceal_range_test.exs`
- Broad: `git diff --check && make lint && mix test.llm --max-cases 4`

#### Non-goals and budget

- Do not add a config observer, process, registry, scheduler, protocol, frontend command, option-change event, wrapper, or dead-buffer abstraction.
- Do not change capture rules, enabled scheduling, render scheduling, or unrelated empty-highlight behavior.
- Do not remove or mutate conceal groups other than `:prettify_symbols`.
- **Maximum production additions:** 200 lines.
- **Maximum test additions:** 160 lines.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/3007
- **Commit SHA:** `d55840281`
- **Merge SHA:** `fda6e81df20f0f8ab0667287adfe9386aa98d14e`
- **Focused tests:** 35 passed: 8 effect tests, 6 rule tests, and 21 conceal-range tests including 8 properties.
- **Broad validation:** `git diff --check`, `make lint`, and `mix test.llm --max-cases 4` passed on current main; full non-heavy result: 58 doctests, 98 properties, 9,912 tests, 0 failures, 1 skipped, 578 excluded.
- **Planner verdict:** `READY`; exact owners, transition order, worker/apply boundary, tests, constraints, and validation are locked with no unresolved implementer question.
- **Ponytail verdict:** `LEAN` after deleting the obsolete test-only `PrettifySymbols.apply/3`; targeted recheck returned `Lean already. Ship.`
- **Elixir verdict:** `PASS` after narrowing expected Buffer exits and making cleanup cancel admitted work before mutation.
- **Bug-hunt verdict:** `PASS` after moving all Buffer mutation out of workers; canceled and stale candidates cannot re-add conceals.
- **Final reviewer verdict:** `PASS` after a targeted correction narrowed worker and completed-apply catches to expected dead Buffer exits; behavior coverage proves unexpected exits propagate.
- **Production lines added/removed:** 99 added / 58 removed, net +41.
- **Test lines added/removed:** 160 added / 2 removed, net +158.
- **Concepts added/removed:** Preparation and application are explicit phases of the existing effect; the obsolete combined `apply/3` entry point is removed. No process, scheduler, protocol, or wrapper is added.
- **Findings resolved:** L13. Disabling prettify symbols now cancels admitted work and removes installed prettify conceals without permitting stale worker mutation.
- **Discoveries affecting later work:** Canceling a task cannot retract an already-sent Buffer call. Effect workers that race cleanup must return data and defer mutation until scheduler claim.
- **Completion date:** 2026-07-18

### W014: Preserve sidebar focus during Git refresh

- **Status:** VERIFIED
- **Audit ID:** L14
- **Roadmap unit:** W014, Preserve sidebar focus during Git refresh
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `cea126bc0d520698c6ddb79ca6ae2fd0dc85aa7e`
- **Freshness basis:** Current `HEAD` and `origin/main` contain the verified W013 lifecycle fix. A visible Git panel registration still marked itself focused during every background panel replacement.

#### Observable outcome

Background Git status replacement updates the registered panel's visibility, badge count, and content without changing the focused left sidebar. Explicit Git activation still selects and focuses Git Status. Closing Git Status clears its selected shell state and registered visibility and focus.

#### Owners and failure path

- `MingaEditor.Shell.Traditional.Sidebars.active_id` owns the selected left-sidebar identity.
- `MingaEditor.Shell.Traditional.SidebarWorkflow.select/2` owns explicit selection and registry focus synchronization.
- `MingaEditor.Sidebar.BuiltinSurfaces` projects shell panel state into `MingaEditor.Extension.Sidebar`; it does not own focus selection.
- Before this unit, `FileEventHandler.handle_git_status_changed/2` replaced the panel through `SidebarWorkflow.replace_git_status/2`. The projection registered every visible Git panel with `focused?: true` and called `Sidebar.focus_left/2`, so a background refresh could steal focus from Observatory.

#### Locked implementation

1. Pass an explicit boolean focus projection through `BuiltinSurfaces.sync_git_status_panel/3`.
2. Register a missing Git panel as invisible and unfocused with badge count zero.
3. Register a visible Git panel with the passed focus and current entry count.
4. Call `Sidebar.focus_left/2` only when the projected Git panel is both visible and focused.
5. Derive the projection in `SidebarWorkflow.sync_git_status_sidebar/2` from `active_id(state) == "git_status"`.
6. Keep `replace_git_status/2` as a data replacement. Keep `select/2` as the explicit focus transition.
7. Preserve Observatory synchronization without changes.

#### Required tests

- `test/minga_editor/handlers/file_event_handler_test.exs`: a background Git refresh updates panel data, visibility, and badge count while Observatory remains selected and focused.
- `test/minga_editor/handlers/gui_action_handler_test.exs`: a visible Git panel begins unfocused, then explicit activation selects Git and installs the Git keymap scope.
- `test/minga_editor/shell/traditional/sidebars_test.exs`: closing Git clears shell selection and registered visibility, focus, and badge count.

#### Validation

- Focused: `mix test.debug test/minga_editor/handlers/file_event_handler_test.exs test/minga_editor/handlers/gui_action_handler_test.exs test/minga_editor/shell/traditional/sidebars_test.exs`
- Broad: `git diff --check && make lint && mix test.llm --max-cases 4`

#### Non-goals and budget

- Do not add a process, registry, generic update API, wrapper, protocol, frontend change, or architecture migration.
- Do not make `replace_git_status/2` select or focus a sidebar.
- Do not change Observatory synchronization.
- **Maximum production additions:** 40 lines.
- **Maximum test additions:** 80 lines.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/3009
- **Commit SHA:** `76ed51dde`
- **Merge SHA:** `098436f3fe321ed33ba1d4e5ec6e3994298d1731`
- **Focused tests:** 48 passed across the three locked test files.
- **Broad validation:** `git diff --check`, `make lint`, and `mix test.llm --max-cases 4` passed; full non-heavy result: 58 doctests, 98 properties, 9,914 tests, 0 failures, 1 skipped, 578 excluded.
- **Planner verdict:** `READY`; the selected-sidebar owner, projection boundary, focus transitions, tests, constraints, and validation are locked with no unresolved implementer question.
- **Ponytail verdict:** `LEAN`; targeted review returned `Lean already. Ship.`
- **Elixir verdict:** `PASS`; explicit clauses, boolean guards, owner-derived projection, and state flow are idiomatic and narrow.
- **Bug-hunt verdict:** `PASS`; refresh, activation, and close paths preserve the authoritative focus transition.
- **Final reviewer verdict:** `PASS`.
- **Production lines added/removed:** 22 added / 13 removed, net +9.
- **Test lines added/removed:** 53 added / 0 removed, net +53.
- **Concepts added/removed:** One explicit focus projection replaces visibility-derived focus. No process, registry, abstraction, protocol, or frontend path is added.
- **Findings resolved:** L14. Background Git status replacement now preserves shell-owned sidebar focus while explicit activation and close retain their focus transitions.
- **Discoveries affecting later work:** Registry projections must derive focus from shell-owned selection instead of inferring focus from visibility.
- **Completion date:** 2026-07-18

### W015: Size popup metadata from the frontend viewport

- **Status:** VERIFIED
- **Audit ID:** L15
- **Roadmap unit:** W015, Size popup metadata from the frontend viewport
- **Ponytail verdict:** `ACCEPT/direct`
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `medium`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness SHA:** `57d4e10bba0d5825164b20ca032544cac95baace`
- **Freshness basis:** Current `HEAD` and `origin/main` contain verified W014. Popup lifecycle still matched a nonexistent top-level viewport and fell back to 24 by 80.

#### Observable outcome

New split and float popup windows initialize their viewport metadata from `state.frontend.terminal_viewport`, including dimensions reported after a frontend resize.

#### Owner and failure path

- `MingaEditor.State.Frontend` owns the terminal viewport and its resize transition.
- `MingaEditor.UI.Popup.Lifecycle` owns popup Window construction.
- Before this unit, both popup creation branches called `viewport_size/1`. That helper looked for `state.viewport`, which is not an `EditorState` field, then returned `{24, 80}`.

#### Locked implementation

1. Read `state.frontend.terminal_viewport.rows` and `.cols` directly in split popup construction.
2. Read the same frontend-owned dimensions in float popup construction.
3. Delete the stale helper, hardcoded fallback, and unused `Viewport` alias.
4. Do not retain a compatibility path for a nonexistent state shape.

#### Required test

- `test/minga_editor/ui/popup/lifecycle_test.exs`: keep workspace viewport at 24 by 80, resize only the frontend viewport to 40 by 120, open one split and one float popup, and assert both Window viewports use 40 by 120.

#### Validation

- Focused: `mix test.debug test/minga_editor/ui/popup/lifecycle_test.exs`
- Broad: `git diff --check && make lint && mix test.llm --max-cases 4`

#### Non-goals and budget

- Do not change layout geometry, split sizing, popup rules, protocols, rendering, or frontend resize ownership.
- Do not add a helper, fallback, abstraction, module, or compatibility path.
- **Maximum production additions:** 40 lines.
- **Maximum test additions:** 40 lines.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/3011
- **Commit SHA:** `90ba545eb`
- **Merge SHA:** `e2d958d8a540d49625a73104d07a39eebcece821`
- **Focused tests:** 30 popup lifecycle tests passed.
- **Broad validation:** `git diff --check`, `make lint`, and `mix test.llm --max-cases 4` passed; full non-heavy result: 58 doctests, 98 properties, 9,915 tests, 0 failures, 1 skipped, 578 excluded.
- **Planner verdict:** `READY`; source owner, both construction branches, regression assertion, constraints, and validation are locked.
- **Ponytail verdict:** `LEAN`; targeted review returned `Lean already. Ship.`
- **Elixir verdict:** `PASS`; direct frontend field access and stale helper deletion match existing Elixir conventions.
- **Bug-hunt verdict:** `PASS`; both popup creation branches and the resize owner are covered.
- **Final reviewer verdict:** `PASS`.
- **Production lines added/removed:** 4 added / 7 removed, net -3.
- **Test lines added/removed:** 33 added / 0 removed, net +33.
- **Concepts added/removed:** The invalid state-shape fallback is removed; no concept is added.
- **Findings resolved:** L15. Split and float popup Window metadata now uses frontend-reported terminal dimensions without a stale fallback.
- **Discoveries affecting later work:** Frontend-reported row fit and terminal dimensions must be read from `State.Frontend`, not a workspace or top-level fallback.
- **Completion date:** 2026-07-18

### W016: Retire remote buffer registrations with root buffers

- **Status:** VERIFIED
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `0f67b113ddd6e08c511528d2c306ed12a2d5810b`
- **Observable outcome:** After `MingaEditor.State.remove_buffer(state, retired_pid)`, every `{server, path} => retired_pid` entry is removed from `state.remote`; entries for other PIDs remain.
- **Failure path:** Root buffer retirement removed parser, lifecycle, workspace, shell runtime, and git state references but left `MingaEditor.State.Remote.buffers` registrations pointing at retired buffer PIDs.
- **Locked implementation:** Add owner-local `Remote.retire_buffer/2` with a pid guard and `Map.reject/2`, call it from root `State.remove_buffer/2`, and install the returned remote state in the root struct.
- **Focused validation:** `mix test.debug test/minga_editor/state_test.exs:502` passed 1 regression with 10 excluded; full `state_test.exs` passed 11 tests; `buffer_lifecycle_test.exs` passed 10 tests.
- **Broad validation:** `make lint` passed; `mix test.llm --max-cases 4` passed 58 doctests, 98 properties, and 9,916 tests with 0 failures, 1 skipped, and 578 excluded; merged CI run `29671111665` passed every required check.
- **Non-goals:** No workflow changes, liveness probes, catches, wrappers, new process, module, dependency, behaviour, protocol, registry, config, data shape, root forwarding API, or changes to existing Remote read contracts.
- **Maximum production additions:** 15 lines.
- **Maximum test additions:** 25 lines.

#### Completion evidence

- **PR URL:** https://github.com/jsmestad/minga/pull/3016
- **Commit SHA:** `6540b8ee8bdcb3ac1e2a51975c4df434b5bafcb0`
- **Merge SHA:** `73edcf5ea402f7edf7859e341af11cc44133afcd`
- **Planner verdict:** `READY`; owner, exact filter, root installation, assertions, constraints, and validation were locked.
- **Ponytail verdict:** `LEAN`; targeted review returned `Lean already. Ship.`
- **Elixir verdict:** `PASS`; the owner-local transition and `Map.reject/2` are the idiomatic immutable update.
- **Bug-hunt verdict:** `PASS`; the sole documentation command mismatch was corrected from line 501 to 502 and the exact regression passed.
- **Final reviewer verdict:** `PASS`; the owner transition, atomic root installation, regression, budgets, evidence, and merge safety are accepted.
- **Production lines added/removed:** 9 added / 1 removed, net +8.
- **Test lines added/removed:** 20 added / 0 removed, net +20.
- **Concepts added/removed:** Added one owner-local `Remote.retire_buffer/2` transition; no new process, module, dependency, protocol, registry, config, or data shape.
- **Findings resolved:** L16. Root buffer retirement now removes every Remote buffer registration for the retired PID while preserving other registrations.
- **Discoveries affecting later work:** Buffer retirement invariants span root owners; each owner must expose its own transition and root removal must install every returned owner value atomically.
- **Completion date:** 2026-07-19

### W017: Target agent tool collapse by stable message ID

- **Status:** VERIFIED
- **Audit ID:** L19
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `129f1dd9f981ef4cdbc73c4d4bc35deefd833f5e`
- **Observable outcome:** macOS and Go actions for resident tool or thinking entries send the existing stable uint32 transcript message ID, and Session toggles only the full-transcript entry with that ID after any resident front trim.
- **Failure path:** Both frontends sent a resident suffix index in GUI action 0x15; BEAM decoded `index(2)` and applied it through `Transcript.update_at/3` to the full transcript, so resident index zero could mutate an unrelated older message.
- **Wire contract:** Clean cutover of GUI action 0x15 from `index(2)` to big-endian `message_id(4)` and protocol version 12 to 13. No old two-byte fallback. Zero, unknown, and non-collapsible IDs are Session no-ops without notification or save scheduling.
- **Authoritative owner:** `MingaAgent.Session.Transcript` owns stable-ID collapse mutation; Session owns effects; `MingaEditor.Frontend.Protocol.GUI` owns BEAM decoding; Swift and Go echo IDs already present in their resident models.
- **Locked implementation:** Add owner-local `Transcript.toggle_message_collapse/2`; update Session without changing `toggle_tool_collapse/2` arity; decode uint32 IDs; update macOS card/input encoding and Go shortcut/protocol encoding; bump and regenerate protocol version outputs; update GUI protocol documentation.
- **Accepted mutations:** Matching tool calls use `ToolCall.toggle_collapsed/1`; matching thinking entries invert their collapsed flag. Every other message kind and missing ID returns the original transcript.
- **Tests:** Lock BEAM 4-byte decode and malformed old payloads, owner no-op/revision behavior, Session later-ID targeting, Swift six-byte encoding, and Go stable-ID shortcut encoding including zero-ID refusal.
- **Focused validation:** `mix protocol.gen --check`; focused BEAM protocol/transcript/session tests; focused Go protocol/UI tests; focused Swift GUI action encoder tests.
- **Broad validation:** `make lint`; `mix test.llm --max-cases 4`; `cd go/tui && go test ./...`; `cd macos && xcodebuild test -scheme Minga -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO`.
- **Non-goals:** No resident-store redesign, new action, compatibility shim, old-index fallback, negotiation branch, config, process, module, dependency, parallel data shape, new UI state, liveness behavior, or changes to toggle-all, approvals, scrolling, epochs, or other actions.
- **Maximum production additions:** 45 net lines across Elixir, Swift, and Go; documentation and generated outputs excluded.
- **Maximum test additions:** 120 lines across BEAM, Swift, and Go.
- **Dependencies:** W016 is VERIFIED and merged; no unresolved dependency or implementer question remains.
- **Completion evidence:**
  - **Implementation result:** Protocol schema/docs cut over GUI action 0x15 to big-endian `message_id(4)` and protocol version 13; BEAM decodes only 4-byte payloads; `MingaAgent.Session.Transcript.toggle_message_collapse/2` owns stable-ID tool/thinking mutation; Session only publishes/saves on changed transcript; macOS and Go producers echo resident stable IDs and suppress zero IDs.
  - **Failure reproduced:** `mix run -e ...` before the fix returned `old_uint16: {:ok, {:agent_tool_toggle, 7}}` and `uint32_id: :error`.
  - **Focused validation:** `mix protocol.gen --check` passed; the locked BEAM protocol, Transcript, and Session set passed 171 tests, then 28 focused tests and the 11-test Transcript suite passed after review fixes; the locked Go protocol/UI selection passed both packages. Local Swift validation was unavailable on Linux; merged macOS CI passed the Swift GUI and protocol integration suites.
  - **Broad validation:** `make lint` passed after the final production edit; `mix test.llm --max-cases 4` passed 58 doctests, 98 properties, and 9,916 tests with 0 failures, 1 skipped, and 578 excluded; `cd go/tui && go test ./...` passed 7 packages with 1 package containing no tests; merged CI run `29672836893` passed every required check.
  - **Line deltas:** Production Elixir/Swift/Go net +23 lines, under the +45 cap. Tests net +118 lines, under the +120 cap. Docs/schema net +2 lines. Generated Go protocol version net 0.
  - **Concepts added:** One Transcript-owned stable message-ID collapse transition and the uint32 GUI action payload for `agent_tool_toggle`.
  - **Concepts removed:** Resident-index collapse targeting, two-byte 0x15 payload acceptance, Go resident index selectors, and one draft single-use Transcript transform helper.
  - **Pre-acceptance reviews:** Correctness `PASS`; Elixir craftsmanship `PASS` after eliminating no-op list allocation and aligning the owner typespec; Ponytail `Lean already. Ship.`
  - **Final reviewer:** `PASS`; the stable-ID cutover, owner transition, effects, callsites, tests, budgets, and merge safety are accepted.
  - **PR URL:** https://github.com/jsmestad/minga/pull/3020
  - **Implementation commit SHA:** `da792f30d`
  - **Merge SHA:** `afa39a0221604629d48be73a86fb6ef9f97452aa`
  - **Findings resolved:** L19. Agent tool and thinking collapse now targets stable transcript identity across BEAM, macOS, and Go even after resident front trimming.
  - **Discoveries affecting later work:** Resident semantic models already carry stable identity; frontend actions must echo that identity instead of deriving a local array position.
  - **Completion date:** 2026-07-19

### W018: Capture resize drags and clear release state

- **Status:** VERIFIED
- **Audit ID:** L22
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `5aa3ea6e2b8b3ec87246610ee5b9b917f017fa58`
- **Observable outcome:** Active left-button resize drag and release events bypass focus-tree hit routing, and active text or resize release always clears its drag state even when the pointer leaves the tree, coordinates are negative, or the active buffer disappears.
- **Failure path:** Router captured text drags directly but routed resize drags through the focus tree, where outside coordinates or another handler could swallow them. Mouse checked for an active buffer and negative coordinates before release cleanup, preserving stale drag state on early return.
- **Authoritative owners:** `Input.Router.dispatch_mouse/7` owns capture order; `Mouse.handle/7` owns release semantics; `State.Mouse.stop_drag/1` and `stop_resize/1` own value transitions; `Session.State.set_mouse/2` owns workspace installation.
- **Locked implementation:** Direct-route active `%MouseState{dragging: true}` and `%MouseState{resize_dragging: {_, _}}` left drag/release events before negative-coordinate and focus-tree routing. Move existing text and resize release clauses before the no-buffer and negative-coordinate guards without changing their bodies or auto-copy behavior.
- **Tests:** Router regressions prove resize release outside the focus tree clears state and active resize drag bypasses node handlers. Mouse regressions prove text and resize release clear state after the active buffer disappears; include negative-coordinate resize release if it remains concise.
- **Focused validation:** `mix test.debug test/minga_editor/input/router_test.exs test/minga_editor/mouse_test.exs test/minga_editor/state/mouse_test.exs` -> 75 passed.
- **Broad validation:** `make lint`; `mix test.llm --max-cases 4`; `git diff --check`.
- **Non-goals:** No focus-tree, shell lifecycle, mouse protocol, separator math, drag-start, selection, auto-copy, hover, click-count, wheel, frontend, process, module, dependency, registry, config, compatibility, or data-shape changes.
- **Maximum production additions:** 50 net lines; expected 10 to 25.
- **Maximum test additions:** 80 lines.
- **Dependencies:** W017 is VERIFIED and merged; no unresolved dependency or implementer question remains.
- **Completion evidence:**
  - **PR URL:** https://github.com/jsmestad/minga/pull/3022
  - **Implementation commit SHA:** `d4d3b5389`
  - **Merge commit SHA:** `dd8848b879ce3c268f6cefa705224e3f2a04e19d`
  - **Implementation result:** `Input.Router.dispatch_mouse/7` now captures active `%MouseState{dragging: true}` and `%MouseState{resize_dragging: {_, _}}` left drag/release events before negative-coordinate and focus-tree routing, running the existing shell availability check and `Mouse.handle/7` path directly. `Mouse.handle/7` now runs active text and resize release cleanup before the no-active-buffer and negative-coordinate guards, preserving the existing text visual auto-copy path and owner APIs.
  - **Regression coverage:** Added router regressions for resize release outside the focus tree clearing resize state and active resize drag bypassing focus-tree node handlers. Added Mouse regressions for resize and text release clearing state after active-buffer loss. The optional negative-coordinate Mouse regression was not added so test additions stay within the locked budget; the production release clauses are still ordered before the negative-coordinate guards.
  - **Failure reproduced:** Before the production fix, the new focused regressions failed 5 times: resize drag reached `InputRouterMouseProbe`, resize release outside the focus tree left `resize_dragging` set, and text/resize release cleanup was skipped after active-buffer loss or negative coordinates.
  - **Focused validation:** `mix test.debug test/minga_editor/input/router_test.exs test/minga_editor/mouse_test.exs test/minga_editor/state/mouse_test.exs` passed with 75 tests.
  - **Broad validation:** `make lint` passed Credo, compile, and incremental Dialyzer; `mix test.llm --max-cases 4` passed 58 doctests, 98 properties, and 9,920 tests with 0 failures, 1 skipped, and 578 excluded.
  - **Merged CI:** Run `29674129331` passed every required check, including Elixir, Dialyzer, lint/format, Zig, Go, Swift, protocol integration, Neovim conformance, boot smoke, and keystroke latency.
  - **Line deltas:** Production `lib/minga_editor/input/router.ex` +21/-3 and `lib/minga_editor/mouse.ex` +38/-60, net -4. Tests `test/minga_editor/input/router_test.exs` +33 and `test/minga_editor/mouse_test.exs` +41, total +74 additions.
  - **Concepts added/removed:** Added no architecture or data shape; removed duplicated release-state installation and the stale routing/guard ordering path that could swallow active resize release cleanup.
  - **Pre-acceptance reviews:** Correctness found no routing or state defect after its evidence-only correction; Elixir craftsmanship `PASS` after release clauses reused `update_mouse/2` and fixtures used `Windows.set_tree/2` and `Buffers.remove/2`; Ponytail `Lean already. Ship.`
  - **Final reviewer:** `PASS`; locked routing and release-cleanup contract, ownership, lifecycle, API, tests, budgets, evidence, and merge safety accepted with no findings.
  - **Completion date:** 2026-07-19

### W019: Retire redundant tool-status clear timers

- **Status:** VERIFIED
- **Audit ID:** L23
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `a139cf97ca0ba7d4225eab1a41dc1ae15c8e5f03`
- **Observable outcome:** An old tool-install completion cannot dismiss a newer tool-like notice. Tool completion retains its text, log, picker refresh, and render effects, then expires only through the ordinary identity-safe notice lifecycle.
- **Failure path:** Tool completion publishes through `NoticeWorkflow`, then also schedules bare `:clear_tool_status`. The old atom later routes through `ToolHandler`, infers ownership from the current message prefix, and can dismiss a newer `Installing ...` or `✓ ... installed` notice.
- **Authoritative owners:** `Shell.Traditional.Notice` owns ordinary notice identity; `NoticeWorkflow` owns publish, timer cancellation/creation, and timeout delivery; `Shell.Traditional.State` installs Notice transitions. `ToolHandler` does not own notice lifecycle.
- **Locked implementation:** Delete ToolHandler's conditional five-second clear effect, prefix-based clear handler, `send_after` effect type/executor, and the Editor atom-dispatch entry. Retain `%Notice{id, message, timer}` and `{:notice_timeout, id}` unchanged. Do not replace the redundant timer with another tagged timer.
- **Tests:** Replace old clear scheduling/prefix tests with non-headless and headless ownership assertions; add an Editor `handle_info/2` regression proving a legacy bare clear atom cannot dismiss newer `Installing ...` or `✓ ... installed` notices; retain existing stale/matching notice-ID tests.
- **Focused validation:** `mix test test/minga_editor/handlers/tool_handler_test.exs test/minga_editor/shell/traditional/notice_workflow_test.exs`.
- **Broad validation:** `mix test test/minga_editor/handlers test/minga_editor/shell/traditional`; `mix test.llm --max-cases 4`; `make lint`; `git diff --check`.
- **Non-goals:** No ToolStatus struct, tagged replacement timer, registry, process, behaviour, protocol, config, public API, compatibility shim, Tool Manager payload, notification, operation-feedback, status-bar, or frontend changes.
- **Maximum production additions:** 0 net lines; expected net deletion. Any positive additions require explanation and remain capped at 50.
- **Maximum test additions:** 40 lines expected, 80 hard ceiling.
- **Dependencies:** Existing NoticeWorkflow identity-safe timeouts are merged; no unresolved dependency or implementer question remains.
- **Completion evidence:**
  - **Implementation result:** Deleted ToolHandler's five-second clear effect, prefix-based clear handler, timer effect type/executor, and Editor atom route. Tool completion still publishes the same success notice and returns the same log, picker refresh, and render effects; NoticeWorkflow is now the sole timeout owner.
  - **Failure reproduced:** Before production deletion, focused regressions observed `{:send_after, :clear_tool_status, 5_000}` and a legacy bare atom dismissed a newer `Installing fd...` notice.
  - **Regression coverage:** Non-headless completion records the NoticeWorkflow timer and no ToolHandler clear effect; headless completion records no notice timer; legacy bare delivery preserves both `Installing ...` and `✓ ... installed` notices and their IDs; existing stale/matching notice-ID tests remain unchanged.
  - **Focused validation:** `mix test.debug test/minga_editor/handlers/tool_handler_test.exs test/minga_editor/shell/traditional/notice_workflow_test.exs` passed 16 tests; `mix test test/minga_editor/handlers test/minga_editor/shell/traditional` passed 209 tests.
  - **Broad validation:** `make lint` passed Credo, compile, and incremental Dialyzer after the final effect-union narrowing; `mix test.llm --max-cases 4` passed 58 doctests, 98 properties, and 9,918 tests with 0 failures, 1 skipped, and 578 excluded.
  - **Line deltas:** Production `lib/minga_editor.ex` +3/-5 and `lib/minga_editor/handlers/tool_handler.ex` +13/-59, net -48. Tests `test/minga_editor/handlers/tool_handler_test.exs` +25/-51, net -26.
  - **Concepts added/removed:** Added none. Removed the second tool-status timer lifecycle, prefix ownership inference, generic timer effect, bare Editor dispatch route, unreachable generic log levels, and obsolete duplicate tests.
  - **Pre-acceptance reviews:** Correctness `PASS`; Elixir craftsmanship `PASS` after documentation and effect types were aligned to actual ownership; Ponytail `Lean already. Ship.` after duplicate headless effect coverage was removed.
  - **Final reviewer:** `PASS`; redundant timer deletion, sole NoticeWorkflow ownership, preserved tool effects, tests, budgets, evidence, and merge safety accepted with no findings.
  - **PR URL:** https://github.com/jsmestad/minga/pull/3024
  - **Implementation commit SHA:** `8d32acf16`
  - **Merge commit SHA:** `d745a0ed51b58f47bf4f2c3427dba047e043ff74`
  - **Merged CI:** Run `29675403567` passed every required check, including Elixir, Dialyzer, lint/format, Zig, Go, Swift, protocol integration, Neovim conformance, boot smoke, and keystroke latency.
  - **Completion date:** 2026-07-19

### W020: Guard buffer lookup-to-use process exits

- **Status:** VERIFIED
- **Audit ID:** L24
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `c28eb0ee433b885513debe28fad760dd3b4c2b70`
- **Observable outcome:** A buffer dying after file-path lookup no longer crashes file-change handling, which returns the existing Editor state unchanged. Input snapshots with a stale active PID retain the snapshot shape with version `0` and cursor `nil`.
- **Failure path:** `FileWatcherHelpers` catches exits during path lookup but then calls unprotected `:sys.get_state/1`; `Input.Router` catches cursor exits but calls unprotected `Buffer.version/1`.
- **Authoritative owners:** `FileWatcherHelpers` owns stale file-change fallback; `Input.Router` owns pre-action snapshot fallbacks; Buffer process APIs and the existing snapshot shape remain unchanged.
- **Locked implementation:** Add one local safe buffer-state read returning `{:ok, Buffer.State.t()}` or `:unavailable`, with only `catch :exit`; return unchanged state before file stat on unavailable. Add only `catch :exit, _ -> 0` around Router's active-buffer version call. Do not widen catches or change other callers.
- **Tests:** Add a direct file-change workflow regression using a raw one-shot process that answers `:file_path` then exits before `:sys.get_state/1`; add a public `Router.capture_snapshot/1` regression with a deterministically stopped active buffer. Preserve live and nil branches.
- **Focused validation:** `mix test.debug test/minga_editor/file_change_test.exs test/minga_editor/input/router_test.exs`.
- **Broad validation:** `mix test test/minga_editor`; `mix test.llm --max-cases 4`; `make lint`; `git diff --check`.
- **Non-goals:** No nested test module, production module, wrapper, public Buffer API, behavior, registry, process, monitor, retry, supervision, config, dependency, compatibility shim, stale-PID removal, or catches around reload, file IO, modal, notice, render, LSP, GUI, mouse, or pure state logic.
- **Maximum production additions:** 20 net lines, hard ceiling 50.
- **Maximum test additions:** 60 lines, hard ceiling 80.
- **Dependencies:** Existing Buffer process APIs and snapshot shape are merged; no unresolved dependency or implementer question remains.
- **Completion evidence:**
  - **Implementation result:** `FileWatcherHelpers.handle_file_change/2` now treats a buffer that disappears after path lookup as stale by reading `:sys.get_state/1` through a private `safe_buffer_state/1` tagged result and returning the original Editor state before file stat, reload, conflict modal, or notice work. `Input.Router` now falls back to version `0` only when `Buffer.version/1` exits for the active buffer; the snapshot shape and existing cursor fallback remain unchanged.
  - **Regression reproduction:** With only the new regressions in place, `mix test test/minga_editor/file_change_test.exs:88 test/minga_editor/input/router_test.exs:553 --trace` failed deterministically on the old code with exits from `:sys.get_state(pid)` and `GenServer.call(pid, :version, 5000)`.
  - **Focused validation:** `mix test.debug test/minga_editor/file_change_test.exs test/minga_editor/input/router_test.exs` passed 33 tests after the review correction.
  - **Broad validation:** `mix test test/minga_editor` passed 4,476 tests with 33 excluded after building the worktree's missing native parser; `mix test.llm --max-cases 4` passed 58 doctests, 98 properties, and 9,920 tests with 0 failures, 1 skipped, and 578 excluded; `make lint` passed Credo, compile, and incremental Dialyzer; `git diff --check` passed.
  - **Line budget:** Production net +13 lines (`file_watcher_helpers.ex` +11, `router.ex` +2); test additions +42 lines (`file_change_test.exs` +26, `router_test.exs` +16), within W020 limits.
  - **Pre-acceptance reviews:** Correctness `PASS`; Elixir craftsmanship concern resolved by matching the repository's `spawn_link` plus `GenServer.reply/2` one-shot fixture idiom while retaining project-required monitor synchronization for the dead Buffer test; Ponytail `Lean already. Ship.`
  - **Final reviewer:** `PASS`; both lookup-to-use exit windows, ownership, APIs, deterministic regressions, line budgets, validation evidence, and merge safety accepted with no findings.
  - **PR URL:** https://github.com/jsmestad/minga/pull/3026
  - **Implementation commit SHA:** `1d7465b7c`
  - **Merge commit SHA:** `4d1bcc1571c8334d94fbbcd5471210b486b679f0`
  - **Merged CI:** Run `29676744074` passed every required check, including Elixir, Dialyzer, lint/format, Zig, Go, Swift, protocol integration, Neovim conformance, boot smoke, and keystroke latency.
  - **Completion date:** 2026-07-19

### W021: Roll back partial native IPC initialization

- **Status:** VERIFIED
- **Audit ID:** L25
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `2f5bb009d3663657d36809b7e042edbb8ad66170`
- **Observable outcome:** Native IPC initialization failures after listener creation preserve the original failure while removing the failed generation's descriptor, temporary descriptor, listener, and socket path in reverse acquisition order.
- **Authoritative owner:** `MingaEditor.NativeIPC.Server` owns endpoint acquisition and partial-init rollback; `Server.State` remains the unchanged steady-state owner.
- **Locked implementation:** Fetch required options before resource acquisition. Keep all parent, directory, socket, descriptor, identity, and authentication checks unchanged. On post-listen failure, close the listener then unlink its socket. Descriptor publication removes its temp file on pre-rename failure and removes published `current.json` only when its `core_instance_id` matches the failed generation. Start the acceptor only after complete acquisition.
- **Tests:** Pre-create `runtime_dir/current.json` as a directory, start the real IPC supervisor, assert the original `:eisdir` startup error, preserve the blocker directory, and assert no `control-*` socket or `current.json.tmp-*` remains. Preserve symlink rejection and normal endpoint lifecycle tests.
- **Focused validation:** `mix test test/minga/frontend/native_ipc_test.exs --seed 0`.
- **Broad validation:** `mix test`; `make lint`; `git diff --check`.
- **Non-goals:** No endpoint struct, new module, process, registry, behavior, dependency, public API, config, protocol/schema change, test injection, trust-check weakening, runtime directory removal, helper change, or connection/request redesign.
- **Maximum production additions:** 50 net lines.
- **Maximum test additions:** 45 lines.
- **Dependencies:** Existing File, Path, `:gen_tcp`, JSON, supervisor, identity, and descriptor APIs only; no unresolved implementer question remains.
- **Completion evidence:**
  - **Implementation result:** `MingaEditor.NativeIPC.Server.init/1` now fetches the required task supervisor before identity/runtime/socket work, validates the private parent/runtime directory before resource acquisition, opens the AF_UNIX listener inside a staged endpoint boundary, and starts the acceptor only after socket validation and descriptor publication succeed. Post-listen errors close the listener and unlink the socket while preserving the original reason; descriptor publication removes only the temp file before a successful rename and removes `current.json` after rename only when the failed generation's `core_instance_id` is still current.
  - **Regression evidence:** Added the real filesystem/AF_UNIX blocker-directory regression in `test/minga/frontend/native_ipc_test.exs`; before the fix, `mix test test/minga/frontend/native_ipc_test.exs --seed 0` failed because `entries` still contained `control-DThY6HrvSBE_ilfh.sock` next to `current.json`. After the fix, the same test asserts the original `:eisdir` startup error, preserved blocker directory, no `control-*` socket, no `current.json.tmp-*`, and only `current.json` remaining.
  - **Focused validation:** `mix test test/minga/frontend/native_ipc_test.exs --seed 0` passed with 8 tests on 2026-07-19.
  - **Line budget:** Production delta `+77/-30` in `lib/minga_editor/native_ipc/server.ex` for net `+47`; test delta `+45/-0` in `test/minga/frontend/native_ipc_test.exs`, within W021 limits.
  - **Concepts added/removed:** Added private staged endpoint acquisition and rollback helpers inside the existing server owner. Added no endpoint struct, module, process, registry, behavior, dependency, public API, config, protocol, schema, or test injection. Removed no steady-state trust check or normal terminate behavior.
  - **Pre-acceptance reviews:** Correctness `PASS`; Elixir craftsmanship `PASS` after flattening listener-owned error flow and consolidating finalization rollback into one catch-and-reraise path; Ponytail `Lean already. Ship.`
  - **Broad validation:** `mix test --max-cases 4` passed 10,444 tests, including 58 doctests and 99 properties, with 0 failures, 1 skipped, and 210 excluded after building the worktree's missing native parser and hook runner; `make lint` passed Credo, compile, and incremental Dialyzer after the final control-flow correction; `git diff --check` passed.
  - **Final reviewer:** `PASS`; staged rollback, trust checks, original errors, steady-state ownership, public APIs, real IPC regression, line budgets, validation evidence, and merge safety accepted with no findings.
  - **PR URL:** https://github.com/jsmestad/minga/pull/3028
  - **Implementation commit SHA:** `6e29b355f`
  - **Merge commit SHA:** `f7b75be60c4321e1064bb358de1ae5c3e0af8e90`
  - **Merged CI:** Run `29678609780` passed every required check, including Elixir, Dialyzer, lint/format, Zig, Go, Swift, protocol integration, Neovim conformance, boot smoke, and keystroke latency.
  - **Completion date:** 2026-07-19

### W022: Snapshot Git syncing as render data

- **Status:** VERIFIED
- **Audit ID:** L26
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `4786b2f909a714e5329559a22953a5982fee82e5`
- **Observable outcome:** Active or queued Git mutation activity remains `git_syncing: true` across `EditorState` snapshot, cache-free frame intent, renderer materialization, and emit context; inactive states remain false, and no render transfer value carries the scheduler process.
- **Authoritative owner:** `RenderPipeline.Input` owns snapshot derivation, `FrameIntent` owns the renderer-boundary allowlist, and `Frontend.Emit.Context` consumes the boolean without querying process state.
- **Locked implementation:** Replace `Input.effect_scheduler` with a default-false `git_syncing` boolean computed once through `EffectScheduler.active_activity?/2`; allowlist and type the boolean on `FrameIntent`; read it strictly in `Emit.Context`; retain generic materialization unchanged and remove the obsolete scheduler alias/helper.
- **Tests:** In `test/minga_editor/render_pipeline/input_test.exs`, prove nil/idle scheduler false, deterministic active `:git_syncing` activity true, absence of `:effect_scheduler`, boolean carriage through `FrameIntent` and `BufferChanges.prepare/2`, emit-context preservation, and false after activity ends. Retain real Git async and Git status builder coverage.
- **Focused validation:** `mix test test/minga_editor/render_pipeline/input_test.exs test/minga_editor/handlers/gui_action_git_async_test.exs test/minga_editor/frontend/emit_test.exs test/minga_editor/render_model/ui/git_status_builder_test.exs`.
- **Broad validation:** `mix test`; `make lint`; `git diff --check`.
- **Non-goals:** No scheduler, policy, admission, worker, Git mutation, feedback, render-model, protocol, frontend, config, public API, dependency, process, module, behavior, registry, compatibility, or adjacent DTO redesign.
- **Maximum production additions:** 12 net lines.
- **Maximum test additions:** 80 lines.
- **Dependencies:** Existing `EffectScheduler.active_activity?/2`, `activity: :git_syncing` metadata, explicit `FrameIntent` materialization, and deterministic `Minga.Test.EffectProbe`; no unresolved implementer question remains.
- **Completion evidence:**
  - **Implementation result:** `RenderPipeline.Input` now snapshots `git_syncing` once with `EffectScheduler.active_activity?/2`, no longer carries `effect_scheduler`, and defaults manual inputs to inactive. `FrameIntent` allowlists the boolean, renderer materialization carries it through the generic `struct!(Input, ...)` path, and `Frontend.Emit.Context` consumes `state.git_syncing` strictly without a fallback scheduler query.
  - **Failure reproduction:** Before the source change, `mix test test/minga_editor/render_pipeline/input_test.exs` failed because `%Input{}` and `%FrameIntent{}` had no `:git_syncing` key while the new active/inactive render-boundary regression expected that snapshot field.
  - **Focused regression:** `test/minga_editor/render_pipeline/input_test.exs` covers nil scheduler false, live idle scheduler false, deterministic active `activity: :git_syncing` true, no scheduler carrier, `Intent` carriage, `BufferChanges.prepare/2` materialization, `Emit.Context` preservation, and false after finalization. `test/minga_editor/renderer/buffer_changes_test.exs` pins the updated frame-intent allowlist.
  - **Focused validation:** `mix test test/minga_editor/render_pipeline/input_test.exs` passed 21 tests. The four-file locked command passed 49 tests; after the allowlist assertion update, the focused five-file boundary command passed 55 tests.
  - **Line budget:** Production delta `+11/-10` across the three locked source files for net `+1`; test delta `+79/-0` in `input_test.exs` and `+1/-0` in `buffer_changes_test.exs`, exactly matching the locked +80 total test budget.
  - **Pre-acceptance reviews:** Correctness `PASS` after exact budget evidence; Elixir craftsmanship `PASS` after routing activity metadata through `Request.new/4` and documenting the process-to-data projection; Ponytail `Lean already. Ship.` after duplicate assertions were removed.
  - **Broad validation:** `mix test --max-cases 4` passed 10,446 tests, including 58 doctests and 99 properties, with 0 failures, 1 skipped, and 210 excluded after building the worktree's missing native parser and hook runner; `make lint` passed Credo, compile, format, and incremental Dialyzer after the exact frame-intent allowlist was updated and the test budget remained at 80 lines; `git diff --check` passed.
  - **Final reviewer:** `PASS`; snapshot ownership, active/inactive lifecycle semantics, process-carrier removal, explicit frame boundary, materialization, strict consumption, tests, budgets, validation evidence, and merge safety accepted with no findings.
  - **PR URL:** https://github.com/jsmestad/minga/pull/3030
  - **Implementation commit SHA:** `06c036a87`
  - **Merge commit SHA:** `40711ed89e350a30d96242f0947176b0a9e7b443`
  - **Merged CI:** Run `29680427172` passed every required check, including Elixir, Dialyzer, lint/format, Zig, Go, Swift, protocol integration, Neovim conformance, boot smoke, and keystroke latency.
  - **Completion date:** 2026-07-19

### W023: Resolve triple-click targets through `HitTest`

- **Status:** VERIFIED
- **Audit ID:** L27
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness:** Reproduced on current main SHA `edf2442ceb314e8f712dfb5de268bb529ed0b84f`.
- **Observable outcome:** Triple-click consumes the canonical `%MingaEditor.Mouse.Target.Buffer{}` resolved for the clicked screen cell, so wrapped continuation rows and folded display rows select their source buffer line and the drag origin retains the resolved window.
- **Current failure path:** `Mouse.handle_triple_click/3` focuses independently, derives a window with `origin_window_id_at/3`, derives a line with `mouse_to_buffer_line/2`, and reads `state.workspace.buffers.active`. The line helper bypasses `HitTest.position/7`, wrapping, folds, composed decorations, virtual text, and the resolved target buffer/window. A triple-click on the second visual row of a one-line wrapped buffer returns unchanged state; a folded row can select a hidden line.
- **Owner and target shape:** `MingaEditor.Mouse.HitTest.resolve_buffer/3` owns screen-to-buffer resolution and returns `%MingaEditor.Mouse.Target.Buffer{window_id, buffer, line, col, local_row, local_col, viewport}`. `MingaEditor.Mouse` remains the workflow consumer and must use `target.window_id`, `target.buffer`, and `target.line`.
- **Locked source files:** Modify only `lib/minga_editor/mouse.ex`. `lib/minga_editor/mouse/hit_test.ex` and `lib/minga_editor/mouse/target/buffer.ex` remain unchanged.
- **Locked implementation:** Preserve the leading `maybe_focus_window_at/3` call and its focus side effects. Replace the independently derived origin, line, and active buffer in `handle_triple_click/3` with one `HitTest.resolve_buffer/3` match on `{:buffer, %BufferTarget{} = target}`. Keep the existing line-end calculation, buffer move, Visual Line transition, and drag transition, passing `target.window_id` to `MouseState.start_drag/3`. Return the focused state unchanged for commands, block no-ops, and misses. Delete the now-unused `mouse_to_buffer_line/2`. Do not change any other mouse path.
- **Ordered steps:** Add failing wrapped-row and folded-row triple-click regressions at the `Mouse.handle/7` boundary; replace the triple-click target derivation with the canonical target; delete `mouse_to_buffer_line/2`; run the focused and broad commands.
- **Required regression 1:** In `test/minga_editor/mouse_test.exs`, create a 100-character one-line buffer at width 20 with wrap enabled, linebreak disabled, and line numbers disabled. Triple-click the second visual row. Assert cursor `{0, 99}`, Visual Line anchor `{0, 0}`, line visual type, active drag anchor `{0, 0}`, and drag origin equal to the active window.
- **Required regression 2:** In the same file, fold lines 0 through 2, set viewport top to 1, and triple-click the first visible content row. Assert cursor `{3, 5}`, Visual Line anchor `{3, 0}`, line visual type, drag anchor `{3, 0}`, and drag origin equal to the active window.
- **Optional compact regression:** If it fits the locked test ceiling, triple-click a non-active split and assert the resulting active window, active buffer, drag origin, and visual anchor equal the pre-resolved `BufferTarget` fields.
- **Focused validation:** `mix test test/minga_editor/mouse_test.exs --seed 0`
- **Broad validation:** `mix test test/minga_editor/mouse_test.exs test/minga_editor/mouse/hit_test_test.exs --seed 0`
- **Line budget:** Production net addition at most `+10`; test additions at most `+80`.
- **Non-goals:** No `HitTest`, target-struct, layout, fold, decoration, renderer, protocol, router, Unicode line-end, ordinary click, double-click, shift-click, modifier-click, block-command, hover, scrolling, resize, or drag-autoscroll changes. No new abstraction, process, dependency, public API, compatibility path, or target shape.
- **Dependencies and constraints:** Current `HitTest.resolve_buffer/3`, `%BufferTarget{}`, `WindowFocus`, buffer APIs, mode transition API, and mouse-state owner. Preserve focus-before-selection behavior and every unrelated mouse behavior. Return `NEEDS_REPLAN` rather than exceeding either line ceiling or changing a locked file.
- **Implementation result:** `Mouse.handle_triple_click/3` now preserves the leading focus call, consumes `HitTest.resolve_buffer/3` as `{:buffer, %BufferTarget{} = target}`, uses `target.line`, `target.buffer`, and `target.window_id` for the line selection and drag origin, and deletes obsolete `mouse_to_buffer_line/2`.
- **Failure reproduction:** Before the source correction, `mix test test/minga_editor/mouse_test.exs --seed 0` failed the two new regressions as expected: wrapped continuation row left the cursor at `{0, 0}` instead of `{0, 99}`, and folded visible-row mapping selected hidden line `{1, 5}` instead of `{3, 5}`. Result: 41/43 passed, 2 failed.
- **Focused regression:** `mix test test/minga_editor/mouse_test.exs --seed 0` passed after the source correction. Result: 43 passed.
- **Line budget:** After formatting, `git diff --numstat origin/main` reports `lib/minga_editor/mouse.ex` `8	33` (production net `-25`, within `+10`), `test/minga_editor/mouse_test.exs` `39	0` (test additions `+39`, within `+80`), and `docs/workstreams/editor-lifecycle-roadmap.md` `34	0`.
- **Pre-acceptance reviews:** Correctness `PASS`; Elixir craftsmanship `PASS`; Ponytail `Lean already. Ship.`
- **Broad validation:** The focused mouse and hit-test command passed 51 tests. The first `mix test --max-cases 4` run exposed the worktree's missing native parser binary; after `mix compile.minga_zig`, the same command passed 10,448 tests, including 58 doctests and 99 properties, with 0 failures, 1 skipped, and 210 excluded. `make lint` passed Credo, compile, format, and incremental Dialyzer. `git diff --check` passed.
- **Final reviewer:** `PASS`; canonical target consumption, focus/mode/drag preservation, duplicate-mapper deletion, wrapped/folded regressions, line budgets, validation evidence, and merge safety accepted with no findings.
- **PR URL:** https://github.com/jsmestad/minga/pull/3032
- **Implementation commit SHA:** `309c08144`
- **Merge commit SHA:** `0f1212fed87ec94e74a1b690a1decfc7cb208fa2`
- **Merged CI:** Run `29681853361` passed every required check, including Elixir, Dialyzer, lint/format, Zig, Go, Swift, protocol integration, Neovim conformance, boot smoke, and keystroke latency.
- **Completion date:** 2026-07-19

### W024: Show omitted resident transcript history

- **Status:** VERIFIED
- **Audit ID:** L28
- **Decision:** ACCEPT/native
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness:** Reproduced on current main SHA `42b8b886e62a96f08afcdfad7525ecc623962cfb`.
- **Observable outcome:** When the resident macOS agent transcript omits older complete messages, the chat shows a static `Older messages omitted` indicator at the top boundary of retained history and VoiceOver announces the same label. The indicator is absent for a complete transcript.
- **Current failure path:** The BEAM computes `resident_truncated?`, 0x86 encodes and decodes it, prepared frame publication stores it as `AgentChatState.transcriptTruncated`, and state tests cover true-to-false lifecycle. `AgentChatView` never reads the flag, so the already-owned truncation fact has no visible or accessible consumer.
- **Owner and target shape:** The BEAM remains authoritative for truncation. `AgentChatState` remains the Swift state owner for `transcriptTruncated`. `AgentChatView` owns presentation only and reads the existing boolean without mutating state or changing protocol flow.
- **Locked files:** Modify only `macos/Sources/Views/Agent/AgentChatView.swift` and `macos/Tests/MingaTests/SwiftUIViewTests.swift`.
- **Locked implementation:** Add `if state.transcriptTruncated { olderMessagesOmittedIndicator }` as the first child of the message `LazyVStack`, before retained messages. The private computed view is text-only with exact copy `Older messages omitted`, centered, system font size 11 medium, `theme.agentMutedFg`, horizontal padding 10, vertical padding 5, and a capsule using `theme.agentCodeBg.opacity(0.75)` plus `theme.agentCodeBorder.opacity(0.25)` at one point. Apply `.accessibilityElement(children: .ignore)`, label `Older messages omitted`, and hint `Earlier session messages are outside the locally retained transcript.` Add no value or interactive traits.
- **Required tests:** In `AgentChatViewTests`, publish one retained `Hello` user message with `truncated: true`; assert visible copy, retained message, and accessibility label. Publish the same frame with `truncated: false`; assert the indicator copy is absent while `Hello` remains.
- **Focused validation:** `cd macos && xcodebuild test -scheme Minga -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:MingaTests/AgentChatViewTests`
- **Broad validation:** `cd macos && xcodebuild test -scheme Minga -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:MingaTests/SwiftUIViewTests -only-testing:MingaTests/StateLifecycleTests`
- **Build smoke:** `cd macos && xcodebuild build -scheme Minga -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO`
- **Line budget:** Production net addition at most `+22`; test additions at most `+34`.
- **Non-goals:** No BEAM, protocol, schema, opcode, decoder, dispatcher, `AgentChatState`, transcript lifecycle/cache, Go TUI, theme slot, asset, generated file, project configuration, new abstraction, dependency, API, compatibility path, or parallel state shape change.
- **Dependencies and constraints:** Existing `transcriptTruncated`, SwiftUI, ViewInspector, `ThemeColors`, and `Wire.ChatMessage` only. Preserve the dumb-renderer and State + View boundaries. Return `NEEDS_REPLAN` rather than exceeding either line ceiling or touching another file.
- **Implementation result:** Added the locked first `LazyVStack` child `if state.transcriptTruncated { olderMessagesOmittedIndicator }` before retained messages in `AgentChatView`, with the exact text-only private indicator copy, centered style, existing theme tokens, capsule fill/border, and accessibility label/hint. Added the locked positive and negative `AgentChatViewTests` using `AgentChatState.applyTranscript(... truncated: true/false ...)` with one retained `Hello` user message.
- **Failure reproduction:** Local Linux substitute per revised validation contract: `command -v xcodebuild` exited `1`, so Swift UI tests were not executable locally. Static pre-fix evidence before production edit: repository search of `AgentChatView.swift` found no `transcriptTruncated` read and no `Older messages omitted` copy, while the positive test asserted visible copy, retained `Hello`, and accessibility label, and the negative test asserted the indicator copy was absent while retained `Hello` remained.
- **Focused regression:** Local static post-fix inspection verified `if state.transcriptTruncated { olderMessagesOmittedIndicator }` is the first `LazyVStack` child before the retained-message `ForEach`; `olderMessagesOmittedIndicator` uses exact copy `Older messages omitted`, `.font(.system(size: 11, weight: .medium))`, `theme.agentMutedFg`, horizontal padding `10`, vertical padding `5`, `Capsule().fill(theme.agentCodeBg.opacity(0.75))`, `Capsule().strokeBorder(theme.agentCodeBorder.opacity(0.25), lineWidth: 1)`, centered frame, `.accessibilityElement(children: .ignore)`, label `Older messages omitted`, and hint `Earlier session messages are outside the locally retained transcript.`
- **Line budget:** Measured with `git diff --numstat -- macos/Sources/Views/Agent/AgentChatView.swift macos/Tests/MingaTests/SwiftUIViewTests.swift docs/workstreams/editor-lifecycle-roadmap.md`: `18 0 macos/Sources/Views/Agent/AgentChatView.swift`, `30 0 macos/Tests/MingaTests/SwiftUIViewTests.swift`, `32 0 docs/workstreams/editor-lifecycle-roadmap.md`. Production `+18 <= +22`; tests `+30 <= +34`.
- **Pre-acceptance reviews:** Correctness `PASS`; Swift craftsmanship `PASS`; native UI/accessibility design `PASS`; Ponytail `Lean already. Ship.`
- **Broad validation:** `mix swift.build` exited `0`, completed protocol generation, and printed `xcodebuild not found; skipping Swift build`; local Linux therefore did not execute Swift tests or the xcodebuild build smoke, and the macOS CI Swift job remains mandatory before merge. After `mix compile.minga_zig`, `mix test --seed 69814 --max-cases 4` passed 10,448 tests, including 58 doctests and 99 properties, with 0 failures, 1 skipped, and 210 excluded. The first branch run exposed an unrelated existing monitor-reason race in `Minga.Extension.LifecycleContractTest` (`:noproc` observed where the assertion expected `:killed`); the identical current-main SHA and seed passed, and the diagnosed branch rerun passed. `make lint` passed Credo, compile, format, and incremental Dialyzer with 0 errors. `git diff --check` passed.
- **Final reviewer:** `PASS`; visible/accessibility contract, state ownership, true/false regressions, locked scope, line budgets, validation evidence, and merge safety accepted with no findings.
- **PR URL:** https://github.com/jsmestad/minga/pull/3034
- **Implementation commit SHA:** `b0e5ee25c`
- **Merge evidence:** PR #3034 merged as `dc07dacc9300a58c9809f352a76d24fa551404cc` after CI run `29683366591` passed every required check, including Swift (macOS GUI), Swift protocol integration, Elixir, Go, Zig, Dialyzer, lint/format, Neovim conformance, boot smoke, and keystroke latency.
- **Completion date:** 2026-07-19

### W025: Validate omitted link and advisory color overrides

- **Status:** VERIFIED
- **Audit ID:** L29
- **Decision:** ACCEPT/direct
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `b233b970ad340c10612eb150ad0bd7278159d247`
- **Observable outcome:** Invalid nested `editor.link_fg` and `gutter.advisory_fg` overrides now raise the same exact color-validation errors as existing color fields, while valid non-negative integers land on `theme.editor.link_fg` and `theme.gutter.advisory_fg`.
- **Locked plan:** Add exactly `:link_fg` to `@color_fields.editor` after `:indent_guide_active_fg` and `:advisory_fg` to `@color_fields.gutter` after `:separator_fg`; extend only the existing nested valid override test and invalid override value shapes test; do not change Builder validation architecture, Theme structs, Loader, renderer, consumers, public APIs, dependencies, configuration, or data shapes.
- **Failure reproduction:** Before production changes, `mix run -e 'palette=%{variant: :dark, bg: 0x1E1E2E, fg: 0xCDD6F4, surface: 0x313244, overlay: 0x181825, muted: 0x6C7086, subtle: 0x45475A, highlight: 0x89B4FA, selection_bg: 0x585B70, error: 0xF38BA8, warning: 0xF9E2AF, info: 0x89B4FA, success: 0xA6E3A1, match: 0xF9E2AF, link: 0x89B4FA, border: 0x7F849C, contrast_fg: 0x1E1E2E, builtin: 0x94E2D5, functions: 0x89B4FA, keywords: 0xCBA6F7, methods: 0x89B4FA, operators: 0x89DCEB, constants: 0xFAB387, strings: 0xA6E3A1, numbers: 0xFAB387, type: 0xF9E2AF, variables: 0xCDD6F4, comments: 0x6C7086}; alias MingaEditor.UI.Theme.Builder; editor=Builder.from_palette(:palette_test, palette, %{editor: %{link_fg: :oops}}); gutter=Builder.from_palette(:palette_test, palette, %{gutter: %{advisory_fg: :oops}}); IO.inspect({editor.editor.link_fg, gutter.gutter.advisory_fg}, label: "escaped override values")'` printed `escaped override values: {:oops, :oops}` and exited `0`, proving invalid values escaped construction.
- **Implementation result:** `Theme.Builder` now treats the two existing struct fields as color override fields in the existing `@color_fields` metadata. The existing nested override test now asserts `editor.link_fg == 0x112233` and `gutter.advisory_fg == 0x445566`; the existing invalid-shapes test now asserts the exact `theme override editor.link_fg must be a color` and `theme override gutter.advisory_fg must be a color` errors.
- **Focused tests:** `mix test.debug test/minga_editor/ui/theme/builder_test.exs` passed with seed `996522`: `Result: 5 passed`.
- **Broad validation:** The scoped theme/consumer command passed 130 tests with 0 failures. `mix test.llm --seed 184212` exposed two `MingaAgent.SessionManagerTest` five-second timeouts at the default 64-way concurrency; the identical command reproduced both failures on unchanged current main, while the isolated 29-test session-manager module passed, confirming unrelated cross-suite load sensitivity. `mix test --max-cases 4` then passed 10,448 tests, including 58 doctests and 99 properties, with 0 failures, 1 skipped, and 210 excluded. `make lint` passed Credo, compile, format, and incremental Dialyzer with 0 errors.
- **Formatting:** `mix format lib/minga_editor/ui/theme/builder.ex test/minga_editor/ui/theme/builder_test.exs` exited `0`.
- **Line budget:** `git diff --numstat -- lib/minga_editor/ui/theme/builder.ex test/minga_editor/ui/theme/builder_test.exs` reported `4 2 lib/minga_editor/ui/theme/builder.ex` and `12 0 test/minga_editor/ui/theme/builder_test.exs`. Production net `+2 <= +2`; tests net `+12 <= +16`.
- **Production lines added/removed:** `4 added / 2 removed`
- **Test lines added/removed:** `12 added / 0 removed`
- **Concepts added/removed:** Added no new concept beyond two entries in the existing color-validation metadata; removed none.
- **Findings resolved:** L29 only.
- **Discoveries affecting later work:** None.
- **Ponytail verdict:** `Lean already. Ship.`
- **Bug-hunt verdict:** Correctness `PASS`; both metadata paths, valid and invalid contracts, optional nil default, consumer preservation, scope, budgets, and evidence accepted with no findings.
- **Elixir craftsmanship verdict:** `PASS`; the two ordered metadata entries and direct unit assertions are the smallest idiomatic extension of the existing validation flow.
- **Final reviewer verdict:** `PASS`; exact metadata scope, construction-time ownership, valid and invalid regressions, budgets, transparent validation evidence, and merge safety accepted with no findings.
- **PR URL:** https://github.com/jsmestad/minga/pull/3036
- **Implementation commit SHA:** `0347ab168`
- **Merge SHA:** `7fe6c648371c55cac81078636edefab77e6d85b1`; PR #3036 merged after CI run `29684733018` passed every required check, including Elixir, Swift, Go, Zig, Dialyzer, lint/format, Neovim conformance, boot smoke, protocol integration, and keystroke latency.
- **Completion date:** 2026-07-19

### W026: Make title metadata reads stale-buffer safe

- **Status:** VERIFIED
- **Audit ID:** L30
- **Decision:** ACCEPT/shrink
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Freshness commit SHA:** `fb382a47f7fd00fc4525ad2ed32131faafc3a25b`
- **Observable outcome:** Plain-map and `EditorState` terminal and GUI title formatting now survive stale stopped active-buffer pids. Dead buffers fall back to `[no file]`, empty filepath, empty directory, clean dirty marker, and the current mode where terminal formatting has a mode. Agent titles remain `Agent`, GUI punctuation remains unchanged, and live buffer formatting keeps the existing basename, directory, dirty, mode, special-buffer, and `bufname` behavior.
- **Locked implementation:** `MingaEditor.Title` owns one private `read_buffer_title_metadata/1` helper that reads only `Buffer.file_path/1`, `Buffer.buffer_name/1`, and `Buffer.dirty?/1`, catching only `{:noproc, {GenServer, :call, [^buf, _request, _timeout]}}` for the same buffer pid as `:dead_buffer`. Title context no longer carries filetype, agent context carries `filepath: ""`, plain-map GUI context delegates through `buffer_content_context/1`, both `build_vars/1` context branches consume `ctx.filepath`, `build_vars_from_buffer/2` uses the same helper, and the obsolete duplicate `buffer_filepath/1` helper is deleted. No public API, process, dependency, configuration, compatibility shim, or extra abstraction was added.
- **Regression reproduction:** With only the four dead-buffer regressions added, `mix test.debug test/minga_editor/title_test.exs` failed deterministically before the source correction. The run stopped after 3 failures: the plain-map terminal path exited from `GenServer.call(dead_pid, :file_path, 5000)` in `build_vars_from_buffer/2`; the `EditorState` terminal path exited from `Buffer.file_path/1` in `buffer_content_context/1`; and the `EditorState` GUI path exited from the same unguarded context read. Result before source correction: `8/11 passed`, `3 failed`, max-failures reached.
- **Focused tests:** `mix test.debug test/minga_editor/title_test.exs` passed after the mandatory Ponytail and Elixir corrections. Result: `20 passed`.
- **Broad validation:** `mix test.llm --seed 798303` exposed one unrelated five-second `MingaAgent.SessionManagerTest` timeout at the local default 64-way concurrency; the isolated 29-test module passed. The identical seed passed on unchanged current main, while a separate current-main default-concurrency run exposed a different unrelated two-second observatory timeout, confirming existing load sensitivity rather than title behavior. `mix test --max-cases 4` passed 10,452 tests, including 58 doctests and 99 properties, with 0 failures, 1 skipped, and 210 excluded. `make lint` passed Credo, compile, format, and incremental Dialyzer with 0 errors.
- **Formatting:** `mix format lib/minga_editor/title.ex test/minga_editor/title_test.exs` exited `0` for the implementation and again after the mandatory Elixir correction; `mix format test/minga_editor/title_test.exs` exited `0` after the mandatory Ponytail test simplification.
- **Line budget:** Final `git diff --numstat -- lib/minga_editor/title.ex test/minga_editor/title_test.exs docs/workstreams/editor-lifecycle-roadmap.md` reported `60 52 lib/minga_editor/title.ex` and `78 0 test/minga_editor/title_test.exs` before this evidence correction. Production net `+8 <= +25`; tests net `+78 <= +100`.
- **Production lines added/removed:** `60 added / 52 removed`
- **Test lines added/removed:** `78 added / 0 removed`
- **Concepts added/removed:** Added one private title metadata helper and one private fallback context shape inside the existing title owner. Removed title `filetype` context fields, both `Buffer.filetype/1` title reads, and the obsolete duplicate `buffer_filepath/1` read helper. Added no public API or external abstraction.
- **Findings resolved:** L30 only.
- **Discoveries affecting later work:** None.
- **Ponytail verdict:** Initial review required extracting repeated dead-buffer setup; after `dead_buffer!/0`, recheck returned `Lean already. Ship.`
- **Bug-hunt verdict:** Correctness `PASS`; same-buffer `:noproc` specificity, all four stale-buffer surfaces, live and agent behavior, synchronization, scope, budgets, and evidence accepted with no blockers.
- **Elixir craftsmanship verdict:** Initial review required consuming `ctx.filepath` in the agent branch; recheck `PASS` after the one-line correction.
- **Final reviewer verdict:** `PASS` after correcting the roadmap decision from `ACCEPT/direct` to the immutable audit classification `ACCEPT/shrink`; implementation, exception boundary, regressions, ownership, scope, budgets, and validation evidence accepted with no remaining findings.
- **PR URL:** https://github.com/jsmestad/minga/pull/3038
- **Implementation commit SHA:** `dff4592ef`
- **Merge SHA:** `c8805ecca0e3a9eabe082b21a1dac3fe25953118`; PR #3038 merged after CI run `29686552573` passed every required check, including Elixir, Swift, Go, Zig, Dialyzer, lint/format, Neovim conformance, boot smoke, protocol integration, and keystroke latency.
- **Completion date:** 2026-07-19

### W027: Delete retired 0x78 agent-chat messages section

- **Status:** VERIFIED
- **Audit ID:** D05
- **Decision:** ACCEPT/deletion
- **Planning profile:** `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`
- **Ready provenance:** Locked by `agent://D05Planner` with authoritative correction `local://d05-plan-correction.md`; the correction forbids protocol-version bumps, `docs/protocol_schema.toml` edits, and generated opcode edits because removing optional section `0x06` from sectioned `0x78` is compatible while `0x86` remains authoritative.
- **Freshness commit SHA:** `6682054397b37f64aad20c6b73884a8aa1c3073a`
- **Exact outcome:** `gui_agent_chat` (`0x78`) remains as sectioned chrome state, emits 8 visible sections, preserves section `0x09` input focus and every non-message section, skips retired well-formed section `0x06` on Swift and Go decode, and no longer carries or falls back to transcript messages. Agent transcript rendering is sourced only from resident `gui_agent_transcript` (`0x86`) state. The shared body codec/types required by `0x86` are retained.
- **Locked plan:** First update focused tests to establish section `0x06` absence/skip and resident-only behavior, then delete the 0x78 message producer/decoder/fallback path across the BEAM semantic model, builder, GUI encoder, Swift decoder/state/dispatcher/previews/tests, Go decoder/model/UI fallback/tests, `docs/GUI_PROTOCOL.md`, and this roadmap entry. Keep body codecs/types needed by `0x86`; do not change protocol version, schema, generated opcodes, other `0x78` sections, or `0x86`; add no shim/fallback/parallel shape.
- **Test and evidence plan:** Retain direct `0x86` transcript/body coverage, add BEAM assertions that visible `0x78` omits section `0x06`, add Swift and Go decoder skip/regression coverage for retired section `0x06`, add resident-only state/dispatcher/UI assertions, remove duplicated 0x78 payload tests, run focused Elixir and Go tests, run `mix protocol.gen --check`, run available Linux Swift static/build check, and record `xcodebuild` as unavailable locally.
- **Source-trace / pre-fix evidence:** Before deletion, source trace confirmed `AgentChatBuilder` constructed a capped `messages` tail for `0x78` beside the resident `0x86` suffix; `AgentChatEncoder` appended `@section_chat_messages 0x06` from `model.messages`; Swift `ProtocolDecoder` decoded `0x78` messages into `.guiAgentChat`, while `AgentChatState` kept a `rawMessages` update path; Go decoded `0x78` section `0x06` into `AgentChat.Messages` and `agent_chat_panel.go` fell back to that field when the resident store was empty. The new tests were written before production deletion; where executing the red Swift path was impossible on Linux, this source trace plus the removed decoder/fallback lines records the pre-fix behavior.
- **Implementation result:** Removed `messages` from the BEAM `AgentChat` render model and builder, removed `0x78` message encoding from `AgentChatEncoder`, kept `resident_messages` and `AgentChatMessageCodec` for retained `0x86` bodies, updated `GUI.encode_ui/2` dual emit to pair `0x78` chrome with `0x86` transcript only, removed Swift `guiAgentChat` message decoding and state update arguments, made the ordinary Swift 0x78 fixture carry all eight retained non-0x06 sections including completion/help while Swift continues to skip 0x09 input focus, made dedicated Swift/Go retired-0x06 skip fixtures use the exact former framed-v1 payload (`0xFF`, version 1, message_count u16, message_len u32 including id, message_id u32, typed body) between recognized sections, removed Swift preview/test seeding through chrome messages in favor of `applyTranscript`, removed Go chrome-message fallback/render arguments, made Go `0x86` retained known text/thinking/system/usage bodies require exact body consumption, made Go styled lines iterate exactly the declared count, made Swift `0x86` body strings strict UTF-8 through `readRequiredUTF8`/`readRequiredString16`, and added retained-body assertions for non-zero tool/status/error/result/run colors, approval status, usage, and markdown capability fields.
- **Focused validation:** `mix test test/minga/render_model/ui/agent_chat_test.exs test/minga/frontend/adapter/gui/agent_chat_encoder_test.exs test/minga/frontend/adapter/gui/agent_transcript_encoder_test.exs test/minga_editor/render_model/ui/agent_chat_builder_test.exs test/minga_editor/frontend/protocol_test.exs test/minga_editor/integration/gui_protocol_test.exs` passed: 205 tests, 24 excluded, 0 failures. `cd go/tui && go test ./internal/protocol ./internal/ui` passed both packages. `mix compile --warnings-as-errors` passed. `mix protocol.gen --check` passed. `mix swift.build` exited 0 and printed `xcodebuild not found; skipping Swift build`.
- **Formatting:** `mix format lib/minga/frontend/adapter/gui/agent_chat_encoder.ex lib/minga/frontend/adapter/gui/agent_transcript_encoder.ex lib/minga/render_model/ui/agent_chat.ex` ran for the touched Elixir moduledocs. `gofmt -w internal/protocol/chrome_agent.go internal/protocol/chrome_transcript_test.go internal/protocol/commands_test.go` ran from `go/tui` after the final Go decoder and test updates. Swift formatting was not run locally because this Linux workstation has no Swift formatter available.
- **Numstat:** Final `git diff --numstat` after this evidence update reported docs `35 added / 43 removed` in `docs/GUI_PROTOCOL.md`; production `205 added / 551 removed` (net `-346`, within production net `<= 0`); tests `789 added / 1440 removed` (net `-651`, within test net `<= +80`); roadmap evidence `27 added / 0 removed`. Per-file final numstat: `docs/GUI_PROTOCOL.md 35 43; docs/workstreams/editor-lifecycle-roadmap.md 27 0; go/tui/internal/protocol/chrome_agent.go 66 101; go/tui/internal/protocol/chrome_transcript.go 3 4; go/tui/internal/protocol/chrome_transcript_test.go 175 2; go/tui/internal/protocol/chrome_types.go 0 1; go/tui/internal/protocol/commands_test.go 25 139; go/tui/internal/ui/agent_chat_panel.go 10 12; go/tui/internal/ui/agent_transcript_render_test.go 0 5; go/tui/internal/ui/model.go 3 3; go/tui/internal/ui/model_test.go 23 23; lib/minga/config/options.ex 1 1; lib/minga/frontend/adapter/gui.ex 1 1; lib/minga/frontend/adapter/gui/agent_chat_encoder.ex 14 40; lib/minga/frontend/adapter/gui/agent_chat_message_codec.ex 3 21; lib/minga/frontend/adapter/gui/agent_transcript_encoder.ex 8 8; lib/minga/render_model/ui/agent_chat.ex 18 18; lib/minga_editor/agent/transcript.ex 1 1; lib/minga_editor/render_model/ui/agent_chat_builder.ex 1 84; macos/Sources/PreviewFixtures.swift 2 2; macos/Sources/PreviewRegistry+AgentChat.swift 17 12; macos/Sources/Protocol/ProtocolDecoder.swift 42 141; macos/Sources/Protocol/ProtocolTypes.swift 1 1; macos/Sources/Renderer/CommandDispatcher.swift 1 4; macos/Sources/Views/Agent/AgentChatState.swift 11 17; macos/TestHarness/main.swift 2 79; macos/Tests/MingaTests/CommandDispatcherTests.swift 10 10; macos/Tests/MingaTests/GUIChromeDecoderTests.swift 238 545; macos/Tests/MingaTests/StateLifecycleTests.swift 47 16; test/minga/frontend/adapter/gui/agent_chat_encoder_test.exs 24 432; test/minga/frontend/adapter/gui/agent_transcript_encoder_test.exs 219 4; test/minga/render_model/ui/agent_chat_test.exs 8 4; test/minga_editor/frontend/protocol_test.exs 5 99; test/minga_editor/integration/gui_protocol_test.exs 2 116; test/minga_editor/render_model/ui/agent_chat_builder_test.exs 13 45`.
- **Concepts removed:** Removed the BEAM `AgentChat.messages` field, the capped/windowed 0x78 transcript selection path, 0x78 section `0x06` encoder constant and payload builder, Swift 0x78 message decode/state/test-harness JSON plumbing, Go `AgentChat.Messages`, Go 0x78 message decoder, dead Go transcript-renderer chat arguments, and the TUI resident-store fallback to chrome messages.
- **Concepts added:** Added no new production concept, module, process, dependency, public API, configuration, protocol version, schema shape, generated opcode, registry, behavior, protocol, shim, or fallback. Tests add only resident-only/skip assertions for the retained 0x86 contract, direct/body-boundary coverage for live message kinds, chrome fingerprint assertions that resident transcript fields are ignored, exact former-0x06 framed skip fixtures, retained-field assertions, and malformed known-body rejection that protects retained `0x86` frames from partial/corrupt bodies and invalid UTF-8.
- **Remaining references:** Remaining `messages` identifiers are resident `0x86` transcript entries, bottom-panel messages, Swift `AgentChatState.messages` view state, preview/test seeding through `applyTranscript` or `seed`, and docs/tests that explicitly describe retired section `0x06` skip behavior. Targeted grep found no stale `AgentChat.messages`, `rawMessages`, `@section_chat_messages`, `section_chat_messages`, `decodeAgentMessages`, `decodeFramedChatMessages`, `decodeLegacyChatMessages`, `AgentChat.Messages`, `messages: Data?`, `inputFocused`, test-harness `chatMessageToJSON`, or 0x78 fallback/message-section producer path in the touched owners.
- **Findings resolved:** D05 only.
- **Discoveries affecting later work:** Linux cannot run `xcodebuild`, `swift`, or `swiftformat`; macOS CI must validate Swift compile/tests and formatting-sensitive issues. `mix swift.build` skipped cleanly because `xcodebuild` is missing. No schema drift was detected by `mix protocol.gen --check`.
- **Broad validation:** `make lint` passed Credo, compile, format, and incremental Dialyzer with 0 errors. The focused six-file Elixir suite passed 205 tests with 24 excluded, and the focused Go protocol/UI packages passed. The default-concurrency `mix test.llm --seed 100117` exposed a five-second `MingaAgent.SessionManager.list_sessions/0` timeout in unrelated introspection tests on two branch runs; each timed-out module passed alone, and unchanged current main passed the identical seed at default concurrency with 9,929 tests. The bounded-concurrency branch run `mix test.llm --seed 100117 --max-cases 4` passed 9,909 tests, including 58 doctests and 98 properties, with 0 failures, 1 skipped, and 575 excluded. Local Linux cannot execute Swift tests or the Xcode build; `mix swift.build` confirmed the required macOS CI handoff by exiting 0 with `xcodebuild not found; skipping Swift build`.
- **Pre-acceptance reviews:** Correctness and bug-hunt reviews returned `PASS/Lean` after correcting stale callers, retained protocol coverage, malformed-body handling, strict Swift UTF-8, and exact retired-section fixtures. Elixir craftsmanship returned `PASS`; Swift craftsmanship returned `PASS`/`Lean`; Go craftsmanship returned `PASS`; Ponytail returned `Lean already. Ship.` No unresolved pre-acceptance finding remains.
- **Final reviewer:** `PASS` after one targeted recheck corrected the roadmap-only numstat mismatch; implementation, retained `0x78` chrome, authoritative `0x86` ownership and coverage, Swift/Go skip paths, qualified validation, production/test budgets, and merge safety were accepted with no remaining finding.
- **PR URL:** https://github.com/jsmestad/minga/pull/3040; **Implementation commit SHA:** `66c388798`; **Merge SHA:** `58ea975d1db4ca6a51a13791563a74181586d729`; **Merge evidence:** PR #3040 merged after CI run `29692045875` passed Elixir, Swift macOS, Swift protocol integration, Go TUI, Zig, Dialyzer, lint/format, Neovim conformance, Go TUI boot smoke, and keystroke latency; **Completion date:** 2026-07-19.

### W028: Delete first D06 Protocol.GUI outbound parity oracles

- **Status:** VERIFIED
- **Audit ID:** D06.1
- **Decision:** ACCEPT/deletion, split first D06 slice
- **Planning profile:** `D06Planner`, `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `D06Worker`, `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`, one dedicated parent-authored worktree, no delegation
- **Ready provenance:** Locked by `agent://D06Planner` for current SHA `503adf031dd5c861c6d9ac271575d4bbedd8cccd`; D06 was split because full Protocol.GUI outbound parity cleanup spans multiple unrelated opcode families and test harness producers, while this first slice removes only the settings/search/preference parity-oracle encoders already owned by focused adapter encoders.
- **Freshness commit SHA:** `503adf031dd5c861c6d9ac271575d4bbedd8cccd`
- **Observable outcome:** `MingaEditor.Frontend.Protocol.GUI` no longer exposes `encode_gui_line_spacing/1`, `encode_gui_cursor_animation/1`, `encode_gui_search_state/4`, or `encode_gui_config_state/1`. Live production emission still goes through `Minga.Frontend.Adapter.GUI.LineSpacingEncoder`, `CursorAnimationEncoder`, `SearchStateEncoder`, and `ConfigStateEncoder`. Protocol.GUI still owns live clipboard write, settings projection and allowlist, search flag decoding, and `gui_action` decoding.
- **Failure reproduction / source trace:** Before deletion, `grep` showed the four outbound Protocol.GUI encoders and opcode attrs in `lib/minga_editor/frontend/protocol/gui.ex`, plus test-only callsites in `line_spacing_encoder_test.exs`, `cursor_animation_encoder_test.exs`, `search_state_encoder_test.exs`, `config_state_encoder_test.exs`, `gui_search_test.exs`, `gui_settings_test.exs`, and `gui_protocol_unit_test.exs`. No production caller used those four functions, while the planner trace identified the live adapter owners and retained Protocol.GUI surfaces.
- **Locked plan:** Delete only the four public outbound parity encoders, their exclusive private config encoders, and now-unused Protocol.GUI opcode attrs; update the ConfigStateEncoder owner comment; replace self-comparison tests with direct canonical adapter byte assertions; delete ProtocolGUI-only outbound tests; keep schema, protocol version, generated files, Swift, Go production, live clipboard write, settings projection/allowlist, search flag decoding, and gui_action decoding unchanged.
- **Implementation result:** Removed the four outbound Protocol.GUI encoders, `@op_gui_line_spacing`, `@op_gui_cursor_animation`, `@op_gui_config_state`, `@op_gui_search_state`, and the exclusive private config emit helpers `encode_config_option/2`, `encode_config_value/1`, `encode_theme_preview/1`, and `encode_keybinding_entry/1`. Updated adapter tests to assert `0x92`, `0x95`, `0x9E`, and `0x97` bytes directly from canonical encoders. Search-state tests now separately prove `match_count` and `current_index` `Writer.uint16` rejection with one invalid field per case. Config-state tests consume the payload after order-independent option parsing and assert the exact preview count/name/atom/RGB24 fields, keybinding count/mode/key/command/description fields, and empty remainder. Removed the obsolete ProtocolGUI search-state and protocol unit encode describes while retaining action decode, config projection, allowlist, and search flag tests.
- **Focused validation:** `mix test test/minga/frontend/adapter/gui/line_spacing_encoder_test.exs test/minga/frontend/adapter/gui/cursor_animation_encoder_test.exs test/minga/frontend/adapter/gui/search_state_encoder_test.exs test/minga/frontend/adapter/gui/config_state_encoder_test.exs test/minga/frontend/adapter/gui/protocol_golden_test.exs test/minga_editor/frontend/gui_search_test.exs test/minga_editor/frontend/protocol/gui_settings_test.exs test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs` passed after the mandatory review corrections: `143 passed`. Earlier post-edit validation exposed two search-state assertions that still expected zero flags despite `SearchState.case_sensitive` defaulting true; the corrected direct assertions now pin inactive false flags and active `0x02`.
- **Protocol/generated validation:** `mix protocol.gen --check` passed with no generated drift after the mandatory review corrections. `cd go/tui && go test ./internal/generated ./internal/protocol` passed both packages after the mandatory review corrections.
- **Formatting:** `mix format` ran on the touched Elixir files and tests, including the mandatory review correction tests. `mix format --check-formatted lib/minga_editor/frontend/protocol/gui.ex lib/minga/frontend/adapter/gui/config_state_encoder.ex test/minga/frontend/adapter/gui/line_spacing_encoder_test.exs test/minga/frontend/adapter/gui/cursor_animation_encoder_test.exs test/minga/frontend/adapter/gui/search_state_encoder_test.exs test/minga/frontend/adapter/gui/config_state_encoder_test.exs test/minga_editor/frontend/gui_search_test.exs test/minga_editor/frontend/protocol/gui_settings_test.exs test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs` passed after the mandatory review corrections.
- **Numstat before roadmap evidence:** `git diff --numstat -- lib/minga_editor/frontend/protocol/gui.ex lib/minga/frontend/adapter/gui/config_state_encoder.ex test/minga/frontend/adapter/gui/line_spacing_encoder_test.exs test/minga/frontend/adapter/gui/cursor_animation_encoder_test.exs test/minga/frontend/adapter/gui/search_state_encoder_test.exs test/minga/frontend/adapter/gui/config_state_encoder_test.exs test/minga_editor/frontend/gui_search_test.exs test/minga_editor/frontend/protocol/gui_settings_test.exs test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs` after the mandatory review corrections reported production `1 added / 159 removed` (net `-158`, within production net `<= 0`) and tests `97 added / 169 removed` (net `-72`, within tests net `<= +40`). Per-file: `lib/minga/frontend/adapter/gui/config_state_encoder.ex 1 2; lib/minga_editor/frontend/protocol/gui.ex 0 157; test/minga/frontend/adapter/gui/config_state_encoder_test.exs 53 8; test/minga/frontend/adapter/gui/cursor_animation_encoder_test.exs 0 10; test/minga/frontend/adapter/gui/line_spacing_encoder_test.exs 4 5; test/minga/frontend/adapter/gui/search_state_encoder_test.exs 37 61; test/minga_editor/frontend/gui_search_test.exs 0 48; test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs 0 36; test/minga_editor/frontend/protocol/gui_settings_test.exs 3 1`.
- **Concepts removed:** Removed the BEAM-side outbound parity oracle concept for `gui_line_spacing`, `gui_cursor_animation`, `gui_search_state`, and `gui_config_state`, including the obsolete ProtocolGUI search-state clamp oracle.
- **Concepts added:** Added no production concept, helper, facade, compatibility shape, module, process, dependency, behavior, registry, protocol, config flag, public API, schema shape, generated artifact, Swift path, or Go production path. Tests add only direct canonical adapter assertions replacing self-comparison or deleted ProtocolGUI-only assertions.
- **Remaining references:** Later D06 candidate slices still own the remaining ProtocolGUI outbound parity families such as theme, tab bar, workspaces, sidebars, file tree, which-key, status bar, minibuffer, hover/signature/float popups, notifications, extension overlays/panels, observatory, and tool manager. `encode_gui_extension_runtime/3` remains out of D06.1 because it overlaps a separate extension-runtime compatibility surface rather than the locked adapter-owned parity family.
- **Findings resolved:** D06 first slice only. Full D06 remains split; remaining D06 slices stay CANDIDATE until scoped against current main after this work merges.
- **Discoveries affecting later work:** Existing schema/Go golden coverage already covers `gui_search_state`, but not line spacing, cursor animation, or config state; later slices must not assume every ProtocolGUI parity family has generated golden coverage. Direct adapter assertions exposed the active-search default `case_sensitive: true`, so future replacements should assert owner defaults directly instead of inheriting old oracle expectations.
- **Broad validation:** `make lint` passed Credo, compile, format, and incremental Dialyzer with 0 errors after shortening the canonical-owner comment to satisfy the 120-column check. `mix test.llm` passed 9,896 tests, including 58 doctests and 98 properties, with 0 failures, 1 skipped, and 575 excluded. `cd go/tui && go test ./...` passed all seven tested packages with one package reporting no tests. `mix swift.build` confirmed the required macOS CI handoff by exiting 0 with `xcodebuild not found; skipping Swift build`; no Swift source changed.
- **Pre-acceptance reviews:** Correctness returned `PASS` after adding independent `match_count`/`current_index` rejection coverage and structurally consuming the complete config-state preview/keybinding payload. Elixir craftsmanship returned `PASS / Lean`; Ponytail returned `Lean already. Ship.` No unresolved pre-acceptance finding remains.
- **Final reviewer verdict:** `PASS` with 0.99 confidence. The reviewer confirmed the exact four-oracle deletion, retained live adapter and Protocol.GUI contracts, direct canonical wire assertions, no schema/generated/frontend drift, validation evidence, line budgets, and merge safety with no findings.
- **PR URL:** https://github.com/jsmestad/minga/pull/3042
- **Implementation commit SHA:** `f682f2958`
- **Merge SHA:** `44ecac3eee20a490c391ec92e18dff489fdaca80`; **Merge evidence:** PR #3042 merged after CI run `29693987703` passed Elixir, Swift macOS, Swift protocol integration, Go TUI, Zig, Dialyzer, lint/format, Neovim conformance, Go TUI boot smoke, and keystroke latency.
- **Completion date:** 2026-07-19.

### W029: Delete D06 float-popup Protocol.GUI outbound parity oracle

- **Status:** VERIFIED
- **Audit ID:** D06.2
- **Decision:** ACCEPT/deletion, second split D06 slice
- **Planning profile:** `D06Planner2`, `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `D06Worker2`, `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`, one dedicated parent-authored worktree, no delegation
- **Ready provenance:** Locked by `agent://D06Planner2` for current SHA `abe80c2d91c166227f77e908a05a8fe9fc475319`; D06.2 was split to remove only the float-popup outbound Protocol.GUI parity oracle after W028, because the live `gui_float_popup` producer is already the canonical adapter `Minga.Frontend.Adapter.GUI.FloatPopupEncoder` and all production frontend consumers decode the unchanged `0x83` wire command.
- **Freshness commit SHA:** `abe80c2d91c166227f77e908a05a8fe9fc475319`
- **Observable outcome:** `MingaEditor.Frontend.Protocol.GUI` no longer exposes the removed float-popup outbound encoder or its type, and `lib/minga_editor/frontend/protocol/gui.ex` no longer carries the unused float-popup opcode attr. The live `gui_float_popup` command remains emitted by `Minga.Frontend.Adapter.GUI.FloatPopupEncoder` from `Minga.RenderModel.UI.FloatPopup`; Swift and Go decoders, renderers, protocol schema, generated artifacts, docs, and `float_popup_dismiss` action decoding remain unchanged.
- **Failure reproduction / source trace:** Before deletion, repository search showed the removed float-popup outbound encoder and type defined only in `lib/minga_editor/frontend/protocol/gui.ex`, with test-only callsites in `test/minga/frontend/adapter/gui/float_popup_encoder_test.exs` and `test/minga_editor/frontend/gui_hover_protocol_test.exs`. No production caller used the legacy BEAM encoder, while `Minga.Frontend.Adapter.GUI.FloatPopupEncoder.encode/2` and `encode_command/1` already owned runtime bytes.
- **Locked plan:** Delete only the float-popup Protocol.GUI type, public outbound encoder, now-unused Protocol.GUI float-popup opcode attr, ProtocolGUI alias/self-comparisons in the adapter test, and obsolete ProtocolGUI float-popup describe block. Replace parity assertions with direct canonical full-byte assertions for hidden, visible multi-line, and empty-title popups. Preserve cache/fingerprint tests, hover popup, hover action, signature help, split separators, frontend consumers, schema, generated files, docs, opcode `0x83`, and `float_popup_dismiss` action decode behavior.
- **Implementation result:** Removed the Protocol.GUI float-popup outbound encoder/type/attr, removed the test-only legacy ProtocolGUI parity oracle, deleted the obsolete ProtocolGUI float-popup describe block, and added direct `FloatPopupEncoder.encode_command/1` full-byte assertions for hidden `<<0x83, 0>>`, visible `Inspect` with two lines, and visible empty-title `hello`.
- **Focused validation:** `mix test test/minga/frontend/adapter/gui/float_popup_encoder_test.exs test/minga_editor/frontend/gui_hover_protocol_test.exs test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs` passed with `88 passed`.
- **Reference validation:** Repository search for the removed encoder/type symbol names returned zero matches before this roadmap evidence was added. Focused search of `lib/minga_editor/frontend/protocol/gui.ex` for the removed float-popup opcode attr returned zero matches.
- **Protocol/generated validation:** `mix protocol.gen --check` passed with no generated drift. `cd go/tui && go test ./internal/generated ./internal/protocol` passed both focused Go protocol packages.
- **Formatting:** `mix format` ran on `lib/minga_editor/frontend/protocol/gui.ex`, `test/minga/frontend/adapter/gui/float_popup_encoder_test.exs`, and `test/minga_editor/frontend/gui_hover_protocol_test.exs`. `mix format --check-formatted lib/minga_editor/frontend/protocol/gui.ex test/minga/frontend/adapter/gui/float_popup_encoder_test.exs test/minga_editor/frontend/gui_hover_protocol_test.exs` passed.
- **Numstat before roadmap evidence:** `git diff --numstat -- lib/minga_editor/frontend/protocol/gui.ex test/minga/frontend/adapter/gui/float_popup_encoder_test.exs test/minga_editor/frontend/gui_hover_protocol_test.exs` reported production `0 added / 45 removed` (net `-45`, within production net `<= 0`) and tests `19 added / 47 removed` (net `-28`, within tests net `<= +40`).
- **Concepts removed:** Removed the BEAM-side outbound parity oracle concept for `gui_float_popup`, including its Protocol.GUI type and opcode attr.
- **Concepts added:** Added no production concept, helper, facade, compatibility shape, module, process, dependency, behavior, registry, protocol, config flag, public API, schema shape, generated artifact, Swift path, Go path, or data representation. Tests add only direct canonical adapter byte assertions replacing self-comparison and deleted ProtocolGUI-only assertions.
- **Remaining references:** Later D06 candidate slices still own hover popup, hover action, signature help, notifications, observatory, minibuffer, which-key, structural chrome, extension overlays/panels, and tool-manager/runtime surfaces as separately scoped in `agent://D06Planner2`. The `gui_float_popup` opcode, schema docs, Swift/Go consumers, and `float_popup_dismiss` action decoder remain live references by design, not parity-oracle leftovers.
- **Findings resolved:** D06.2 implementation slice only. Full D06 remains split; remaining D06 slices stay CANDIDATE until scoped against current main after this work merges.
- **Discoveries affecting later work:** Direct float-popup adapter assertions were sufficient to preserve hidden, visible multi-line, empty-title, and cache contracts without any Protocol.GUI oracle. No schema, generated, Swift, Go, or action-decoder drift was needed for this slice.
- **Broad validation:** `make lint` passed Credo, compile, format, and incremental Dialyzer with 0 errors. Default-concurrency `mix test.llm --seed 679823` stopped on one unrelated `MingaAgent.Providers.NativeMCPTest` timeout (`provider did not emit AgentEnd`); that exact test passed alone, and `mix test.llm --seed 679823 --max-cases 4` then passed 9,894 tests, including 58 doctests and 98 properties, with 0 failures, 1 skipped, and 575 excluded. `cd go/tui && go test ./...` passed all seven tested packages with one package reporting no tests. `mix swift.build` exited 0 with `xcodebuild not found; skipping Swift build`, preserving the required macOS CI handoff; no Swift source changed.
- **Pre-acceptance reviews:** Correctness returned `PASS / Lean` with no blockers and independently checked complete deleted-symbol absence, runtime/frontend/action retention, exact wire bytes, budgets, and roadmap evidence. Elixir craftsmanship returned `PASS/Lean`; Ponytail returned `Lean already. Ship.` The dedicated test-analysis agent was unavailable because its runtime had no model configured, so correctness review explicitly covered hidden, visible multi-line, empty-title, cache skip/re-emit, frontend decoder, and wire-format assertions instead. No unresolved pre-acceptance finding remains.
- **Final reviewer verdict:** `PASS` with 0.99 confidence. The reviewer confirmed the exact test-only oracle deletion, canonical full-byte and cache coverage, unchanged `0x83` schema/generated/frontend/action contracts, truthful qualified validation evidence, line budgets, and merge safety with no findings.
- **PR URL:** https://github.com/jsmestad/minga/pull/3044
- **Implementation commit SHA:** `005a29179`
- **Merge SHA:** `d79a97bfa865551ece0d3323a0c4c24c5c8ab7ef`; **Merge evidence:** PR #3044 merged after CI run `29695779502` passed Elixir, Swift macOS, Swift protocol integration, Go TUI, Zig, Dialyzer, lint/format, Neovim conformance, Go TUI boot smoke, and keystroke latency. The initial Elixir job and first rerun each exposed a different unrelated concurrency-only failure; both exact tests passed independently, and the final CI rerun passed the full required suite.
- **Completion date:** 2026-07-19.

### W030: Delete D06 assistance-popup Protocol.GUI outbound parity oracles

- **Status:** ACTIVE
- **Audit ID:** D06.3
- **Decision:** ACCEPT/deletion, third split D06 slice
- **Planning profile:** `D06Planner3`, `editor-lifecycle-planner`, `openai-codex/gpt-5.5`, `high`, read-only
- **Implementation profile:** `D06Worker3`, `editor-lifecycle-worker`, `openai-codex/gpt-5.5`, `medium`, one dedicated parent-authored worktree, no delegation
- **Ready provenance:** Locked by `agent://D06Planner3` for current SHA `d9519f4e0734c457668668455ae42427f276e5ad`; D06.3 removes only the hover popup, hover action sidecar, and signature help outbound Protocol.GUI parity oracles because runtime bytes are already owned by `Minga.Frontend.Adapter.GUI.HoverPopupEncoder` and `Minga.Frontend.Adapter.GUI.SignatureHelpEncoder`.
- **Freshness commit SHA:** `d9519f4e0734c457668668455ae42427f276e5ad`
- **Observable outcome:** `MingaEditor.Frontend.Protocol.GUI` no longer exposes `encode_gui_hover_popup/1`, `encode_gui_hover_action/1`, or `encode_gui_signature_help/1`, and no longer carries their Protocol.GUI-only opcode attrs or hover markdown helper block. Live `gui_hover_popup` `0x81`, `gui_hover_action` `0x96`, and `gui_signature_help` `0x82` emission remains in the canonical GUI adapter encoders. `hover_open_action` GUI action decode remains unchanged and covered.
- **Failure reproduction / source trace:** Before deletion, focused searches found the three public outbound encoders, the `@op_gui_hover_popup`, `@op_gui_signature_help`, and `@op_gui_hover_action` attrs, and the Protocol.GUI-local markdown helper block in `lib/minga_editor/frontend/protocol/gui.ex`. Callers were test-only self-comparisons or ProtocolGUI-only oracle tests in the four locked test files. No production caller used the legacy BEAM encoders, while the existing adapter encoders already emitted the runtime hover, hover action sidecar, and signature help bytes.
- **Locked plan:** Delete only the three Protocol.GUI outbound assistance-popup encoders, their now-unused opcode attrs, and the Protocol.GUI-exclusive hover helper block; replace adapter parity assertions with direct canonical byte assertions for hidden, no-action sidecar, focused/scrolled syntax with open action, syntax fallback, hidden signature help, visible signature help, and retained range rejection; delete only the obsolete ProtocolGUI describe blocks; preserve cache contracts, split separator tests, `hover_open_action` decode coverage, schema, generated files, Swift, Go, protocol version constants, frontend decoders, and all runtime producer surfaces.
- **Implementation result:** Removed the three Protocol.GUI assistance-popup parity oracles and their attrs/helpers from `lib/minga_editor/frontend/protocol/gui.ex`. `HoverPopupEncoderTest` now asserts the exact hidden bytes, visible no-action sidecar bytes, visible focused/scrolled syntax/open-action bytes, syntax fallback RGB/flags bytes, and cache re-emit behavior directly from the canonical encoder. `SignatureHelpEncoderTest` now asserts exact hidden and visible bytes directly from the canonical encoder and keeps the `EncodingError` active-signature range contract. ProtocolGUI-only hover popup, hover action, and signature help tests were deleted while split separator and `hover_open_action` decode tests were retained.
- **Focused validation:** `mix test test/minga/frontend/adapter/gui/hover_popup_encoder_test.exs test/minga/frontend/adapter/gui/signature_help_encoder_test.exs test/minga_editor/frontend/gui_hover_protocol_test.exs test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs` passed with seed `214665`: `82 passed`.
- **Reference validation:** Focused search over `lib/` and `test/` found zero `encode_gui_hover_popup`, `encode_gui_hover_action`, or `encode_gui_signature_help` code references after implementation. Focused search of `lib/minga_editor/frontend/protocol/gui.ex` found zero `@op_gui_hover_popup`, `@op_gui_signature_help`, `@op_gui_hover_action`, `encode_markdown_segment`, `encode_markdown_style`, `encode_syntax_flags`, or `encode_line_type` references after implementation. The retained canonical `HoverPopupEncoder` still has private markdown helper names by design because it is the live owner.
- **Protocol/generated validation:** `mix protocol.gen --check` passed with no generated drift. `cd go/tui && go test ./internal/generated ./internal/protocol` passed both focused Go packages.
- **Formatting:** `mix format lib/minga_editor/frontend/protocol/gui.ex test/minga/frontend/adapter/gui/hover_popup_encoder_test.exs test/minga/frontend/adapter/gui/signature_help_encoder_test.exs test/minga_editor/frontend/gui_hover_protocol_test.exs test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs` ran successfully. `mix format --check-formatted lib/minga_editor/frontend/protocol/gui.ex test/minga/frontend/adapter/gui/hover_popup_encoder_test.exs test/minga/frontend/adapter/gui/signature_help_encoder_test.exs test/minga_editor/frontend/gui_hover_protocol_test.exs test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs` passed.
- **Numstat before roadmap evidence:** `git diff --numstat -- lib/minga_editor/frontend/protocol/gui.ex test/minga/frontend/adapter/gui/hover_popup_encoder_test.exs test/minga/frontend/adapter/gui/signature_help_encoder_test.exs test/minga_editor/frontend/gui_hover_protocol_test.exs test/minga_editor/frontend/protocol/gui_protocol_unit_test.exs` reported production `0 added / 187 removed` (net `-187`, within production net `<= 0`) and tests `43 added / 267 removed` (net `-224`, within tests net `<= +40`).
- **Production lines added/removed:** `0 added / 187 removed`
- **Test lines added/removed:** `43 added / 267 removed`
- **Concepts removed:** Removed the BEAM-side outbound Protocol.GUI parity oracle concept for `gui_hover_popup`, `gui_hover_action`, and `gui_signature_help`, including their unused Protocol.GUI attrs and local markdown helper block.
- **Concepts added:** Added no production concept, helper, facade, compatibility shape, module, process, dependency, behavior, registry, protocol, config flag, public API, schema shape, generated artifact, Swift path, Go path, or data representation. Tests add only direct canonical adapter byte assertions replacing self-comparison or deleted ProtocolGUI-only assertions.
- **Remaining references:** The `gui_hover_popup`, `gui_hover_action`, `gui_signature_help`, and `hover_open_action` opcode/schema/frontend/generated references remain live by design. Later D06 candidate slices still own notifications, observatory, minibuffer, which-key, structural chrome, extension overlays/panels, and tool-manager/runtime surfaces.
- **Findings resolved:** D06.3 implementation slice only. Full D06 remains split; remaining D06 slices stay CANDIDATE until scoped against current main after this work merges.
- **Discoveries affecting later work:** The canonical hover popup adapter intentionally retains private helper names matching the deleted Protocol.GUI helpers, so later zero-reference checks for helper names should scope to `lib/minga_editor/frontend/protocol/gui.ex` unless the slice also retires the live adapter encoder.
- **Broad validation:** `make lint` passed Credo, compile, format, and incremental Dialyzer with 0 errors. `mix test.llm` passed 9,883 tests, including 58 doctests and 98 properties, with 0 failures, 1 skipped, and 575 excluded. `cd go/tui && go test ./...` passed all seven tested packages with one package reporting no tests. `mix swift.build` exited 0 with `xcodebuild not found; skipping Swift build`, preserving the required macOS CI handoff; no Swift source changed.
- **Pre-acceptance reviews:** Correctness returned `PASS / Lean` with 0.99 confidence after mapping the large deleted test surface to canonical adapter, builder, frontend, action, and schema coverage. Elixir craftsmanship returned `PASS/Lean`; Ponytail returned `Lean already. Ship.` The dedicated test-analysis agent was unavailable because its runtime had no model configured, so correctness review explicitly mapped every removed hidden, visible, sidecar, syntax, fallback, multiple-signature, range, cache, builder, and action contract to retained coverage. No unresolved pre-acceptance finding remains.
- **Final reviewer verdict:** `PASS` with 0.99 confidence. The reviewer confirmed the exact three-oracle deletion, retained canonical byte/cache/range/builder coverage, unchanged schema/generated/Swift/Go/action contracts, budgets, validation evidence, and merge safety with no findings.
- **PR URL:** https://github.com/jsmestad/minga/pull/3046
- **Implementation commit SHA:** `49d4fcd5b`
- **Merge SHA:** Pending.
- **Completion date:** Pending.

## Follow-on simplifications

### Remove Dired completely

- **Decision:** Approved for planning after the six-unit lifecycle goal
- **Outcome:** Delete the directory-buffer feature without replacement. Minga does not use or need it, and retaining it adds command, state, keymap, input, persistence, buffer-lifecycle, filesystem-mutation, and test complexity.
- **Deletion surface:** Remove `Minga.Dired`, `MingaEditor.Commands.Dired`, `MingaEditor.Input.Dired`, `MingaEditor.State.Dired`, the Dired keymap scope, command registry entries, `:dired` and `:oil` parser routes, leader bindings, Session/TabContext fields and transitions, BufferManagement special cases, tests, and user-facing documentation.
- **Cutover rule:** No deprecation, compatibility alias, disabled code path, retained state field, placeholder module, migration shim, or replacement abstraction.
- **Zero-trace acceptance:** The final deletion PR removes this follow-on entry too, then verifies the repository working tree has no `Dired`, `dired`, `dired_*`, `:dired`, or `:oil` feature references. Git history is the only retained record.
- **Preserve:** Ordinary file opening, file finder, file tree, buffer save/close, and generic buffer retirement behavior must continue without Dired-specific branches.
- **Planning requirement:** Inventory every producer and consumer against current main, lock deletion order and focused regression coverage, and fit the removal into reviewable dependency-ordered slices only if one PR cannot remain mechanically safe.
