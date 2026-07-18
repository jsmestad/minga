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
