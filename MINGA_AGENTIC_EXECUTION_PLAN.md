# Agentic Refactor: Parallel Execution Plan

This is the build plan for `MINGA_REFACTOR_TO_AGENTIC.md`. It organizes the ~40 PRs into parallel tracks that independent LLM workers can execute concurrently, with explicit merge points where tracks must synchronize before the next wave starts.

Each work unit below is a self-contained ticket: it names every file to touch, every file to read for context, the exact verification commands, and the constraints a cold-start worker needs to not break anything.

Read `MINGA_REFACTOR_TO_AGENTIC.md` for the full rationale behind each change. This document covers sequencing, parallelism, and worker scoping only.

---

## How to Read This Plan

**Waves** are groups of work that can run in parallel. All work in a wave must complete before the next wave starts.

**Tracks** within a wave are independent streams. Each track can be assigned to a different worker. Tracks within the same wave never touch the same files.

**Merge points** are gates between waves. At each merge point, all tracks from the previous wave must be merged to `main`, `make lint` must pass, and `mix test.llm` must pass on the combined result. No wave starts until its merge point is green.

**Worker context** sections list exactly what a cold-start LLM needs to read before writing code. Workers should not explore beyond these files unless they hit an unexpected compilation error.

---

## Wave 1: Foundation (3 parallel tracks)

No dependencies. All three tracks can start immediately on separate worktrees branching from current `main`.

### Track A: Sever Core Module Upward Dependencies (PRs 1.1, 1.2, 1.3)

**Goal:** Remove all `Minga.Editor` references from Buffer, LSP, Git, and Config modules.

**Why it matters:** After this track, these modules can function without an Editor process running. This is the prerequisite for headless mode and the API gateway.

**PR 1.1: Replace Editor.log_to_messages/log_to_warnings with Events**

Scope:
- Replace 4 calls in `LSP.Client` that call `Minga.Editor.log_to_warnings/1`
- Replace 1 call in `Git.Tracker` that calls `Minga.Editor.log_to_messages/1`
- Replace 1 call in `Agent.Session` that calls `Minga.Editor.log_to_messages/1`
- Add a `:log_message` event topic and `LogMessageEvent` payload struct to `Minga.Events`
- Subscribe the Editor to `:log_message` events and handle them

Files to read for context:
- `lib/minga/events.ex` (existing event topics, payload struct pattern, `subscribe/1`, `broadcast/2`)
- `lib/minga/lsp/client.ex` lines 260-270, 450-470, 600-610 (the 4 call sites)
- `lib/minga/git/tracker.ex` line 166 (the 1 call site)
- `lib/minga/agent/session.ex` line 1476 (the 1 call site)
- `lib/minga/editor.ex` lines 109-130 (existing `log_to_messages/log_to_warnings` implementations)
- `lib/minga/editor.ex` `handle_info` clauses (see how Editor subscribes to other events today)
- `AGENTS.md` the "Logging and the `*Messages*` Buffer" section (two-tier logging model)

Files to modify:
- `lib/minga/events.ex` — add `LogMessageEvent` defmodule, add `:log_message` to `@type topic` union, add to payload type union
- `lib/minga/lsp/client.ex` — replace 4 `Minga.Editor.log_to_warnings(msg)` with `Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{text: msg, level: :warning})`
- `lib/minga/git/tracker.ex` — replace 1 call with Events broadcast at `:info` level
- `lib/minga/agent/session.ex` — replace 1 call with Events broadcast at `:info` level
- `lib/minga/editor.ex` — add `Minga.Events.subscribe(:log_message)` in init/startup, add `handle_info` clause for `{:minga_event, :log_message, %LogMessageEvent{}}` that routes to `MessageLog.log_message/log_warning`

Constraints:
- The `LogMessageEvent` struct must use `@enforce_keys [:text, :level]`
- The `@type level` must be `:info | :warning | :error`
- Do NOT remove `Editor.log_to_messages/1` or `Editor.log_to_warnings/1` public functions yet. Other callers inside the editor layer may still use them. Just stop core modules from calling them.
- The Editor's `handle_info` for `:log_message` must produce the same behavior as the direct calls did (`:warning` level goes to `log_warning`, others to `log_message`)

Testing:
- Existing tests must pass unchanged. The behavior is identical; only the call path changes.
- Verify with: `grep -rn "Minga\.Editor" lib/minga/lsp/client.ex lib/minga/git/tracker.ex lib/minga/agent/session.ex` should return 0 results.
- `make lint && mix test.llm`

**PR 1.2: Replace Buffer.Server's Editor notification with Events**

Scope:
- Replace `Process.whereis(Minga.Editor)` in `Buffer.Server` line 1903 with an Events broadcast
- Subscribe the Editor to the new event (or reuse existing `:buffer_changed` topic)

Files to read for context:
- `lib/minga/buffer/server.ex` lines 1895-1915 (the `Process.whereis` call and surrounding context)
- `lib/minga/events.ex` (existing `BufferChangedEvent` struct, understand if it fits or if a new topic is needed)
- `lib/minga/editor.ex` — search for `face_overrides_changed` to find the existing handler

Files to modify:
- `lib/minga/buffer/server.ex` — replace the `Process.whereis` block with `Minga.Events.broadcast/2`. Decide: if `BufferChangedEvent` with a specific source is sufficient, use it. If the Editor needs to distinguish face override changes from content changes, add a new `:face_overrides_changed` topic and `FaceOverridesChangedEvent` struct.
- `lib/minga/events.ex` — add new event topic/struct if needed
- `lib/minga/editor.ex` — subscribe to the event and handle it

Constraints:
- The Editor must still learn about face override changes. The behavior must be identical.
- If adding a new event topic, follow the exact pattern of existing topics (struct with `@enforce_keys`, added to `@type topic` union).

Testing:
- `grep -rn "Minga\.Editor" lib/minga/buffer/` should return 0 results.
- `make lint && mix test.llm`

**PR 1.3: Fix Config.Advice docstring**

Scope:
- Line 41 of `config/advice.ex` has a docstring example referencing `Minga.Editor.State.set_status`. Replace with a generic example.

Files to modify:
- `lib/minga/config/advice.ex` — change the docstring example only

Constraints:
- Docstring change only. Zero behavioral change.

Testing:
- `grep -rn "Minga\.Editor" lib/minga/config/` should return 0 results.
- `make lint`

Track A verification (all 3 PRs merged):
```bash
grep -rn "Minga\.Editor" lib/minga/buffer/ lib/minga/events.ex lib/minga/config/ \
  lib/minga/lsp/ lib/minga/git/ --include="*.ex" | wc -l
# Expected: 0
make lint && mix test.llm
```

---

### Track B: Tool Registry and Executor (PRs 2.1, 2.2, 2.3)

**Goal:** Create a Minga-native tool system alongside the existing `ReqLLM.Tool`-based system. New code only; no existing modules change (except PR 2.4 which wires it in, but that moves to Wave 2 because it depends on the registry being supervised).

**Why it matters:** The tool registry is required by the Agent Runtime facade (Phase 6) and the API gateway (Phase 7). Building it now, in parallel with the decoupling work, saves calendar time.

**PR 2.1: Create Tool.Spec struct**

Scope:
- New file `lib/minga/agent/tool/spec.ex`
- Pure data struct. No GenServer, no ETS, no process.

