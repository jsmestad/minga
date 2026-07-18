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

- **Status:** ACTIVE
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
- **Merge SHA:** Pending
- **Completion date:** Pending

## Follow-on simplifications

### Remove Dired completely

- **Decision:** Approved for planning after the six-unit lifecycle goal
- **Outcome:** Delete the directory-buffer feature without replacement. Minga does not use or need it, and retaining it adds command, state, keymap, input, persistence, buffer-lifecycle, filesystem-mutation, and test complexity.
- **Deletion surface:** Remove `Minga.Dired`, `MingaEditor.Commands.Dired`, `MingaEditor.Input.Dired`, `MingaEditor.State.Dired`, the Dired keymap scope, command registry entries, `:dired` and `:oil` parser routes, leader bindings, Session/TabContext fields and transitions, BufferManagement special cases, tests, and user-facing documentation.
- **Cutover rule:** No deprecation, compatibility alias, disabled code path, retained state field, placeholder module, migration shim, or replacement abstraction.
- **Zero-trace acceptance:** The final deletion PR removes this follow-on entry too, then verifies the repository working tree has no `Dired`, `dired`, `dired_*`, `:dired`, or `:oil` feature references. Git history is the only retained record.
- **Preserve:** Ordinary file opening, file finder, file tree, buffer save/close, and generic buffer retirement behavior must continue without Dired-specific branches.
- **Planning requirement:** Inventory every producer and consumer against current main, lock deletion order and focused regression coverage, and fit the removal into reviewable dependency-ordered slices only if one PR cannot remain mechanically safe.
