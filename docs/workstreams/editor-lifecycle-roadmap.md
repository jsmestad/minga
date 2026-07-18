# Editor Lifecycle Execution Roadmap

This ledger turns six independently accepted findings from `FINDINGS.md` into small, current-main implementation slices. `FINDINGS.md` remains the immutable audit record. This file owns execution status, locked specifications, validation evidence, and discoveries made after the audit.

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

The cumulative target across W001 through W006 is net-neutral or net-negative production code.

## Status model

- **CANDIDATE:** An accepted finding that is not sufficiently specified.
- **READY:** The implementation shape, tests, boundaries, validation, and complexity budget are locked.
- **ACTIVE:** The unit is currently being implemented.
- **BLOCKED:** The unit requires a named decision or dependency.
- **VERIFIED:** The implementation PR merged and the ledger contains validation evidence.
- **DROPPED:** The unit is no longer appropriate, with a recorded rationale.

Queue rules:

- Only Ponytail `ACCEPT` findings may become implementation work.
- `ROUTE` findings require a recorded architecture decision before implementation.
- `PRESERVE` and `REJECT` findings cannot enter the implementation queue.
- A lower-cost implementation model executes only READY work.
- A planner or human promotes work to READY.
- One owner area may have only one READY or ACTIVE implementation at a time.
- Every implementation PR updates this ledger.
- A completed PR does not automatically promote the next candidate.
- Scope the next candidate against current main only after the preceding unit merges.
- A unit becomes VERIFIED only after merge.

## Definition of Ready

A candidate becomes READY only when every condition passes:

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

If any condition fails, keep the unit CANDIDATE or mark it BLOCKED.

## OMP orchestration contract

OMP task calls do not accept per-call model or thinking overrides. The repository-local profiles under `.omp/agents/` pin those choices so the controller cannot silently spend Sol on routine implementation.

| Responsibility | Agent | Model | Thinking | Access |
| --- | --- | --- | --- | --- |
| Lock one READY specification | `editor-lifecycle-planner` | `openai-codex/gpt-5.6-sol` | `xhigh` | Read-only |
| Implement one READY unit | `editor-lifecycle-worker` | `openai-codex/gpt-5.6-luna` | `high` | One worktree, no delegation |
| Ponytail or bug-hunt review | `editor-lifecycle-reviewer` | `openai-codex/gpt-5.6-luna` | `high` | Read-only |
| Elixir craftsmanship review | `elixir-architect` | Profile-owned Sol | `xhigh` | Read-only |
| Final acceptance | `reviewer` | Project profile | Project profile | Read-only |

### Planner

The planner promotes one candidate by returning a locked implementation specification. It verifies current source, callers, tests, ownership, and constraints. It may not edit or implement.

Use one task item:

```text
task(
  context: "Current roadmap unit, project rules, and freshness SHA",
  tasks: [
    {
      name: "W001Planner",
      agent: "editor-lifecycle-planner",
      task: "Verify one finding and return the locked READY specification"
    }
  ]
)
```

### Implementer

The worker executes one READY unit exactly as written, adds the locked tests, validates the observable outcome, and updates this ledger. It may not redesign architecture, ownership, persistence, protocols, or scope. It returns `NEEDS_REPLAN` instead of improvising when the specification is invalid.

### Adversarial review

After the first working diff and focused tests pass, launch independent read-only reviews in one task batch:

1. **Ponytail:** Falsify the smallest-correct-slice claim, count production and test deltas separately, and identify deletion, reuse, fake simplicity, or architecture questions.
2. **Bug hunt:** Inspect logic, state flow, process identity, races, stale messages, failure handling, silent fallthroughs, owner boundaries, and acceptance drift.
3. **Elixir craftsmanship:** Inspect changed Elixir source for canonical data shapes, pattern-matched control flow, owner APIs, fitting OTP primitives, types, and removable ceremony.
4. **Silent failure review:** Add `silent-failure-hunter` only when the diff changes error handling, recovery, fallback, catch, shutdown, persistence, or ignored-result behavior.

Send accepted fixes to the existing worker through `hub`; do not spawn a replacement worker. Reuse the same reviewers through `hub` for targeted rechecks. If a bug hunt finds a real correctness, data-loss, concurrency, rendering, security, or acceptance bug, run one additional broad bug hunt after the fix.

A unit cannot advance while Ponytail says `SHRINK`, the Elixir review reports a material non-idiomatic shape, or the bug hunt has an unresolved correctness finding. Architecture or contract changes return `NEEDS_REPLAN`.

Use the normal project reviewer once after all review fixes and required validation. A BLOCKED verdict permits one targeted re-review of the named blockers.

Do not use TaskExecute for planner or implementer work.

## Per-unit lifecycle