Files to read for context:
- `lib/minga/agent/tools.ex` lines 1-80 (existing tool structure, `ReqLLM.Tool` usage)
- `lib/minga/agent/tools/read_file.ex` (example of an existing tool implementation, to understand the callback shape)
- Any one `ReqLLM.Tool.new!` call in `lib/minga/agent/tools.ex` (to see the fields)

Files to create:
- `lib/minga/agent/tool/spec.ex` — struct with `@enforce_keys [:name, :description, :parameter_schema, :callback]`, fields for `destructive`, `category`, `requires_project`. Include `to_req_llm/1` conversion function.

Constraints:
- The `callback` type must be `(map() -> {:ok, term()} | {:error, term()})` matching how existing tools return results
- `category` type: `:buffer | :file | :git | :lsp | :shell | :runtime | :general`
- Include `@moduledoc`, `@spec` on `to_req_llm/1`

Testing:
- Create `test/minga/agent/tool/spec_test.exs` — test struct creation, `to_req_llm/1` conversion, enforce_keys validation
- `make lint && mix test test/minga/agent/tool/spec_test.exs`

**PR 2.2: Create Tool.Registry (ETS-backed GenServer)**

Scope:
- New file `lib/minga/agent/tool/registry.ex`
- GenServer that owns an ETS table with `read_concurrency: true`
- At `init/1`, populates from `Minga.Agent.Tools.all/1` by converting each `ReqLLM.Tool` to a `Tool.Spec`

Files to read for context:
- `lib/minga/agent/tools.ex` (the `all/1` function that returns `[ReqLLM.Tool.t()]`)
- `lib/minga/config/advice.ex` (example of ETS-backed GenServer with read_concurrency pattern)
- `lib/minga/services/independent.ex` (where to add the child spec later, in Wave 2)

Files to create:
- `lib/minga/agent/tool/registry.ex` — GenServer with `register/1`, `lookup/1`, `all/0`, `all_as_req_llm/0`, `unregister/1`. Table name parameterizable for tests.