1. Synchronize with current `origin/main` and create a dedicated feature worktree.
2. Run one planner and record the freshness SHA.
3. Mark the unit ACTIVE and run one worker.
4. Run focused tests and measure production and test line deltas.
5. Run Ponytail, bug-hunt, and Elixir reviews in parallel.
6. Return accepted in-scope fixes to the existing worker.
7. Run required focused and broad validation.
8. Run the normal project reviewer.
9. Update evidence, commit, push, and open the implementation PR.
10. Merge after required checks, mark VERIFIED, synchronize main, then plan the next candidate.

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

- **Status:** READY
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

- **PR URL:** Pending
- **Commit SHA:** Pending
- **Merge SHA:** Pending
- **Focused tests:** Pending
- **Broad validation:** Pending
- **Ponytail verdict:** Pending
- **Bug-hunt verdict:** Pending
- **Elixir craftsmanship verdict:** Pending
- **Final reviewer verdict:** Pending
- **Production lines added/removed:** Pending
- **Test lines added/removed:** Pending
- **Concepts added/removed:** Pending
- **Findings resolved:** Pending
- **Discoveries affecting later work:** Pending
- **Completion date:** Pending

### W002: Failed saves prevent shutdown

- **Status:** CANDIDATE
- **Audit ID:** L02
- **Ponytail verdict:** `ACCEPT/direct`
- **Candidate outcome:** `:wq` and `:wqa` close or shut down only after every required save succeeds.
- **Existing direction:** Factor one internal tagged save result and short-circuit close or shutdown on failure. Reuse the existing save workflow rather than adding a service, behaviour, or generic result framework.
- **Readiness gap:** A fresh planner must reproduce current save sequencing, name the save-result owner and exact tagged shape, lock all callers and failure assertions, and separate L02 from the routed cross-tab inventory finding L03.
- **Allowed concepts before planning:** None.
- **Completion evidence:** Pending.

### W003: Dirty buffers require explicit destruction

- **Status:** CANDIDATE
- **Audit ID:** L04
- **Ponytail verdict:** `ACCEPT/direct`
- **Candidate outcome:** Ordinary buffer destruction refuses a dirty buffer with visible feedback; one explicit force path performs intentional destruction.
- **Existing direction:** Put the decision at the existing buffer-retirement command boundary. Do not add a confirmation framework, policy object, or parallel retirement API family.
- **Readiness gap:** A fresh planner must enumerate every command, keymap, mouse, GUI, and palette producer; lock the force command and feedback contract; and keep root buffer retirement ownership intact.
- **Allowed concepts before planning:** None.
- **Completion evidence:** Pending.

### W004: Dired targets its backing buffer

- **Status:** CANDIDATE
- **Audit ID:** L05
- **Ponytail verdict:** `ACCEPT/direct`
- **Candidate outcome:** Dired save and close operate only on the PID stored in Dired state, and Dired clears when that backing process dies.
- **Existing direction:** Require backing-buffer identity for save, retire that PID directly, and use the existing lifecycle cleanup path. Do not add a Dired process, buffer wrapper, or generic target resolver.
- **Readiness gap:** A fresh planner must reproduce stale scope or tab-switch behavior, name the Dired owner transition, trace buffer `:DOWN` cleanup, and lock tests for save, close, and process death.
- **Allowed concepts before planning:** None.
- **Completion evidence:** Pending.

### W005: Picker refresh rebuilds candidates

- **Status:** CANDIDATE
- **Audit ID:** L10
- **Ponytail verdict:** `ACCEPT/direct`
- **Candidate outcome:** Keep-open picker refresh replaces displayed items and normalized scoring candidates atomically while preserving query and valid selection.
- **Existing direction:** Reuse `Picker.replace_items/2`, then clamp selection through the existing picker owner. Do not add a refresh protocol, cache owner, or candidate abstraction.
- **Readiness gap:** A fresh planner must verify every `refresh_items/1` producer, lock the owner call sequence and selection edge cases, and name the cheapest pure picker tests plus any necessary Tool Manager wiring test.
- **Allowed concepts before planning:** None.
- **Completion evidence:** Pending.

### W006: Diagnostics picker uses current context

- **Status:** CANDIDATE
- **Audit ID:** L12
- **Ponytail verdict:** `ACCEPT/direct`
- **Candidate outcome:** Both registered diagnostics picker commands return diagnostics from the current `Picker.Context` instead of falling through to an empty result.
- **Existing direction:** Match the existing context shape and leave selection callbacks on full Editor state. Do not add another context adapter, source behaviour, or diagnostics projection.
- **Readiness gap:** A fresh planner must verify the current context fields, both command producers, exact diagnostic item shape, empty-state behavior, and the cheapest command-level regression test.
- **Allowed concepts before planning:** None.
- **Completion evidence:** Pending.

## Goal completion

The six-unit goal is complete only when W001 through W006 are VERIFIED after merge, every unit contains current evidence, no accepted review finding remains, cumulative production growth is recorded, and no unnecessary process, dependency, abstraction, wrapper, or parallel data shape was introduced.