Constraints:
- The ETS table name must be parameterizable (pass `:table` option to `start_link`) for test isolation
- `register/1` must be idempotent (re-registering same name overwrites)
- `all_as_req_llm/0` must call `Tool.Spec.to_req_llm/1` on each spec
- Do NOT add to supervision tree yet (that's PR 2.4 in Wave 2, since it touches `services/independent.ex` which Track A may also touch)

Testing:
- Create `test/minga/agent/tool/registry_test.exs` — use `start_supervised!` with custom table name
- Test: register, lookup, all, unregister, re-register overwrites, lookup missing returns `:error`
- `make lint && mix test test/minga/agent/tool/registry_test.exs`

**PR 2.3: Create Tool.Executor**

Scope:
- New file `lib/minga/agent/tool/executor.ex`
- Pure module (no GenServer). Looks up tool from registry, validates args against JSON schema, executes callback.

Files to read for context:
- `lib/minga/agent/tool/registry.ex` (the `lookup/1` function you just created)
- `lib/minga/agent/tools.ex` `destructive?/1` function (approval checking pattern)
- `lib/minga/config/advice.ex` (the `wrap/2` function for advice chain)

Files to create:
- `lib/minga/agent/tool/executor.ex` — `execute/3` function

Constraints:
- `execute/3` returns `{:ok, term()} | {:error, term()} | {:needs_approval, Tool.Spec.t()}`
- Approval check: if `spec.destructive` is true and no `:approved` option passed, return `{:needs_approval, spec}`
- Arg validation: check required keys from `parameter_schema` exist in the args map (basic validation, not full JSON Schema)

Testing:
- Create `test/minga/agent/tool/executor_test.exs` — register a test tool, execute it, verify approval gating, verify error paths
- `make lint && mix test test/minga/agent/tool/`

Track B verification (all 3 PRs merged):
```bash
# New files compile clean with no warnings:
mix compile --warnings-as-errors 2>&1 | grep -i "tool/spec\|tool/registry\|tool/executor"
make lint && mix test test/minga/agent/tool/
```

---

### Track C: Buffer RefTracker (PR 3.1)

**Goal:** Add reference counting infrastructure for buffer processes. Tracking only; no behavior change to buffer lifecycle.

**Why it matters:** Required by the API gateway (to list buffers) and buffer forking (Phase 9). Starting it now in parallel costs nothing because it's a new, additive GenServer.

**PR 3.1: Create Buffer.RefTracker GenServer**

Scope:
- New file `lib/minga/buffer/ref_tracker.ex`
- ETS-backed GenServer tracking `{path, holder_pid, ref_count}`
- Monitor holder PIDs so refs are auto-released if the holder crashes

Files to read for context:
- `lib/minga/buffer.ex` (entry point, `ensure_for_path/1`, `pid_for_path/1`)
- `lib/minga/buffer/server.ex` lines 1830-1850 (Registry.register/unregister pattern)
- `lib/minga/config/advice.ex` (ETS-backed GenServer pattern with parameterizable table name)

Files to create:
- `lib/minga/buffer/ref_tracker.ex` — GenServer with:
  - `acquire(path, holder_pid)` — increment ref for `{path, holder_pid}`, monitor holder
  - `release(path, holder_pid)` — decrement ref, demonitor if count reaches 0
  - `ref_count(path)` — total refs across all holders
  - `holders(path)` — list of `{holder_pid, count}` tuples
  - `all_info()` — returns `[%{path: String.t(), pid: pid() | nil, ref_count: non_neg_integer()}]` (pid looked up from `Minga.Buffer.Registry`)
  - `handle_info({:DOWN, ...})` — auto-release all refs for crashed holder

Constraints:
- ETS table name must be parameterizable for tests
- Do NOT wire into `Buffer.ensure_for_path` yet (that's Wave 2, PR 3.2)
- Do NOT add to supervision tree yet (Wave 2)
- Do NOT auto-terminate buffers when refcount hits 0. Just track.
- `all_info/0` must look up PIDs from the existing `Minga.Buffer.Registry` to include them in the info

Testing:
- Create `test/minga/buffer/ref_tracker_test.exs`, `async: true`
- Use `start_supervised!` with custom table name
- Test: acquire increments, release decrements, DOWN auto-releases, multiple holders tracked independently, `all_info` returns correct shape
- `make lint && mix test test/minga/buffer/ref_tracker_test.exs`

Track C verification:
```bash
make lint && mix test test/minga/buffer/ref_tracker_test.exs
```

---

### Wave 1 Merge Point

**Gate:** All three tracks (A, B, C) merge to `main`. Run:
```bash
make lint && mix test.llm
```

Verification that Track A succeeded:
```bash
grep -rn "Minga\.Editor" lib/minga/buffer/ lib/minga/events.ex lib/minga/config/ \
  lib/minga/lsp/ lib/minga/git/ --include="*.ex" | wc -l
# Must be 0
```

---

## Wave 2: Integration and Agent Decoupling (3 parallel tracks)

Depends on: Wave 1 complete.

### Track D: Wire New Infrastructure into Supervision Tree (PRs 2.4, 3.2, 3.3, 4.1)

**Goal:** Integrate the Tool.Registry and Buffer.RefTracker into the running system. Promote Agent.Supervisor to a top-level peer.

**PR 2.4: Add Tool.Registry to supervision tree, wire Native provider**

Scope:
- Add `Minga.Agent.Tool.Registry` as a child of `Services.Independent`
- Change `Providers.Native` to get tools from `Tool.Registry.all_as_req_llm()` instead of `Tools.all/1`

Files to read for context:
- `lib/minga/services/independent.ex` (children list, ordering)
- `lib/minga/agent/providers/native.ex` — search for `Tools.all` to find the one-line change site
- `lib/minga/agent/tool/registry.ex` (the module you're wiring in)

Files to modify:
- `lib/minga/services/independent.ex` — add `Minga.Agent.Tool.Registry` to children list (after `Minga.Command.Registry`, before `Minga.Diagnostics` or at the end)
- `lib/minga/agent/providers/native.ex` — replace `Tools.all(project_root: project_root)` with `Tool.Registry.all_as_req_llm()`
- Update `Services.Supervisor` moduledoc and `Application` moduledoc supervision tree comments

Constraints:
- The registry must start before `Agent.Supervisor` in the tree (it does, since Independent starts before Agent.Supervisor)
- `Tool.Registry.init/1` calls `Tools.all/1` to seed itself, so it needs Foundation (Config.Options) to be up. This is guaranteed by the supervisor ordering.

Testing:
- Start an IEx session: `iex -S mix` and verify `Minga.Agent.Tool.Registry.all() |> length()` returns the expected tool count
- `make lint && mix test.llm`

**PR 3.2: Wire Buffer.RefTracker into supervision tree and Buffer.ensure_for_path**

Scope:
- Add `Minga.Buffer.RefTracker` to supervision tree (as a child of the top-level `Minga.Supervisor`, after `Buffer.Supervisor` and before `Services.Supervisor`)
- Wire `Buffer.ensure_for_path/1` to call `RefTracker.acquire/2` with `self()` as holder
- Wire `Editor.BufferLifecycle` tab-close to call `RefTracker.release/2`

Files to read for context:
- `lib/minga/application.ex` lines 55-100 (top-level supervisor children)
- `lib/minga/buffer.ex` `ensure_for_path/1` function
- `lib/minga/buffer/ref_tracker.ex` (the module you're wiring in)
- `lib/minga/editor/buffer_lifecycle.ex` or wherever tab close triggers buffer cleanup (search for `buffer_closed` or `close_tab` in `lib/minga/editor/`)

Files to modify:
- `lib/minga/application.ex` — add `Minga.Buffer.RefTracker` to base_children
- `lib/minga/buffer.ex` — in `ensure_for_path/1`, after getting the pid, call `RefTracker.acquire(abs_path, self())`
- Editor tab close path — add `RefTracker.release(path, self())` call

Constraints:
- `RefTracker` must start after `Buffer.Registry` and `Buffer.Supervisor` (it reads from the registry)
- The `self()` in `ensure_for_path` will be the caller (agent tool process, editor, etc.), which is the correct holder

Testing:
- `make lint && mix test.llm`
- In IEx: open a file, check `Minga.Buffer.RefTracker.all_info()` shows it with ref_count >= 1

**PR 3.3: Expose buffer listing through RefTracker**

Scope:
- Add `list_buffers/0` to `Minga.Buffer` entry point, delegating to `RefTracker.all_info/0`

Files to modify:
- `lib/minga/buffer.ex` — add `@spec list_buffers() :: [map()]` and `defdelegate list_buffers(), to: Minga.Buffer.RefTracker, as: :all_info`

Testing:
- `make lint`

**PR 4.1: Promote Agent.Supervisor to top-level peer**

Scope:
- Remove `Minga.Agent.Supervisor` from `Services.Supervisor` children
- Add it to the top-level `Minga.Supervisor` children in `application.ex`, after `Services.Supervisor`

Files to read for context:
- `lib/minga/services/supervisor.ex` (current children list, the `rest_for_one` implications documented in the moduledoc)
- `lib/minga/application.ex` (top-level children list)
- `MINGA_REFACTOR_TO_AGENTIC.md` Phase 4 section (the `rest_for_one` cascade analysis)

Files to modify:
- `lib/minga/services/supervisor.ex` — remove `Minga.Agent.Supervisor` from children list, update moduledoc
- `lib/minga/application.ex` — add `Minga.Agent.Supervisor` to `base_children` after `Services.Supervisor`, update supervision tree diagram in moduledoc

Constraints:
- With `rest_for_one` at the top level: Agent.Supervisor must come after Services.Supervisor (it depends on Foundation, Buffer, and Services). It must come before Runtime.Supervisor (so a Runtime crash doesn't kill agents).
- The ordering must be: Foundation → Buffer.Registry → Buffer.Supervisor → Buffer.RefTracker → Services → Agent.Supervisor → Runtime → SystemObserver

Testing:
- `make lint && mix test.llm`
- In IEx: `Supervisor.which_children(Minga.Supervisor) |> Enum.map(&elem(&1, 0))` to verify Agent.Supervisor appears at the expected position
- Verify agent sessions still work: start Minga, open agent, send a message

---

### Track E: Split Agent.Events (PR 1.4)

**Goal:** Split `Agent.Events` into a domain-only `Agent.EventHandler` (no Editor deps) and a presentation-only `Agent.Events` (thin wrapper that still takes EditorState).

**Why it matters:** This is the single hardest PR in the entire plan. It severs the deepest coupling point between the agent and editor layers. Everything in Phases 5 and 6 depends on this being done correctly.

**PR 1.4: Split Agent.Events into domain and presentation**

Files to read carefully (all of these, in full):
- `lib/minga/agent/events.ex` (all 408 lines, understand every handler)
- `lib/minga/editor/state/agent.ex` (the `AgentState` struct, 150 lines)
- `lib/minga/editor/state/agent_access.ex` (the accessor module, 131 lines)
- `lib/minga/agent/ui_state.ex` (the UIState struct, first 100 lines for field layout)
- `lib/minga/agent/ui_state/panel.ex` (first 50 lines for struct shape)
- `lib/minga/agent/ui_state/view.ex` (first 50 lines for struct shape)
- `lib/minga/editor.ex` — search for `Agent.Events.handle` to see how the editor calls into this module (around line 687)

The split:
1. Create `lib/minga/agent/event_handler.ex` — takes `UIState.t()` and an event, returns `{UIState.t(), [domain_effect()]}`. Domain effects are atoms/tuples like `:render`, `{:log_message, text}`, `:sync_agent_buffer`. This module must have ZERO aliases to anything under `Minga.Editor.*`.
2. Narrow `lib/minga/agent/events.ex` to a thin wrapper: extract `UIState` from `EditorState` via `AgentAccess`, call `EventHandler.handle/2`, put updated `UIState` back, then apply presentation effects (tab label sync, spinner timer start/stop, Board card status sync).

What goes into `EventHandler` (domain):
- Agent status transitions (`:idle`, `:thinking`, `:tool_executing`, `:error`)
- Streaming delta appending to chat content
- Tool call tracking (start, progress, complete, error)
- Auto-scroll engagement on `:thinking`
- Error message construction

What stays in `Events` (presentation):
- Tab label updates (`sync_tab_agent_status`, `update_tab_label`)
- Spinner timer start/stop (`AgentState.start_spinner_timer/stop_spinner_timer`)
- Board card status sync
- Any direct `EditorState` field mutations not on `UIState`

Files to create:
- `lib/minga/agent/event_handler.ex`

Files to modify:
- `lib/minga/agent/events.ex` (narrow to wrapper)

Constraints:
- `EventHandler` must produce IDENTICAL domain state changes as the current `Events` module. This is a refactor, not a behavior change.
- `EventHandler` must not alias/import/reference anything under `Minga.Editor.*`
- The existing `Events.handle/2` signature (`(EditorState.t(), term()) -> {EditorState.t(), [effect()]}`) must not change. The Editor calls it the same way.
- Keep the existing `@type effect` in `Events`. Add a new `@type domain_effect` in `EventHandler`.

Testing:
- All existing agent-related tests must pass unchanged
- Verify: `grep -rn "Minga\.Editor" lib/minga/agent/event_handler.ex` returns 0 results
- Create `test/minga/agent/event_handler_test.exs` — test each event type by constructing a `UIState.new()`, calling `EventHandler.handle/2`, and asserting on the returned UIState and effects. These are pure function tests (no GenServer needed).
- `make lint && mix test.llm`

Risk mitigation:
- If snapshot tests exist for the agent chat panel, run them and compare before/after
- Manually test: start editor, open agent, send a prompt, verify streaming works, verify tool calls render, verify errors display

---

### Track F: Move Presentation Modules to Editor Layer (PRs 1.5, 1.6)

**Goal:** Move `Agent.SlashCommand` and `Agent.ViewContext`/`Agent.View.*` to the editor layer where they belong.

**PR 1.5: Move Agent.SlashCommand to editor layer**

Files to read for context:
- `lib/minga/agent/slash_command.ex` (all 791 lines, understand the module structure)
- `lib/minga/agent/slash_command/command.ex` (the Command struct)
- `lib/minga/editor/commands/agent.ex` (the primary caller, lines 208-220)
- `lib/minga/editor/commands/agent_sub_states.ex` line 153 (another caller)

The move:
1. Move `lib/minga/agent/slash_command.ex` to `lib/minga/editor/commands/agent_slash.ex`
2. Rename module from `Minga.Agent.SlashCommand` to `Minga.Editor.Commands.AgentSlash`
3. Move `lib/minga/agent/slash_command/command.ex` to `lib/minga/editor/commands/agent_slash/command.ex`
4. Leave a defdelegate bridge at the old path: `lib/minga/agent/slash_command.ex` becomes a thin module with `defdelegate` for every public function
5. Update direct callers (`editor/commands/agent.ex`, `editor/commands/agent_sub_states.ex`) to use the new module name

Files to create:
- `lib/minga/editor/commands/agent_slash.ex` (moved + renamed)
- `lib/minga/editor/commands/agent_slash/command.ex` (moved + renamed)

Files to modify:
- `lib/minga/agent/slash_command.ex` (replace with defdelegate bridge)
- `lib/minga/editor/commands/agent.ex` (update alias)
- `lib/minga/editor/commands/agent_sub_states.ex` (update alias)

Constraints:
- The defdelegate bridge must cover every public function so nothing breaks
- Don't restructure SlashCommand internals. Move only. Restructuring comes later.

Testing:
- All existing tests must pass unchanged
- If `test/minga/agent/slash_command_test.exs` exists, move to `test/minga/editor/commands/agent_slash_test.exs` and update the module reference
- `make lint && mix test.llm`

**PR 1.6: Move Agent.ViewContext and Agent.View.* to editor layer**

Files to read for context:
- `lib/minga/agent/view_context.ex` (43 lines of aliases, the `from_editor_state/1` function)
- `lib/minga/agent/view/` directory listing (all renderer modules)
- `lib/minga/agent/diff_renderer.ex`
- `lib/minga/editor/render_pipeline/content.ex` line 269 (where ViewContext is constructed)
- `lib/minga/input/agent_mouse.ex` line 227 (another caller)

The move:
1. Move `lib/minga/agent/view_context.ex` to `lib/minga/editor/agent/view_context.ex`
2. Move `lib/minga/agent/view/` to `lib/minga/editor/agent/view/`
3. Move `lib/minga/agent/diff_renderer.ex` to `lib/minga/editor/agent/diff_renderer.ex`
4. Rename all modules from `Minga.Agent.ViewContext` to `Minga.Editor.Agent.ViewContext`, etc.
5. Leave defdelegate bridges at old paths
6. Update callers: `editor/render_pipeline/content.ex`, `input/agent_mouse.ex`

Constraints:
- Do NOT move `lib/minga/agent/ui_state.ex` or `lib/minga/agent/ui_state/`. UIState is domain state; it stays in the agent layer.
- The view modules will still reference `UIState` which is fine (editor layer depending on agent layer is the correct direction... wait, no. Editor is Layer 2, Agent is Layer 1. Layer 2 depending on Layer 1 is correct.)

Testing:
- All tests pass unchanged
- `make lint && mix test.llm`

---

### Wave 2 Merge Point

**Gate:** Tracks D, E, F all merge to `main`. Run:
```bash
make lint && mix test.llm
```

Verification:
```bash
# Agent domain modules have zero Editor refs:
grep -rn "Minga\.Editor" lib/minga/agent/session.ex lib/minga/agent/provider.ex \
  lib/minga/agent/providers/ lib/minga/agent/tools/ lib/minga/agent/event_handler.ex \
  --include="*.ex" | wc -l
# Must be 0

# Agent.Supervisor is a top-level peer:
# Check application.ex supervision tree comment

# Tool.Registry is running and populated:
# iex -S mix, then: Minga.Agent.Tool.Registry.all() |> length()

# Buffer.RefTracker is running:
# iex -S mix, then: Minga.Buffer.RefTracker.all_info()
```

---

## Wave 3: Extract Editor State (2 parallel tracks)

Depends on: Wave 2 complete (especially Track E, the Agent.Events split).

### Track G: Agent State Extraction (PRs 5.1, 5.2, 5.3)

**Goal:** Extract agent domain state from EditorState into standalone modules. After this track, agent session lifecycle and domain state are accessible without an Editor process.

**PR 5.1: Extract AgentSessionManager GenServer**

Scope:
- Create `Minga.Agent.SessionManager` GenServer that owns agent session lifecycle
- It wraps the existing `Minga.Agent.Supervisor` calls with metadata tracking
- `Editor.AgentLifecycle` becomes a thin wrapper that calls SessionManager then updates presentation state

Files to read for context:
- `lib/minga/editor/agent_lifecycle.ex` (all 346 lines)
- `lib/minga/agent/supervisor.ex` (existing `start_session`, `stop_session`, `sessions`)
- `lib/minga/editor/state/agent.ex` (the session-related fields)
- `lib/minga/agent/session.ex` first 100 lines (session init, what opts it takes)
- `lib/minga/editor.ex` — search for `AgentLifecycle` to find all call sites

Files to create:
- `lib/minga/agent/session_manager.ex` — GenServer with:
  - `start_session(opts)` — calls `Agent.Supervisor.start_session(opts)`, monitors the session, tracks metadata
  - `stop_session(session_id)` — finds session by ID, calls `Agent.Supervisor.stop_session(pid)`
  - `active_sessions()` — returns `[{id, pid, metadata}]`
  - `send_prompt(session_id, text)` — finds session by ID, calls `Agent.Session.send_prompt`
  - `abort(session_id)` — finds session by ID, calls `Agent.Session.abort`
  - `handle_info({:DOWN, ...})` — cleanup on session crash
  - Internal state: `%{sessions: %{id => %{pid: pid, monitor_ref: ref, metadata: metadata}}}`

Files to modify:
- `lib/minga/editor/agent_lifecycle.ex` — delegate session start/stop to SessionManager, keep only presentation state updates (tab bar, UI flags, spinner)
- `lib/minga/agent/supervisor.ex` — no changes (SessionManager wraps it)
- Add `Minga.Agent.SessionManager` to `Agent.Supervisor` children (or as a sibling in the top-level tree, since it should survive individual session crashes)

Constraints:
- SessionManager must start before any sessions. Add it as a named child under the top-level supervisor, or as a separate child in the Agent area.
- SessionManager must NOT reference `Minga.Editor.*`
- The Editor's AgentLifecycle must still work identically from the Editor's perspective

Testing:
- Create `test/minga/agent/session_manager_test.exs` — test start/stop/list lifecycle without an Editor
- All existing agent tests must pass
- `make lint && mix test.llm`

**PR 5.2: Make Agent.UIState independent of Editor.State sub-structs**

Scope:
- `Agent.UIState` aliases `Editor.State.FileTree` and `Editor.State.Windows`
- `Agent.UIState.View` also aliases the same
- Create agent-specific versions of these structs or extract them to a shared location

Files to read for context:
- `lib/minga/agent/ui_state.ex` lines 21-22 (the aliases)
- `lib/minga/agent/ui_state/view.ex` lines 16-17 (the aliases)
- `lib/minga/editor/state/file_tree.ex` (understand the struct shape)
- `lib/minga/editor/state/windows.ex` (understand the struct shape)

Approach (choose one):
- **Option A:** If the FileTree and Windows structs are generic (not editor-specific), move them to a shared location like `Minga.UI.FileTree` and `Minga.UI.Windows`, then update both Agent and Editor to alias the shared location.
- **Option B:** If they're deeply editor-specific, create `Minga.Agent.UIState.FileTree` and `Minga.Agent.UIState.Windows` as agent-specific copies with only the fields the agent needs.

Constraints:
- After this PR, `grep -rn "Minga\.Editor" lib/minga/agent/ui_state.ex lib/minga/agent/ui_state/` must return 0 results
- The agent view renderers that consume these structs must still work

Testing:
- All existing tests pass
- `make lint && mix test.llm`

**PR 5.3: Create Agent.RuntimeState (domain-only struct)**

Scope:
- New struct capturing the agent domain state that lives independently of EditorState
- `Editor.State.Agent` composes this struct instead of owning the fields directly

Files to read for context:
- `lib/minga/editor/state/agent.ex` (current struct, 150 lines)
- `lib/minga/agent/session_manager.ex` (the SessionManager you just created, to understand what state it tracks)

Files to create:
- `lib/minga/agent/runtime_state.ex` — struct with domain fields: `active_session_id`, `active_session_pid`, `group_sessions`, `model_name`, `provider_name`, `status`

Files to modify:
- `lib/minga/editor/state/agent.ex` — replace individual domain fields with `runtime: %Minga.Agent.RuntimeState{}`. Keep presentation fields (`spinner_timer`, `spinner_frame`, etc.) as direct fields.
- All code that reads/writes the moved fields via `AgentAccess` must be updated to go through the composed struct

Constraints:
- This is a high-touch refactor. Every place that reads `agent.status` must now read `agent.runtime.status` (or `AgentAccess` must be updated to route through the composition).
- Keep `AgentAccess` as the sole interface. Update its implementations to compose through `RuntimeState`. Callers should not notice.

Testing:
- All existing tests pass unchanged (AgentAccess hides the internal restructure)
- `make lint && mix test.llm`

---

### Track H: Editor State Extraction for Non-Agent Concerns (PRs 5.4, 5.5, 5.6)

**Goal:** Audit remaining EditorState fields for domain state that the runtime needs. Extract where needed; document as editor-only where not.

**PR 5.4: Wire Editor buffer listing to RefTracker**

Scope:
- Anywhere the Editor or its commands enumerate open buffers, verify it can be done through `Buffer.RefTracker` or `Buffer.Registry` instead of only through `Workspace.State.buffers`
- Add any missing delegations in `Minga.Buffer` entry point

Files to read for context:
- `lib/minga/buffer.ex` (entry point, see what's already delegated)
- `lib/minga/buffer/ref_tracker.ex` (the `all_info/0` function)
- `lib/minga/workspace/state.ex` or search for `state.workspace.buffers` in `lib/minga/editor/`

Constraints:
- Do NOT remove the Editor's internal buffer tracking. It's still needed for tab ordering, active buffer, etc.
- Just ensure there's a parallel path through `Buffer.list_buffers()` for non-editor consumers

Testing:
- `make lint && mix test.llm`

**PR 5.5: Audit and document search state as editor-only**

Scope:
- Verify that `Editor.State.Search` is purely presentation state (search highlight overlays, last search pattern for n/N repeat)
- If agents don't need it (they use `grep` tool instead), document it as editor-only in a comment
- If agents do need search state, extract it

Files to read:
- `lib/minga/editor/state/search.ex`
- `lib/minga/agent/tools/grep.ex` (agents use grep, not editor search)

Likely outcome: No code change, just a documentation comment in `Editor.State.Search`.

**PR 5.6: Audit and document LSP state as editor-only**

Scope:
- `Editor.State.LSP` holds pending request tracking for UI feedback (showing spinners while LSP is working)
- The actual LSP client state lives in `LSP.Client` (already Layer 0)
- Document `Editor.State.LSP` as editor-only presentation state

Files to read:
- `lib/minga/editor/state/lsp.ex`
- `lib/minga/lsp/client.ex` first 50 lines (it manages its own state)

Likely outcome: No code change, just documentation.

---

### Wave 3 Merge Point

**Gate:** Tracks G and H merge to `main`. Run:
```bash
make lint && mix test.llm
```

Verification:
```bash
# Agent UIState has zero Editor refs:
grep -rn "Minga\.Editor" lib/minga/agent/ui_state.ex lib/minga/agent/ui_state/ \
  lib/minga/agent/event_handler.ex lib/minga/agent/runtime_state.ex \
  lib/minga/agent/session_manager.ex --include="*.ex" | wc -l
# Must be 0
```

---

## Wave 4: Runtime Facade (1 track, then 2 parallel)

Depends on: Wave 3 complete.

### Track I: Agent Runtime Facade (PRs 6.1, 6.2, 6.3)

**Goal:** Create `Minga.Agent.Runtime` as the single API surface for programmatic interaction with the agentic runtime. After this track, an external client has one module to import.

This track is sequential (6.1 before 6.2 before 6.3) but can run in parallel with nothing else.

**PR 6.1: Create the Runtime facade module**

Files to read for context:
- `lib/minga/agent/session_manager.ex` (session management API)
- `lib/minga/agent/tool/registry.ex` (tool listing API)
- `lib/minga/agent/tool/executor.ex` (tool execution API)
- `lib/minga/buffer/ref_tracker.ex` (buffer listing API)
- `lib/minga/buffer.ex` (`content/1` and other buffer read functions)
- `lib/minga/events.ex` (`subscribe/1`, `broadcast/2`)
- `lib/minga/config/hooks.ex` (`register/2`)
- `lib/minga/config/advice.ex` (`register/3`)

Files to create:
- `lib/minga/agent/runtime.ex` — mostly `defdelegate`, as specified in the refactor doc's Phase 6

Constraints:
- This module must NOT reference `Minga.Editor.*`
- Every delegated function must have its own `@spec` and `@doc`
- The module-level `@moduledoc` should serve as a capability overview for LLMs reading it

Testing:
- Create `test/minga/agent/runtime_test.exs` — integration test that starts required processes (`SessionManager`, `Tool.Registry`, `RefTracker`) via `start_supervised!` and calls Runtime functions
- `make lint && mix test test/minga/agent/runtime_test.exs`

**PR 6.2: Create Introspection.Describer**

Files to create:
- `lib/minga/agent/introspection/describer.ex`

Scope:
- `describe/0` returns a map with: tools (name, description, category, destructive), sessions (id, status, model), buffers (path, ref_count, dirty), event_topics (name, payload fields), health (uptime, process_count, memory)
- Each sub-section has a helper that builds its part

Constraints:
- Must handle the case where SessionManager or RefTracker isn't running (return empty lists, don't crash)
- Health info uses `Process.info/2`, `:erlang.memory/0`, `System.monotonic_time/0`

Testing:
- Create `test/minga/agent/introspection/describer_test.exs`
- `make lint && mix test test/minga/agent/introspection/`

**PR 6.3: Add runtime tools (describe, eval, process_tree, register_tool)**

Files to create:
- `lib/minga/agent/tools/runtime_describe.ex`
- `lib/minga/agent/tools/runtime_eval.ex`
- `lib/minga/agent/tools/runtime_process_tree.ex`
- `lib/minga/agent/tools/runtime_register_tool.ex`

Scope: Each is a `Tool.Spec` struct. Register them in `Tool.Registry` at startup.

Constraints:
- `runtime_eval` must be marked `destructive: true`
- `runtime_register_tool` must be marked `destructive: true`
- `runtime_describe` and `runtime_process_tree` are read-only

Files to modify:
- `lib/minga/agent/tool/registry.ex` — add runtime tools to the initial seed in `init/1`

Testing:
- Create `test/minga/agent/tools/runtime_tools_test.exs`
- `make lint && mix test test/minga/agent/tools/runtime_tools_test.exs`

---

### Wave 4 Merge Point

**Gate:** Track I merges to `main`. Run:
```bash
make lint && mix test.llm
```

Verification:
```bash
# Runtime facade has zero Editor refs:
grep -rn "Minga\.Editor" lib/minga/agent/runtime.ex lib/minga/agent/introspection/ \
  --include="*.ex" | wc -l
# Must be 0

# Runtime.describe() works:
# iex -S mix, then: Minga.Agent.Runtime.describe() |> Map.keys()
# Should return [:tools, :sessions, :buffers, :event_topics, :health]
```

---

## Wave 5: Gateway and Buffer Forking (2 parallel tracks)

Depends on: Wave 4 complete.

### Track J: API Gateway (PRs 7.1, 7.2, 7.3, 7.4, 7.5)

**Goal:** External clients can connect via WebSocket or JSON-RPC and interact with the runtime. This is the first externally visible change.

**PR 7.1: Add Bandit dependency, create minimal WebSocket server**

Scope:
- Add `{:bandit, "~> 1.6"}` and `{:websock_adapter, "~> 0.5"}` to `mix.exs` deps
- Create `Minga.Gateway.Server` (Supervisor), `Minga.Gateway.Router` (Plug.Router)
- Conditional startup: only when `Application.get_env(:minga, :start_gateway, false)`

Files to read for context:
- `mix.exs` (existing deps, to check for conflicts)
- `lib/minga/application.ex` (where to add conditional startup)
- Bandit docs for the minimal Supervisor + Plug.Router pattern

Files to create:
- `lib/minga/gateway/server.ex`
- `lib/minga/gateway/router.ex`

Files to modify:
- `mix.exs` — add deps
- `lib/minga/application.ex` — add conditional gateway children
- `config/config.exs` or `config/dev.exs` — add `config :minga, start_gateway: false`

Constraints:
- Gateway must NOT start in test env or by default
- Gateway must start after Agent.Supervisor in the tree
- The port must be configurable: `Application.get_env(:minga, :gateway_port, 4840)`

Testing:
- `mix deps.get && make lint`
- Manually: `MINGA_GATEWAY=true iex -S mix`, then `curl http://localhost:4840/health` returns 200

**PR 7.2: WebSocket message handling**

Files to create:
- `lib/minga/gateway/websocket/handler.ex` — implements `WebSock` behaviour
- `lib/minga/gateway/dispatch.ex` — shared dispatch logic (method string to Runtime call)

Scope:
- JSON request/response protocol: `{"method": "...", "params": {...}, "id": "..."}`
- Dispatch methods: `tool.execute`, `tool.list`, `session.start`, `session.stop`, `session.list`, `session.prompt`, `runtime.describe`, `buffer.list`, `buffer.content`
- Error responses: `{"id": "...", "error": {"code": -32601, "message": "Method not found"}}`

Constraints:
- All dispatch goes through `Minga.Agent.Runtime` (the facade). The handler must not directly call SessionManager, Tool.Registry, etc.
- Use `String.to_existing_atom/1` for method parameters that become atoms (prevent atom leak)

Testing:
- Create `test/minga/gateway/websocket/handler_test.exs` — test dispatch logic directly (call `dispatch/2` without a real WebSocket)
- `make lint && mix test test/minga/gateway/`

**PR 7.3: Event streaming over WebSocket**

Scope:
- Client sends `events.subscribe` with a list of topic strings
- Handler calls `Minga.Events.subscribe/1` for each topic
- Handler's `handle_info` receives `{:minga_event, topic, payload}` and pushes JSON event to client

Constraints:
- Payload serialization: structs need to be converted to maps before `JSON.encode!`. Add a `serialize/1` helper that handles `%SomeStruct{} -> Map.from_struct` recursively.
- Topics sent by client must be validated against known topics (reject unknown topics)

Testing:
- Create `test/minga/gateway/websocket/event_streaming_test.exs` — subscribe handler process to a topic, broadcast an event, verify handler pushes JSON
- `make lint && mix test test/minga/gateway/`

**PR 7.4: JSON-RPC over stdio handler**

Files to create:
- `lib/minga/gateway/jsonrpc/handler.ex` — reads JSON lines from stdin, writes responses to stdout
- `lib/minga/cli.ex` modification — add `--rpc` flag that starts the JSON-RPC handler instead of the TUI

Scope:
- Same `dispatch/2` function as WebSocket (extracted to `Gateway.Dispatch`)
- Line-delimited JSON on stdin/stdout
- Graceful shutdown on stdin EOF

Constraints:
- Must not interfere with the existing Port protocol (which also uses stdin/stdout for the TUI). The `--rpc` flag selects one or the other.
- Must handle malformed JSON gracefully (log error, continue reading)

Testing:
- Create `test/minga/gateway/jsonrpc/handler_test.exs` — test with StringIO
- `make lint && mix test test/minga/gateway/`

**PR 7.5: Port protocol as Gateway client**

Scope:
- Create `lib/minga/gateway/port_adapter.ex` that bridges `Frontend.Manager` events to the Gateway's event subscription model
- This is organizational: the Port protocol continues to work exactly as before. The adapter just allows the Gateway's `Dispatch` module to also route responses back through the Port if needed.

Constraints:
- This is the lowest priority PR in Track J. Skip if time-constrained. The WebSocket and JSON-RPC paths are sufficient for external clients.

Testing:
- Existing Port protocol tests pass unchanged
- `make lint && mix test.llm`

---

### Track K: Buffer Forking (PRs 9.1, 9.2, 9.3, 9.4)

**Goal:** Agents can fork a buffer, edit their copy concurrently, and merge back.

**PR 9.1: Buffer.Fork GenServer**

Files to read for context:
- `lib/minga/buffer/server.ex` (the API surface: `apply_text_edits`, `find_and_replace`, `content`, understand what operations a fork needs to support)
- `lib/minga/buffer/document.ex` first 100 lines (the Document struct, `new/1`, `content/1`)
- `lib/minga/buffer/ref_tracker.ex` (forks should also be tracked)

Files to create:
- `lib/minga/buffer/fork.ex` — GenServer holding: parent_pid, ancestor Document snapshot, working Document, session_id
- Public API: `fork(parent_pid, session_id)`, `content(fork_pid)`, `apply_text_edits(fork_pid, edits)`, `merge(fork_pid)`, `discard(fork_pid)`

Constraints:
- Fork snapshots parent content at fork time (call `Buffer.content(parent_pid)`)
- Fork supports the same editing API subset that agent tools use
- `merge/1` is implemented in PR 9.2; for now, return `{:error, :not_implemented}`
- Fork registers itself in `RefTracker` as a holder of the parent buffer

Testing:
- Create `test/minga/buffer/fork_test.exs`
- Test: fork captures snapshot, edits don't affect parent, content diverges, discard cleans up
- `make lint && mix test test/minga/buffer/fork_test.exs`

**PR 9.2: Three-way merge**

Files to read for context:
- `lib/minga/git/diff.ex` (existing Myers diff usage)
- `List.myers_difference/2` docs

Files to create:
- `lib/minga/buffer/merge.ex` — pure function `merge(ancestor, theirs, ours)` returning `{:ok, merged}` or `{:conflict, [hunk()]}`

Constraints:
- Pure function, no GenServer
- A "conflict" occurs when both sides modified the same line range
- Hunk type: `%{ancestor: [line], theirs: [line], ours: [line], line_start: non_neg_integer()}`

Testing:
- Create `test/minga/buffer/merge_test.exs` — property-based tests with StreamData:
  - Non-overlapping edits merge cleanly
  - Identical edits merge cleanly (same change on both sides)
  - Overlapping different edits produce conflict
  - Empty ancestor (new file) works
- `make lint && mix test test/minga/buffer/merge_test.exs`

**PR 9.3: Wire fork merge into Buffer.Fork, wire agent tools**

Scope:
- Implement `Buffer.Fork.merge/1` using `Buffer.Merge.merge/3`
- Add a `fork_pid` option to buffer tool callbacks so agents can operate on forks

Files to modify:
- `lib/minga/buffer/fork.ex` — implement `merge/1`
- `lib/minga/agent/tools/edit_file.ex` (or the shared tool callback path) — accept optional `fork_pid` in opts

Constraints:
- On merge conflict, return `{:conflict, hunks}` and let the caller decide (agent can present the conflicts or abort)
- Merge success: apply the merged content to the parent buffer via `Buffer.Server.replace_content` or equivalent

Testing:
- Integration test: fork a buffer, edit the fork, edit the parent, merge, verify content
- `make lint && mix test test/minga/buffer/`

**PR 9.4: Selective flush before shell commands**

Scope:
- When `shell` tool executes, flush dirty buffers (and forks) to disk so builds see latest content

Files to read:
- `lib/minga/agent/tools/shell.ex` (the shell tool callback)
- `lib/minga/buffer/server.ex` — search for `save` or `write` functions

Files to modify:
- `lib/minga/agent/tools/shell.ex` — before executing the command, call a new `Buffer.flush_dirty/0` function
- `lib/minga/buffer.ex` — add `flush_dirty/0` that iterates registered buffers and saves dirty ones

Constraints:
- `flush_dirty/0` must not block indefinitely. Use a timeout per buffer save.
- Only flush buffers that have unsaved changes (check dirty flag)

Testing:
- `make lint && mix test.llm`

---

### Wave 5 Merge Point

**Gate:** Tracks J and K merge to `main`. Run:
```bash
make lint && mix test.llm
```

Verification:
```bash
# Gateway compiles and tests pass:
mix test test/minga/gateway/

# Buffer forking works:
mix test test/minga/buffer/fork_test.exs test/minga/buffer/merge_test.exs
```

---

## Wave 6: Self-Description and Boundary Enforcement (2 parallel tracks)

Depends on: Wave 5 complete.

### Track L: Self-Description and Runtime Modification (PRs 8.1, 8.2, 8.3, 8.4)

**Goal:** Flesh out the runtime tools so an LLM can fully discover and modify the runtime.

**PR 8.1: Flesh out runtime_describe tool**

Scope: Enhance `Introspection.Describer.describe/0` to include full JSON Schema for each tool, payload field descriptions for event topics, and health metrics.

Testing:
- Update `test/minga/agent/introspection/describer_test.exs`
- `make lint && mix test test/minga/agent/introspection/`

**PR 8.2: Implement runtime_eval tool**

Scope: As specified in the refactor doc. `Code.eval_string/1` wrapped in try/rescue. Always `destructive: true`.

Constraints:
- Return value must be `inspect`ed with `pretty: true, limit: :infinity`
- Errors must return the exception message, not the stacktrace

Testing:
- `test/minga/agent/tools/runtime_eval_test.exs` — test success, error, and that it's marked destructive
- `make lint`

**PR 8.3: Implement runtime_register_tool tool**

Scope: As specified. Evaluates a code string to get a callback, creates a `Tool.Spec`, registers it.

Constraints:
- Always `destructive: true`
- Validate that the evaluated code is a function of arity 1

Testing:
- `test/minga/agent/tools/runtime_register_tool_test.exs`
- `make lint`

**PR 8.4: Implement runtime_process_tree tool**

Scope: Walk the supervision tree starting from `Minga.Supervisor`, return a formatted tree string.

Testing:
- `test/minga/agent/tools/runtime_process_tree_test.exs`
- `make lint`

---

### Track M: Boundary Enforcement (PRs 10.1, 10.3)

**Goal:** Make the layer boundaries machine-enforced and update documentation.

**PR 10.1: Add Credo layer boundary check**

Files to read for context:
- `.credo.exs` (existing checks configuration)
- `AGENTS.md` "Code Organization" section (the layer definitions)
- Any existing custom Credo check in `lib/mix/` for the pattern

Files to create:
- `lib/mix/credo/check/layer_boundary.ex` — Credo check that parses `alias` and `import` lines, classifies each module into a layer, and flags upward dependencies

Layer assignments (from AGENTS.md):
- Layer 0: `Minga.Buffer`, `Minga.Events`, `Minga.Config`, `Minga.LSP`, `Minga.Git`, `Minga.Project`, `Minga.Editing`, `Minga.Diagnostics`, `Minga.Parser`, `Minga.Core`, `Minga.Language`, `Minga.Log`, `Minga.Telemetry`
- Layer 1: `Minga.Agent` (except view modules that moved to editor in Track F)
- Layer 2: `Minga.Gateway`
- Layer 3: `Minga.Editor`, `Minga.Input`, `Minga.Frontend`, `Minga.UI`, `Minga.Shell`, `Minga.Keymap`, `Minga.Mode`, `Minga.Command`

Files to modify:
- `.credo.exs` — add the new check to the checks list

Constraints:
- The check must pass on the current codebase after all previous waves are merged. If it doesn't, there are remaining violations to fix first.
- Cross-cutting modules (`Minga.Events`, `Minga.Log`, `Minga.Telemetry`, `Minga.Clipboard`) are exempt from layer checks (usable by all layers)

Testing:
- `mix credo` must pass with the new check enabled
- `make lint`

**PR 10.3: Documentation pass**

Scope:
- Update `AGENTS.md` module organization table to reflect moves (SlashCommand, ViewContext, etc.)
- Update `docs/ARCHITECTURE.md` supervision tree diagram
- Update supervision tree comments in `application.ex` and `services/supervisor.ex` (these should already be updated from earlier PRs, but do a final audit)
- Update `MINGA_REFACTOR_TO_AGENTIC.md` to mark completed phases

Files to modify:
- `AGENTS.md`
- `docs/ARCHITECTURE.md`
- `MINGA_REFACTOR_TO_AGENTIC.md`

Testing:
- `make lint` (catches any broken module references in docstrings)

Note: PR 10.2 (optional directory reorganization) is deliberately omitted. The Credo check enforces boundaries regardless of directory structure. Renaming is high-churn, low-value at this stage.

---

### Wave 6 Merge Point (Final)

**Gate:** Tracks L and M merge to `main`. Run:
```bash
make lint && mix test.llm
```

Final verification (run all of these):
```bash
# 1. Zero upward deps from Layer 0 to Layer 1+:
grep -rn "Minga\.Editor\|Minga\.Agent" lib/minga/buffer/ lib/minga/events.ex \
  lib/minga/config/ lib/minga/lsp/ lib/minga/git/ lib/minga/diagnostics.ex \
  --include="*.ex" | wc -l
# Must be 0

# 2. Agent domain modules have zero Editor refs:
grep -rn "Minga\.Editor" lib/minga/agent/session.ex lib/minga/agent/session_manager.ex \
  lib/minga/agent/provider.ex lib/minga/agent/providers/ lib/minga/agent/tools/ \
  lib/minga/agent/event_handler.ex lib/minga/agent/runtime.ex \
  lib/minga/agent/runtime_state.ex lib/minga/agent/introspection/ \
  --include="*.ex" | wc -l
# Must be 0

# 3. Credo layer check passes:
mix credo --strict

# 4. Full test suite:
make lint && mix test.llm

# 5. Release builds:
MIX_ENV=prod mix release minga
MIX_ENV=prod mix release minga_macos
```

---

## Summary: Wave/Track Matrix

```
Wave 1 (parallel, no deps)          Wave 2 (parallel, needs W1)
├── Track A: Core decoupling        ├── Track D: Wire infrastructure
│   PR 1.1 log_to_messages          │   PR 2.4 Tool.Registry in sup tree
│   PR 1.2 Buffer.Server event      │   PR 3.2 RefTracker in sup tree
│   PR 1.3 Config.Advice docstring  │   PR 3.3 Buffer.list_buffers
├── Track B: Tool system            │   PR 4.1 Promote Agent.Supervisor
│   PR 2.1 Tool.Spec struct         ├── Track E: Agent.Events split
│   PR 2.2 Tool.Registry            │   PR 1.4 EventHandler extraction
│   PR 2.3 Tool.Executor            ├── Track F: Move view modules
└── Track C: RefTracker             │   PR 1.5 SlashCommand → editor
    PR 3.1 Buffer.RefTracker        │   PR 1.6 ViewContext → editor

Wave 3 (parallel, needs W2)         Wave 4 (sequential, needs W3)
├── Track G: Agent state            └── Track I: Runtime facade
│   PR 5.1 SessionManager               PR 6.1 Runtime module
│   PR 5.2 UIState independence          PR 6.2 Introspection.Describer
│   PR 5.3 Agent.RuntimeState            PR 6.3 Runtime tools
└── Track H: Editor state audit
    PR 5.4 Buffer listing
    PR 5.5 Search state audit
    PR 5.6 LSP state audit

Wave 5 (parallel, needs W4)         Wave 6 (parallel, needs W5)
├── Track J: API Gateway             ├── Track L: Self-description
│   PR 7.1 Bandit + WebSocket       │   PR 8.1 runtime_describe
│   PR 7.2 Message handling          │   PR 8.2 runtime_eval
│   PR 7.3 Event streaming           │   PR 8.3 runtime_register_tool
│   PR 7.4 JSON-RPC stdio            │   PR 8.4 runtime_process_tree
│   PR 7.5 Port adapter              └── Track M: Boundary enforcement
└── Track K: Buffer forking               PR 10.1 Credo layer check
    PR 9.1 Fork GenServer                 PR 10.3 Documentation pass
    PR 9.2 Three-way merge
    PR 9.3 Wire tools to forks
    PR 9.4 Flush before shell
```

## Calendar Estimate

Assuming 2-3 workers running in parallel:

| Wave | Calendar time | Cumulative |
|------|-------------|------------|
| Wave 1 | 1 week | Week 1 |
| Wave 2 | 1-2 weeks | Week 2-3 |
| Wave 3 | 1-2 weeks | Week 3-5 |
| Wave 4 | 3-5 days | Week 5-6 |
| Wave 5 | 2-3 weeks | Week 6-9 |
| Wave 6 | 1 week | Week 9-10 |

**Total: ~10 weeks with 2-3 parallel workers.** The critical path runs through Tracks A → E → G → I → J. Buffer forking (Track K) and boundary enforcement (Track M) are off the critical path.

## File Conflict Matrix

This table shows which source files are modified by multiple PRs across different tracks. Workers must not be in the same wave if they modify the same file.

| File | PRs that modify it | Conflict-free? |
|------|-------------------|----------------|
| `lib/minga/events.ex` | 1.1, 1.2 (both Track A) | Yes (same track) |
| `lib/minga/editor.ex` | 1.1, 1.2 (Track A) | Yes (same track) |
| `lib/minga/application.ex` | 3.2, 4.1 (both Track D) | Yes (same track) |
| `lib/minga/services/supervisor.ex` | 4.1 (Track D) | No conflict |
| `lib/minga/services/independent.ex` | 2.4 (Track D) | No conflict |
| `lib/minga/agent/events.ex` | 1.4 (Track E) | No conflict |
| `lib/minga/agent/ui_state.ex` | 5.2 (Track G) | No conflict |
| `lib/minga/editor/state/agent.ex` | 5.3 (Track G) | No conflict |
| `lib/minga/agent/tools.ex` | None (read-only) | N/A |
| `lib/minga/buffer.ex` | 3.2, 3.3 (Track D), 9.4 (Track K) | Yes (different waves) |
| `mix.exs` | 7.1 (Track J) | No conflict |

No cross-track conflicts exist within any wave. The plan is safe for parallel execution.
