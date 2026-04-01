# Execution Plan: Runtime-First Minga

**Status:** Draft
**Date:** 2026-03-31
**Supersedes:** `docs/PLAN-ui-stability.md` (90% already shipped), `MINGA_REFACTOR_TO_AGENTIC.md` (experiments branch)

## How to read this plan

**Waves** are groups of work. All work in a wave completes before the next wave starts.

**Tracks** within a wave are independent. Each track runs on its own git worktree branching from `main`. Tracks within the same wave never touch the same files. Assign one agent per track.

**Gates** are checkpoints between waves. At each gate, all tracks merge to `main`, `make lint` passes, and `mix test.llm` passes. No wave starts until its gate is green.

**Each work item** lists: what to do, which files to read first, which files to modify, constraints, and the exact verification commands. A cold-start LLM should be able to execute any item without reading the rest of this document.

**Agent count per wave** is the maximum number of concurrent agents that can work without stepping on each other. More agents than the listed count will create merge conflicts.

---

## Current state (2026-03-31)

Most of the UI stability plan has already shipped:

| Item | Status |
|------|--------|
| A1: content-type guard on sync_active_window_buffer | ✅ Done |
| A2: agent deactivation on zoom-out | ✅ Done |
| A3: fresh workspace for first-time zoom | ✅ Done |
| A4: deactivate counterpart | ✅ Done |
| B1: timer quarantine in headless mode | ✅ Done |
| B2: pure state functions | ✅ Done |
| B3: pure state tests | ✅ Done |
| C1-C4: shell lifecycle callbacks | ✅ Done |

Remaining upward dependencies (Layer 0/1 modules importing from Editor):

| Module | Reference | Count |
|--------|-----------|-------|
| `Minga.LSP.Client` | `Minga.Editor.log_to_warnings/1` | 4 |
| `Minga.Buffer.Server` | `Process.whereis(Minga.Editor)` | 1 |
| `Minga.Agent.Session` | `Minga.Editor.log_to_messages/1` | 1 |
| `Minga.Config.Advice` | Docstring reference | 1 |
| **Total** | | **7** |

---

## Wave 1: Enforce Boundaries + Finish Stability ✅ DONE

**Duration:** 1 week
**Agents:** 3 (one per track, all start from `main`)
**Gate:** `make lint` (with boundary check) passes, `mix test.llm` passes 3x clean
**Completed:** 2026-03-31 — All three tracks merged. Boundary check hard-enabled (#1364), upward deps severed (#1366), timer quarantine verified in-place.

### Track A: Boundary check (1 agent) ✅ DONE

~~Create `mix check.layers` that enforces layer rules.~~ Existing `Minga.Credo.DependencyDirectionCheck` already does this. Promoted from warning (`exit_status: 0`) to hard failure in PR #1364.

**What:** ~~A Mix task that scans every `.ex` file under `lib/`, extracts `alias`/`import` lines, and fails if a module in a lower layer imports from a higher layer.~~ Already implemented as a credo check in `credo/checks/dependency_direction_check.exs`. Uses AST walking (not regex), classifies modules into three layers, has an `@allowed_references` allowlist for structural dispatch, and exempts cross-cutting modules. The only change needed was removing `exit_status: 0` from `.credo.exs`.

**Files to read:**
- `AGENTS.md` § "Code Organization" → the three layer definitions and module assignments
- `lib/mix/` → existing custom Mix tasks for pattern reference
- `.credo.exs` → understand the existing lint pipeline

**Files to create:**
- `lib/mix/tasks/check_layers.ex`

**Implementation:**

```elixir
defmodule Mix.Tasks.CheckLayers do
  @moduledoc "Enforces layer dependency rules."
  use Mix.Task

  # Layer 0: Core Runtime (no agent, no editor deps)
  @layer_0_prefixes ~w(Minga.Buffer Minga.Editing Minga.Core Minga.Config
    Minga.Keymap Minga.Mode Minga.Language Minga.LSP Minga.Git Minga.Project
    Minga.Diagnostics Minga.Command Minga.Events Minga.Log Minga.Telemetry
    Minga.Clipboard Minga.Session Minga.Parser Minga.Extension Minga.Workspace)

  # Layer 1: Agent Runtime (no editor deps)
  @layer_1_prefixes ~w(Minga.Agent Minga.Tool)

  # Layer 2: Presentation
  @layer_2_prefixes ~w(Minga.Editor Minga.Shell Minga.Input Minga.Frontend Minga.UI)

  # Known violations to fix (shrink this list, never grow it)
  @allowed_violations [
    {"lib/minga/lsp/client.ex", "Minga.Editor"},
    {"lib/minga/buffer/server.ex", "Minga.Editor"},
    {"lib/minga/agent/session.ex", "Minga.Editor"},
    {"lib/minga/config/advice.ex", "Minga.Editor"}
  ]

  @impl true
  def run(_args) do
    # Scan lib/ for violations, compare against allowlist, fail on new ones
  end
end
```

**Files to modify:**
- `Makefile` → add `mix check.layers` to the `lint` target

**Constraints:**
- Must pass on current codebase with the 4 allowlisted violations
- Must fail if a new violation is added (test by temporarily adding `alias Minga.Editor` to `lib/minga/buffer/document.ex`, running, then reverting)
- Scan `alias Minga.X` and `import Minga.X` lines. Ignore comments, `@moduledoc`, and `@doc` strings.
- After Wave 2 (namespace split), update prefixes to `MingaAgent.*` and `MingaEditor.*`

**Verification:**
```bash
mix check.layers                              # passes (allowlisted violations only)
echo 'alias Minga.Editor.State' >> lib/minga/buffer/document.ex
mix check.layers                              # FAILS with clear error message
git checkout lib/minga/buffer/document.ex     # revert
make lint                                     # passes
```

---

### Track B: Sever upward dependencies (1 agent)

Remove all 7 remaining upward references so Layer 0/1 modules are independent of the Editor.

**What:** Replace direct `Minga.Editor.log_to_messages/warnings` calls with `Minga.Events.broadcast/2`. Replace `Process.whereis(Minga.Editor)` with Events. Fix the docstring.

**Files to read:**
- `lib/minga/events.ex` → existing event topics, payload struct pattern, `subscribe/1`, `broadcast/2`
- `lib/minga/lsp/client.ex` lines 260-270, 450-470, 600-610 → the 4 `log_to_warnings` call sites
- `lib/minga/buffer/server.ex` line 1903 → the `Process.whereis` call
- `lib/minga/agent/session.ex` line 1476 → the `log_to_messages` call
- `lib/minga/config/advice.ex` line 41 → the docstring reference
- `lib/minga/editor.ex` lines 108-130 → existing `log_to_messages/log_to_warnings` implementations
- `lib/minga/editor.ex` → search for `subscribe` to see how Editor subscribes to other events

**Files to modify:**
- `lib/minga/events.ex` → add `LogMessageEvent` struct, add `:log_message` to `@type topic` union
- `lib/minga/lsp/client.ex` → replace 4 calls
- `lib/minga/git/tracker.ex` line 166 → replace 1 call (also found during scan)
- `lib/minga/buffer/server.ex` → replace `Process.whereis` block with Events broadcast
- `lib/minga/agent/session.ex` → replace 1 call
- `lib/minga/config/advice.ex` → fix docstring
- `lib/minga/editor/startup.ex` or `lib/minga/editor.ex` → subscribe to `:log_message`, add `handle_info` clause

**Constraints:**
- `LogMessageEvent` must have `@enforce_keys [:text, :level]` and `@type level :: :info | :warning | :error`
- Do NOT remove `Editor.log_to_messages/1` or `Editor.log_to_warnings/1` public functions. Internal editor code still uses them. Just stop Layer 0/1 modules from calling them.
- The Editor's `handle_info` for `:log_message` must route `:warning` and `:error` levels through `MessageLog.log_warning`, others through `MessageLog.log_message`
- For `Buffer.Server`, the existing behavior sends `{:face_overrides_changed, buf_pid}` to the Editor. Replace with `Minga.Events.broadcast(:face_overrides_changed, %{buffer: buf_pid})`

**Verification:**
```bash
grep -rn "Minga\.Editor" lib/minga/lsp/ lib/minga/git/ lib/minga/buffer/server.ex \
  lib/minga/agent/session.ex lib/minga/config/advice.ex --include="*.ex" | grep -v "test/" | grep -v "^.*#"
# Expected: 0 results (the docstring fix removes the last one)
make lint && mix test.llm
```

---

### Track C: Finish timer quarantine (1 agent)

Guard remaining unguarded `send(self(), ...)` and `Process.send_after` in the Editor GenServer.

**What:** Add `if state.backend != :headless` guards to the ~10 remaining timer sites.

**Files to read:**
- `lib/minga/editor.ex` → search for `send(self()` and `Process.send_after(self()` to find all sites
- `lib/minga/editor.ex` → search for `backend != :headless` to see the existing guard pattern
- `docs/PLAN-ui-stability.md` § "B1" → the categorization of which timers to skip vs apply synchronously

**File to modify:**
- `lib/minga/editor.ex`

**Unguarded sites (as of 2026-03-31):**

| Line | Timer | Action |
|------|-------|--------|
| 225 | `:evict_parser_trees` | Skip in headless |
| 753 | `:dismiss_toast` | Skip in headless |
| 780 | `:setup_highlight` | Apply synchronously in headless (functional effect tests depend on) |
| 1092 | `msg` with `delay` (spinner) | Skip in headless |
| 1249 | `:debounced_render` | Already handled by `schedule_render` headless guard at line 1242 — verify, don't double-guard |
| 1352 | `msg` with `interval` (spinner) | Skip in headless |
| 1373 | `msg` with `interval` (spinner) | Skip in headless |
| 1458 | `:check_swap_recovery` | Skip in headless |
| 1539 | `:request_code_lens_and_inlay_hints` | Skip in headless |
| 2076 | `:warning_popup_timeout` | Skip in headless |

**Pattern to use:**
```elixir
# Before:
Process.send_after(self(), :some_timer, 500)

# After:
if state.backend != :headless do
  Process.send_after(self(), :some_timer, 500)
end
```

For `:setup_highlight` (line 780), apply synchronously:
```elixir
# Before:
send(self(), :setup_highlight)

# After:
if state.backend == :headless do
  # Apply the highlight setup synchronously so tests see it immediately
  handle_setup_highlight(state)
else
  send(self(), :setup_highlight)
  state
end
```

Verify `handle_setup_highlight` exists or extract the logic from the `:setup_highlight` `handle_info` clause into a named function.

**Constraints:**
- Do not change any behavior in non-headless mode
- Line 1249 (`:debounced_render`) is likely already covered by the `schedule_render` guard at line 1242. Read both before adding a redundant guard.
- Do not refactor or rename anything. Only add guards.

**Verification:**
```bash
# All timer sites are guarded (use context-aware check, not same-line grep):
# Note: state/session.ex:start_timer is excluded below — it is protected by
# session_dir: nil (nil-clause guard) and by its call sites in editor.ex.
python3 -c "
import re, os
timer_p = re.compile(r'send\\(self\\(\\)|Process\\.send_after\\(self\\(\\)')
headless_p = re.compile(r'headless')
exclude = {'lib/minga/editor/state/session.ex'}
for root, _, files in os.walk('lib/minga/editor'):
  for f in files:
    if not f.endswith('.ex'): continue
    path = os.path.join(root, f)
    if path in exclude: continue
    lines = open(path).readlines()
    for i, l in enumerate(lines):
      if timer_p.search(l):
        ctx = ''.join(lines[max(0,i-10):i+1])
        if not headless_p.search(ctx): print(path+':'+str(i+1)+' UNGUARDED')
"
# Expected: no output (all sites are guarded)

make lint && mix test.llm
# Run 3 times to check for flakes:
mix test.llm && mix test.llm && mix test.llm
```

### Wave 1 gate

```bash
make lint                    # includes mix check.layers
mix test.llm                 # 3 consecutive passes, 0 flakes
grep -rn "Minga\.Editor" lib/minga/lsp/ lib/minga/git/ lib/minga/buffer/server.ex \
  lib/minga/agent/session.ex lib/minga/config/advice.ex --include="*.ex" | \
  grep -v "test/\|#" | wc -l
# Expected: 0
```

Merge order: Track A first (boundary check), then B and C (either order).

---

## Wave 2: Namespace Split ✅ DONE

**Duration:** 1 week
**Agents:** 1 (sequential PRs, too much file overlap for parallel work)
**Gate:** Three namespaces exist, boundary check uses namespace prefixes, all tests pass
**Completed:** 2026-03-31 — NS-1 (#1367), NS-2+NS-3 (#1370). Three namespaces active. 9 pre-existing violations tracked in #1368.

### NS-1: Create `MingaAgent.*` ✅ DONE

This is purely mechanical: move files, rename module prefixes, update aliases. No behavioral changes. Do it in a quiet window with no other branches in flight.

### NS-1: Create `MingaAgent.*` (1 PR)

Move agent domain modules from `lib/minga/agent/` to `lib/minga_agent/`. Move `lib/minga/tool/` to `lib/minga_agent/tool/`.

**Files to read:**
- `lib/minga/agent/` → full directory listing, understand which modules are domain vs presentation
- `lib/minga/tool/` → full directory listing

**Modules that move (rename `Minga.Agent.X` → `MingaAgent.X`):**
- `session.ex`, `supervisor.ex`
- `provider.ex`, `provider_resolver.ex`, `providers/native.ex`, `providers/pi_rpc.ex`
- `message.ex`, `event.ex`, `internal_state.ex`
- `compaction.ex`, `cost_calculator.ex`, `token_estimator.ex`, `turn_usage.ex`
- `memory.ex`, `session_store.ex`, `session_export.ex`, `session_metadata.ex`
- `config.ex`, `credentials.ex`, `model_catalog.ex`, `model_limits.ex`
- `retry.ex`, `notifier.ex`, `branch.ex`, `instruction.ex`, `instructions.ex`, `skills.ex`
- `todo_item.ex`, `context_artifact.ex`, `file_mention.ex`, `markdown.ex`
- `tool_call.ex`, `tool_approval.ex`

Move `lib/minga/tool/` → `lib/minga_agent/tool/` (rename `Minga.Tool.X` → `MingaAgent.Tool.X`):
- `spec.ex`, `registry.ex`, `executor.ex`, `approval.ex`, `schema.ex`

Move all `lib/minga/agent/tools/` → `lib/minga_agent/tools/` (rename `Minga.Agent.Tools.X` → `MingaAgent.Tools.X`)

**Modules that stay in `lib/minga/agent/` (they depend on Editor, move to MingaEditor in NS-2):**
- `events.ex`, `ui_state.ex`, `ui_state/panel.ex`, `ui_state/view.ex`, `view_context.ex`
- `slash_command.ex`, `slash_command/command.ex`
- `buffer_sync.ex`, `edit_boundary.ex`
- `diff_renderer.ex`, `diff_review.ex`, `diff_snapshot.ex`
- `chat_decorations.ex`, `chat_search.ex`, `markdown_highlight.ex`
- `view/` (all renderer modules)

**Update all aliases across the entire codebase.** Use find-and-replace:
- `Minga.Agent.Session` → `MingaAgent.Session` (but NOT `Minga.Agent.Session` in the presentation modules that stay — those become `MingaAgent.Session` too, they just import from the new location)
- `Minga.Agent.Tools.` → `MingaAgent.Tools.`
- `Minga.Tool.` → `MingaAgent.Tool.`
- etc.

**Also update:**
- `config/config.exs`, `config/test.exs` → any module references
- `test/` → mirror the new directory structure, update all module references
- `lib/minga/application.ex` → supervisor child references

**Constraints:**
- Do NOT move presentation modules. They stay as `Minga.Agent.*` for now.
- Run `mix compile --warnings-as-errors` after every batch of renames to catch missed references.
- Test files move to mirror lib: `test/minga/agent/session_test.exs` → `test/minga_agent/session_test.exs`

**Verification:**
```bash
mix compile --warnings-as-errors   # no undefined module warnings
make lint
mix test.llm
# Confirm no old references remain:
grep -rn "defmodule Minga\.Agent\." lib/minga_agent/ | head -5
# Expected: 0 (all are MingaAgent.*)
grep -rn "defmodule Minga\.Tool\." lib/minga_agent/ | head -5
# Expected: 0
```

### NS-2: Create `MingaEditor.*` ✅ DONE

Move presentation modules to `lib/minga_editor/`.

**Modules that move:**
- `lib/minga/editor/` → `lib/minga_editor/` (rename `Minga.Editor.X` → `MingaEditor.X`) — 135 modules
- `lib/minga/shell/` → `lib/minga_editor/shell/` (rename `Minga.Shell.X` → `MingaEditor.Shell.X`) — 22 modules
- `lib/minga/input/` → `lib/minga_editor/input/` (rename `Minga.Input.X` → `MingaEditor.Input.X`) — 29 modules
- `lib/minga/frontend/` → `lib/minga_editor/frontend/` (rename `Minga.Frontend.X` → `MingaEditor.Frontend.X`) — 12 modules
- `lib/minga/ui/` → `lib/minga_editor/ui/` (rename `Minga.UI.X` → `MingaEditor.UI.X`) — 56 modules
- Remaining `lib/minga/agent/` presentation modules → `lib/minga_editor/agent/` (rename `Minga.Agent.Events` → `MingaEditor.Agent.Events`, etc.)
- `lib/minga/workspace/` → `lib/minga_editor/workspace/` — 3 modules

**Update all aliases across the entire codebase.** This is the largest rename (~250 modules). Use a script:

```bash
# Generate the rename map and apply with sed
find lib/minga/editor lib/minga/shell lib/minga/input lib/minga/frontend lib/minga/ui \
  -name "*.ex" -exec grep -l "defmodule" {} \; | while read f; do
  # Extract old module name, compute new, sed across all .ex files
done
```

**Constraints:**
- Move directories, don't copy. `git mv` preserves history.
- Run `mix compile --warnings-as-errors` frequently during the rename.
- The `lib/minga/editor.ex` entry point becomes `lib/minga_editor/editor.ex` with `defmodule MingaEditor`.
- `Minga.Editor` references in `lib/minga/application.ex` update to `MingaEditor`.

**Verification:**
```bash
mix compile --warnings-as-errors
make lint
mix test.llm
# Confirm boundary:
grep -rn "alias MingaEditor\|import MingaEditor" lib/minga/ lib/minga_agent/ | head -5
# Expected: 0 (no upward deps)
grep -rn "alias MingaAgent" lib/minga/ | head -5
# Expected: 0
```

### NS-3: Update boundary check for new namespaces ✅ DONE (merged into NS-2)

Update `mix check.layers` to use the three namespace prefixes instead of the module-level allowlist.

**File to modify:** `lib/mix/tasks/check_layers.ex`

**New logic:**
```elixir
# Layer 0: any module under lib/minga/ (Minga.*)
# Layer 1: any module under lib/minga_agent/ (MingaAgent.*)
# Layer 2: any module under lib/minga_editor/ (MingaEditor.*)
#
# Rule: files in lib/minga/ may not alias/import MingaAgent.* or MingaEditor.*
# Rule: files in lib/minga_agent/ may not alias/import MingaEditor.*
```

The allowlist should be empty after Wave 1 Track B severed all upward deps.

**Verification:**
```bash
mix check.layers   # passes with 0 allowlisted violations
make lint
```

### Wave 2 gate

```bash
make lint
mix test.llm
# Boundary is clean:
grep -rn "alias MingaEditor\|import MingaEditor" lib/minga/ lib/minga_agent/ | wc -l   # 0
grep -rn "alias MingaAgent\|import MingaAgent" lib/minga/ | wc -l                       # 0
# No old-namespace modules remain:
grep -rn "defmodule Minga\.Editor\." lib/ | wc -l    # 0
grep -rn "defmodule Minga\.Agent\." lib/ | wc -l     # 0 (presentation modules moved to MingaEditor.Agent.*)
grep -rn "defmodule Minga\.Shell\." lib/ | wc -l     # 0
grep -rn "defmodule Minga\.Input\." lib/ | wc -l     # 0
grep -rn "defmodule Minga\.Frontend\." lib/ | wc -l  # 0
grep -rn "defmodule Minga\.UI\." lib/ | wc -l        # 0
grep -rn "defmodule Minga\.Tool\." lib/ | wc -l      # 0
```

---

## Wave 3: Agent Runtime Foundation ✅ DONE

Build the tool registry, session manager, and headless entry point.

**Duration:** 3 weeks
**Agents:** 3 (one per track)
**Gate:** Headless runtime boots and runs an agent tool without a frontend

### Track A: Tool Registry + Executor (1 agent)

**Files to read:**
- `lib/minga_agent/tools.ex` → current tool dispatch (the `__tool_specs__` pattern)
- `lib/minga_agent/tool/` → existing tool infrastructure (Spec, Registry, Executor if they exist)
- `lib/minga/config/advice.ex` → understand `wrap/2` for the unified execution path
- `lib/minga/events.ex` → event patterns

**PR A-3.1: Tool.Spec struct**

Create `MingaAgent.Tool.Spec` if it doesn't already exist (check first). Fields: `name`, `description`, `parameter_schema`, `callback`, `category`, `approval_level`, `metadata`.

**File to create/modify:** `lib/minga_agent/tool/spec.ex`

**PR A-3.2: Tool.Registry (ETS-backed)**

Create `MingaAgent.Tool.Registry` GenServer. ETS table with `read_concurrency: true`. Functions: `register/1`, `lookup/1`, `all/0`, `registered?/1`. Register all built-in tools from `MingaAgent.Tools` at startup.

Add to `Minga.Foundation.Supervisor` children.

**Files to create:** `lib/minga_agent/tool/registry.ex`
**Files to modify:** `lib/minga/foundation/supervisor.ex`

**PR A-3.3: Tool.Executor with Config.Advice integration**

Create `MingaAgent.Tool.Executor`. The `execute/3` function:
1. Look up tool spec in Registry
2. Check approval (auto/ask/deny)
3. Wrap execution in `Minga.Config.Advice.wrap(tool_name, fn -> spec.callback.(args) end)`
4. Return `{:ok, result}` or `{:error, reason}`

The advice integration is the key design decision: tools and commands share one advice path.

**Files to create:** `lib/minga_agent/tool/executor.ex`
**Files to read:** `lib/minga/config/advice.ex` → `wrap/2` signature and behavior

**Constraints:**
- The ETS fast-path: if `Minga.Config.Advice.has_advice?(tool_name)` returns false (one ETS read), skip the wrap entirely. Add `has_advice?/1` to Advice if it doesn't exist.
- Tools execute in the calling process (the Agent.Session). No spawning.

**Verification for all 3 PRs:**
```bash
make lint && mix test.llm
# Tool round-trip works:
mix test test/minga_agent/tool/registry_test.exs
mix test test/minga_agent/tool/executor_test.exs
```

---

### Track B: Session Manager (1 agent)

**Files to read:**
- `lib/minga_agent/session.ex` → current session lifecycle
- `lib/minga_agent/supervisor.ex` → current supervision
- `lib/minga_editor/agent_lifecycle.ex` → how the Editor currently manages sessions
- `lib/minga_editor/state/agent.ex` → session fields on EditorState

**PR B-3.1: Create MingaAgent.SessionManager**

GenServer that owns session lifecycle independently of any UI.

```elixir
defmodule MingaAgent.SessionManager do
  use GenServer

  # Public API
  @spec start_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
  @spec abort(String.t()) :: :ok | {:error, :not_found}
  @spec list_sessions() :: [{String.t(), pid(), MingaAgent.SessionMetadata.t()}]
end
```

Session IDs are human-readable strings (e.g., `"session-1"`), not PIDs. The SessionManager maps IDs to PIDs internally.

**Files to create:** `lib/minga_agent/session_manager.ex`
**Files to modify:** `lib/minga_agent/supervisor.ex` → add SessionManager as a child

**PR B-3.2: Wire Editor to use SessionManager**

Update `MingaEditor.AgentLifecycle` to call `MingaAgent.SessionManager.start_session/1` instead of directly starting sessions. The Editor still keeps a local reference to the active session PID for rendering, but lifecycle goes through SessionManager.

**Files to modify:** `lib/minga_editor/agent_lifecycle.ex`

**Constraints:**
- SessionManager starts sessions via `MingaAgent.Supervisor` (DynamicSupervisor), not directly.
- SessionManager monitors sessions and broadcasts `:agent_session_stopped` events when they die.
- The Editor subscribes to these events instead of monitoring session PIDs directly.

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga_agent/session_manager_test.exs
```

---

### Track C: Promote Agent.Supervisor + Headless Milestone (1 agent)

**Files to read:**
- `lib/minga/application.ex` → current supervision tree
- `lib/minga_agent/supervisor.ex` → current Agent.Supervisor placement
- `lib/minga/services/supervisor.ex` → where Agent.Supervisor currently lives

**PR C-3.1: Promote MingaAgent.Supervisor to top-level peer**

Move `MingaAgent.Supervisor` from Services.Supervisor to a direct child of `Minga.Supervisor`. It sits between Services and Runtime.

**Files to modify:**
- `lib/minga/application.ex` → add `MingaAgent.Supervisor` as direct child
- `lib/minga/services/supervisor.ex` → remove Agent.Supervisor from children

**PR C-3.2: Supervision tree test**

```elixir
# test/minga/architecture_test.exs
test "MingaAgent.Supervisor is a top-level peer, not nested under Services" do
  top_children = Supervisor.which_children(Minga.Supervisor)
  top_ids = Enum.map(top_children, &elem(&1, 0))
  assert MingaAgent.Supervisor in top_ids

  services_children = Supervisor.which_children(Minga.Services.Supervisor)
  services_ids = Enum.map(services_children, &elem(&1, 0))
  refute MingaAgent.Supervisor in services_ids
end
```

**PR C-3.3: Headless entry point**

Create `Minga.Runtime` module with `start/1` that boots Foundation, Buffer, Services, and Agent supervisors without Runtime.Supervisor (no frontend, no editor).

**Files to create:** `lib/minga/runtime.ex`

```elixir
defmodule Minga.Runtime do
  @moduledoc """
  Boots the Minga runtime without any frontend or editor.

  This is the headless entry point. Layer 0 (core) and Layer 1 (agent)
  are fully functional. No rendering, no input handling, no Port.
  """

  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    children = [
      Minga.Foundation.Supervisor,
      Minga.Buffer.Supervisor,
      Minga.Services.Supervisor,
      MingaAgent.Supervisor
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Minga.Runtime.Supervisor)
  end
end
```

**PR C-3.4: Headless integration test**

```elixir
# test/minga/runtime_test.exs
defmodule Minga.RuntimeTest do
  use ExUnit.Case, async: false
  # async: false because we're starting a full supervision tree

  test "headless runtime boots and runs an agent tool" do
    {:ok, sup} = Minga.Runtime.start()

    # Create a buffer
    {:ok, buf} = Minga.Buffer.Server.start_link(content: "defmodule Foo do\nend\n")

    # Execute a tool through the registry
    {:ok, result} = MingaAgent.Tool.Executor.execute("read_file", %{"path" => "test.ex"})
    assert is_binary(result)

    # Clean up
    Supervisor.stop(sup)
  end
end
```

Adjust the test based on what Tool.Executor actually looks like after Track A lands. The tool may need a real file on disk rather than a buffer. The point is: boot without frontend, run a tool, get a result.

**Constraints:**
- The headless test must NOT start `MingaEditor.Supervisor`, `MingaEditor.Frontend.Manager`, or any Port.
- If existing application startup code hardcodes Editor startup, add a `:mode` option to `Minga.Application` that skips Runtime.Supervisor when `:headless`.

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga/runtime_test.exs
mix test test/minga/architecture_test.exs
```

### Wave 3 gate: HEADLESS RUNTIME WORKS

This is the product gate. After this, Minga is a runtime.

```bash
make lint
mix test.llm          # all pass
mix test test/minga/runtime_test.exs         # headless boot + tool execution
mix test test/minga/architecture_test.exs    # supervision tree shape
# No upward deps:
grep -rn "alias MingaEditor\|import MingaEditor" lib/minga/ lib/minga_agent/ | wc -l   # 0
```

---

## Wave 4: Rendering Contract + Editor Decomposition ✅ DONE

**Duration:** 3-4 weeks
**Agents:** 2 (one per track)
**Gate:** Render pipeline reads from narrow contract, chrome skips rebuild when unchanged

### Track A: RenderPipeline.Input contract (1 agent) ✅ DONE

**Completed:** 2026-04-01 — All three PRs merged in #1383.

**PR A-4.1: Define RenderPipeline.Input struct** ✅

Created `lib/minga_editor/render_pipeline/input.ex`. Input bundles ~21 fields from EditorState (13 top-level + workspace map with 11 fields), excluding ~13 GenServer-only fields. `Input.from_editor_state/1` builds it; `EditorState.apply_render_output/2` writes mutations back (Rule 2 compliant). The workspace is stored as a plain map field (not a WorkspaceState struct) so existing `state.workspace.X` pattern-matches work unchanged.

**PR A-4.2: Wire pipeline to read from Input** ✅

`RenderPipeline.run/1` takes `Input.t()`. `Renderer.render_buffer` does `Input.from_editor_state → run → apply_render_output`. All 6 pipeline stage modules thread Input. 27 files changed total. 8 downstream modules (TreeRenderer, ViewContext, StatusBarData, Title, Layout, SearchHighlight, SemanticWindow.Builder, MingaEditor.Editing) gained map-matching fallback clauses or widened specs to accept Input alongside EditorState. `TestHelpers.run_pipeline/1` wraps the conversion for existing pipeline tests.

**PR A-4.3: Chrome dirty tracking** ✅

`Input.chrome_fingerprint/1` hashes 17 chrome-relevant fields via `:erlang.phash2` (vim mode, mode_state, tab_bar, status_msg, nav_flash, file_tree, completion, hover_popup, signature_help, whichkey, picker_ui, prompt_ui, agent state, viewport dimensions, window splits, bottom_panel, git_status_panel, plus active buffer cursor and version). The chrome stage compares against the previous frame's fingerprint (process dictionary cache) and reuses the cached `Chrome` result when unchanged.

**Verification:**
```bash
make lint && mix test.llm
# RenderPipeline.run takes Input.t():
grep '@spec run(input())' lib/minga_editor/render_pipeline.ex
# Chrome skip log (set :log_level_render to :debug):
# "[render:chrome] skipped (fingerprint unchanged)" appears during idle viewing
```

---

### Track B: Extract Agent.RuntimeState (1 agent) ✅ DONE

**Files to read:**
- `lib/minga_editor/state/agent.ex` → current Agent state on EditorState
- `lib/minga_agent/session.ex` → what domain state sessions carry
- `lib/minga_editor/agent/events.ex` → how agent events mutate EditorState

**PR B-4.1: Create MingaAgent.RuntimeState**

Domain-only struct for agent state: `active_session_id`, `status`, `model_name`, `provider_name`.

**File to create:** `lib/minga_agent/runtime_state.ex`

**PR B-4.2: Compose RuntimeState into Editor's Agent state**

`MingaEditor.State.Agent` composes `MingaAgent.RuntimeState` with presentation fields (spinners, tab associations).

**File to modify:** `lib/minga_editor/state/agent.ex`

**Verification:**
```bash
make lint && mix test.llm
```

### Wave 4 gate

```bash
make lint && mix test.llm
# RenderPipeline.run takes Input.t(), not EditorState.t():
grep '@spec run(input())' lib/minga_editor/render_pipeline.ex
# Should find the spec (input type aliases Input.t())
# Chrome skip works:
grep 'chrome_prev_fingerprint' lib/minga_editor/render_pipeline.ex
# Should find the process dictionary cache check
```

Original gate command used `grep "def run(%MingaEditor.RenderPipeline.Input"}"` to check for a struct match in the function head. The actual implementation uses `@spec run(input())` with a type alias instead, which is idiomatic Elixir.

Old verification block (superseded):
```bash
# grep "def run(%MingaEditor.RenderPipeline.Input{}" lib/minga_editor/render_pipeline.ex
# Should find the function head
```

---

## Wave 5: Runtime Facade + API Gateway

**Duration:** 3-4 weeks
**Agents:** 3 (one per track)
**Gate:** External clients can connect via WebSocket, start agent sessions, execute tools, and receive streaming events through `MingaAgent.Runtime`

### Track A: MingaAgent.Runtime facade + Introspection (1 agent)

Two separate modules. The facade is stable `defdelegate` glue that rarely changes. Introspection evolves as external clients demand new metadata. Bundling them means the facade's API surface churns when you add a new introspection field.

**Files to read:**
- `lib/minga_agent/session_manager.ex` → the lifecycle API this facade delegates to
- `lib/minga_agent/tool/registry.ex` → ETS-backed tool lookup (read path)
- `lib/minga_agent/tool/executor.ex` → tool execution pipeline with advice integration
- `lib/minga_agent/tool/spec.ex` → tool spec struct (name, schema, callback, category, approval)
- `lib/minga_agent/runtime_state.ex` → domain state struct (status, session_id, model, provider)
- `lib/minga/runtime.ex` → headless entry point (boots supervision tree without frontend)
- `lib/minga/events.ex` → event topics and payload structs for cross-component notifications

**PR A-5.1: Create MingaAgent.Runtime facade**

Thin `defdelegate` module unifying SessionManager, Tool.Registry, Tool.Executor, and RuntimeState into one entry point. This is the stable API surface that Track C (API Gateway) binds to.

**File to create:** `lib/minga_agent/runtime.ex`

```elixir
defmodule MingaAgent.Runtime do
  @moduledoc """
  Public API for the Minga agent runtime.

  Unifies session management, tool execution, and introspection into
  a single entry point. External clients (API gateway, CLI tools, IDE
  extensions) should call this module rather than reaching into
  SessionManager, Tool.Registry, or Tool.Executor directly.

  All functions here are Layer 1 (MingaAgent.*). They work in both
  headless mode (`Minga.Runtime.start/1`) and full editor mode.
  """

  # ── Session lifecycle ────────────────────────────────────────────────────────

  @doc "Starts a new agent session. Returns `{:ok, session_id, pid}`."
  @spec start_session(keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  defdelegate start_session(opts \\ []), to: MingaAgent.SessionManager

  @doc "Stops a session by its human-readable ID."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  defdelegate stop_session(session_id), to: MingaAgent.SessionManager

  @doc "Sends a user prompt to a session."
  @spec send_prompt(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate send_prompt(session_id, prompt), to: MingaAgent.SessionManager

  @doc "Aborts the current operation on a session."
  @spec abort(String.t()) :: :ok | {:error, :not_found}
  defdelegate abort(session_id), to: MingaAgent.SessionManager

  @doc "Lists all active sessions as `{id, pid, metadata}` tuples."
  @spec list_sessions() :: [{String.t(), pid(), MingaAgent.SessionMetadata.t()}]
  defdelegate list_sessions(), to: MingaAgent.SessionManager

  @doc "Looks up the PID for a session ID."
  @spec get_session(String.t()) :: {:ok, pid()} | {:error, :not_found}
  defdelegate get_session(session_id), to: MingaAgent.SessionManager

  # ── Tool operations ─────────────────────────────────────────────────────────

  @doc "Executes a tool by name with the given arguments."
  @spec execute_tool(String.t(), map()) :: MingaAgent.Tool.Executor.result()
  defdelegate execute_tool(name, args), to: MingaAgent.Tool.Executor, as: :execute

  @doc "Returns all registered tool specs."
  @spec list_tools() :: [MingaAgent.Tool.Spec.t()]
  defdelegate list_tools(), to: MingaAgent.Tool.Registry, as: :all

  @doc "Looks up a tool spec by name."
  @spec get_tool(String.t()) :: {:ok, MingaAgent.Tool.Spec.t()} | :error
  defdelegate get_tool(name), to: MingaAgent.Tool.Registry, as: :lookup

  @doc "Returns true if a tool with the given name is registered."
  @spec tool_registered?(String.t()) :: boolean()
  defdelegate tool_registered?(name), to: MingaAgent.Tool.Registry, as: :registered?

  # ── Introspection ───────────────────────────────────────────────────────────

  @doc "Returns a capabilities manifest describing the runtime."
  @spec capabilities() :: MingaAgent.Introspection.capabilities_manifest()
  defdelegate capabilities(), to: MingaAgent.Introspection

  @doc "Returns structured descriptions of all registered tools."
  @spec describe_tools() :: [MingaAgent.Introspection.tool_description()]
  defdelegate describe_tools(), to: MingaAgent.Introspection

  @doc "Returns structured descriptions of all active sessions."
  @spec describe_sessions() :: [MingaAgent.Introspection.session_description()]
  defdelegate describe_sessions(), to: MingaAgent.Introspection
end
```

**Constraints:**
- `MingaAgent.Runtime` must have `@moduledoc` and `@spec` on every public function
- No logic beyond delegation. If removing all `defdelegate` lines and specs leaves more than ~10 lines, the module is doing too much.
- Do NOT add state. This module is a routing table, not a GenServer.

**Verification:**
```bash
make lint && mix test.llm
# Facade compiles and delegates correctly:
mix compile --warnings-as-errors
# Smoke test: in an iex session with headless runtime, call each function:
# MingaAgent.Runtime.list_tools() should return tool specs
# MingaAgent.Runtime.list_sessions() should return []
```

---

**PR A-5.2: Create MingaAgent.Introspection**

Pure data transform module. Queries Tool.Registry (ETS) and SessionManager (GenServer), formats structured descriptions. No GenServer, no side effects beyond those reads.

**File to create:** `lib/minga_agent/introspection.ex`

```elixir
defmodule MingaAgent.Introspection do
  @moduledoc """
  Runtime self-description for external clients.

  Produces structured capability manifests, tool descriptions, and
  session descriptions. All functions are pure data transforms over
  the current registry and session state. No side effects.

  External clients use this to discover what the runtime can do
  before making requests. The API gateway (Track C) exposes these
  as JSON-RPC methods.
  """

  alias MingaAgent.Tool.{Registry, Spec}
  alias MingaAgent.SessionManager

  @typedoc "Runtime capabilities manifest."
  @type capabilities_manifest :: %{
          version: String.t(),
          tool_count: non_neg_integer(),
          session_count: non_neg_integer(),
          tool_categories: [Spec.category()],
          features: [atom()]
        }

  @typedoc "Structured tool description for external clients."
  @type tool_description :: %{
          name: String.t(),
          description: String.t(),
          parameter_schema: map(),
          category: Spec.category(),
          approval_level: Spec.approval_level()
        }

  @typedoc "Structured session description for external clients."
  @type session_description :: %{
          session_id: String.t(),
          model_name: String.t(),
          provider_name: String.t(),
          status: atom(),
          created_at: DateTime.t()
        }

  @spec capabilities() :: capabilities_manifest()
  def capabilities do
    tools = Registry.all()
    sessions = SessionManager.list_sessions()
    categories = tools |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()

    %{
      version: Application.spec(:minga, :vsn) |> to_string(),
      tool_count: length(tools),
      session_count: length(sessions),
      tool_categories: categories,
      features: enabled_features()
    }
  end

  @spec describe_tools() :: [tool_description()]
  def describe_tools do
    Registry.all()
    |> Enum.map(fn %Spec{} = s ->
      %{
        name: s.name,
        description: s.description,
        parameter_schema: s.parameter_schema,
        category: s.category,
        approval_level: s.approval_level
      }
    end)
  end

  @spec describe_sessions() :: [session_description()]
  def describe_sessions do
    SessionManager.list_sessions()
    |> Enum.map(fn {id, _pid, metadata} ->
      %{
        session_id: id,
        model_name: metadata.model_name,
        provider_name: Map.get(metadata, :provider_name, "unknown"),
        status: Map.get(metadata, :status, :unknown),
        created_at: metadata.created_at
      }
    end)
  end

  @spec enabled_features() :: [atom()]
  defp enabled_features do
    features = [:tools, :sessions, :events]
    # Future: add :changesets when Track B lands, :buffer_fork when Wave 6 lands
    features
  end
end
```

**Constraints:**
- `MingaAgent.Introspection` is Layer 1. It reads from `MingaAgent.Tool.Registry` (Layer 1 ETS) and `MingaAgent.SessionManager` (Layer 1 GenServer). It must NOT import from `MingaEditor.*`.
- Return plain maps, not structs. External clients (API gateway) will JSON-encode these directly. Structs require `@derive JSON.Encoder` and add coupling. Maps are the right choice for a serialization boundary.
- The `capabilities/0` function is the "hello" handshake for external clients. Keep it cheap (two ETS reads + one GenServer call).

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga_agent/introspection_test.exs
```

---

**PR A-5.3: Register introspection as agent tools**

Register `describe_runtime` and `describe_tools` as tools in Tool.Registry so the agent itself can introspect its own capabilities. This is the "self-describing runtime" concept: an LLM can call `describe_runtime` to discover what tools are available.

**Files to modify:**
- `lib/minga_agent/tools.ex` → add `describe_runtime` and `describe_tools` tool definitions to `all/1`

**File to create:** `lib/minga_agent/tools/introspection.ex`

```elixir
defmodule MingaAgent.Tools.Introspection do
  @moduledoc "Agent tools for runtime self-description."

  alias MingaAgent.Introspection

  @spec describe_runtime(map()) :: {:ok, String.t()}
  def describe_runtime(_args) do
    caps = Introspection.capabilities()
    {:ok, format_capabilities(caps)}
  end

  @spec describe_tools(map()) :: {:ok, String.t()}
  def describe_tools(_args) do
    tools = Introspection.describe_tools()
    {:ok, format_tools(tools)}
  end

  @spec format_capabilities(map()) :: String.t()
  defp format_capabilities(caps) do
    """
    Minga Runtime v#{caps.version}
    Tools: #{caps.tool_count} (#{Enum.join(caps.tool_categories, ", ")})
    Sessions: #{caps.session_count}
    Features: #{Enum.join(caps.features, ", ")}
    """
    |> String.trim()
  end

  @spec format_tools([map()]) :: String.t()
  defp format_tools(tools) do
    tools
    |> Enum.map(fn t -> "- #{t.name} [#{t.category}]: #{t.description}" end)
    |> Enum.join("\n")
  end
end
```

**Constraints:**
- Tools return `{:ok, String.t()}` (formatted text), not raw maps. The agent consumes text, not structured data.
- Keep both tools in the `:agent` category with `:auto` approval (read-only introspection, no side effects).

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga_agent/tools/introspection_test.exs
# Verify tools are registered:
# MingaAgent.Tool.Registry.registered?("describe_runtime") should be true
```

---

### Track B: Changeset integration (1 agent)

Port the changeset experiment from the `experiments` branch into the Minga layer structure. Changesets are opt-in per session (not always-on, not sub-session scope). When enabled, file tools route through a changeset overlay instead of directly modifying the filesystem. Three-way merge on session completion handles concurrent edits.

**Why opt-in (not always-on):** ~70% of agent sessions write 0-2 files. Creating a filesystem overlay (50-250ms), maintaining hardlinks, and running a merge step on every session is waste for those sessions. The overhead only pays for itself on multi-file editing sessions where isolation and rollback matter.

**Files to read:**
- `experiments/changeset/lib/changeset.ex` (on `experiments` branch) → the facade API
- `experiments/changeset/lib/changeset/server.ex` → GenServer lifecycle, modifications, history, budget
- `experiments/changeset/lib/changeset/overlay.ex` → filesystem overlay (hardlinks, materialize, cleanup)
- `experiments/changeset/lib/changeset/merge.ex` → three-way merge using Myers diff
- `lib/minga/core/diff.ex` → existing `merge3/3` function (reuse this, don't port `Changeset.Merge`)
- `lib/minga_agent/session.ex` → session GenServer, status lifecycle, tool dispatch
- `lib/minga_agent/internal_state.ex` → session internal state struct
- `lib/minga_agent/tools/write_file.ex` → current direct-write tool
- `lib/minga_agent/tools/edit_file.ex` → current direct-edit tool
- `lib/minga_agent/tools/read_file.ex` → current direct-read tool

**PR B-5.1: Create Minga.Core.Overlay (Layer 0)**

Pure filesystem overlay utilities. No GenServer, no budget, no merge. This is a data structure + utility functions. The overlay concept has nothing agent-specific about it; it's a filesystem primitive.

**File to create:** `lib/minga/core/overlay.ex`

Port from `experiments/changeset/lib/changeset/overlay.ex` with these changes:
- Rename `Changeset.Overlay` to `Minga.Core.Overlay`
- Keep the same struct fields: `overlay_dir`, `project_root`, `build_dir`, `link_mode`
- Keep: `create/1`, `materialize_file/3`, `delete_file/2`, `deleted?/2`, `modified?/2`, `command_env/1`, `cleanup/1`
- Keep: `detect_link_mode/2`, `mirror_directory/3`, `link_or_copy/3`, `find_any_file/1`, `remove_symlinks_recursive/1`
- Add `@spec` to every public function, `@enforce_keys` on the struct
- Add `@moduledoc` explaining the hardlink overlay strategy

**Constraints:**
- Layer 0 module: must NOT import from `MingaAgent.*` or `MingaEditor.*`
- No `Process.sleep`, no GenServer calls, no side effects beyond filesystem operations
- `@skip_dirs` must include `_build`, `.git`, `.elixir_ls`, `node_modules`, `.hex` (same as experiment)
- `@symlink_dirs` must include `deps` (shared read-only)

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga/core/overlay_test.exs
```

```elixir
# test/minga/core/overlay_test.exs
defmodule Minga.Core.OverlayTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Overlay

  setup do
    dir = Path.join(System.tmp_dir!(), "overlay-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "hello.txt"), "original")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/foo.ex"), "defmodule Foo do\nend")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{project: dir}
  end

  test "create mirrors project with hardlinks", %{project: project} do
    {:ok, overlay} = Overlay.create(project)
    assert File.exists?(Path.join(overlay.overlay_dir, "hello.txt"))
    assert File.read!(Path.join(overlay.overlay_dir, "hello.txt")) == "original"
    Overlay.cleanup(overlay)
  end

  test "materialize_file replaces hardlink with new content", %{project: project} do
    {:ok, overlay} = Overlay.create(project)
    :ok = Overlay.materialize_file(overlay, "hello.txt", "modified")
    assert File.read!(Path.join(overlay.overlay_dir, "hello.txt")) == "modified"
    # Original is untouched
    assert File.read!(Path.join(project, "hello.txt")) == "original"
    Overlay.cleanup(overlay)
  end

  test "modified? detects changed files", %{project: project} do
    {:ok, overlay} = Overlay.create(project)
    refute Overlay.modified?(overlay, "hello.txt")
    :ok = Overlay.materialize_file(overlay, "hello.txt", "changed")
    assert Overlay.modified?(overlay, "hello.txt")
    Overlay.cleanup(overlay)
  end
end
```

---

**PR B-5.2: Create MingaAgent.Changeset GenServer (Layer 1)**

Port from `experiments/changeset/lib/changeset/server.ex`. Wraps `Minga.Core.Overlay` and adds: modification tracking, per-file undo history, budget system, and three-way merge via `Minga.Core.Diff.merge3/3` (NOT a ported `Changeset.Merge`).

**Files to create:**
- `lib/minga_agent/changeset.ex` → public API facade (replaces experiment's `Changeset` module)
- `lib/minga_agent/changeset/server.ex` → GenServer (port from experiment's `Changeset.Server`)

**Key differences from the experiment:**
- Uses `Minga.Core.Overlay` instead of `Changeset.Overlay`
- Uses `Minga.Core.Diff.merge3/3` instead of `Changeset.Merge.three_way/3` (verify the function signatures are compatible; the experiment splits on `"\n"` and calls `List.myers_difference/2`, while `Diff.merge3` takes line lists directly)
- GenServer is `:temporary` restart (same as experiment)
- Skip `Changeset.FastOverlay` (macOS APFS clones). The basic hardlink overlay works cross-platform. FastOverlay is a follow-up optimization.
- Broadcasts `Minga.Events` on merge completion and budget exhaustion

**File structure for `lib/minga_agent/changeset.ex`:**
```elixir
defmodule MingaAgent.Changeset do
  @moduledoc """
  In-memory changesets with filesystem overlays for agent editing.

  A changeset tracks file edits without modifying the original project.
  Edits are held in memory and materialized into a hardlink overlay where
  external tools (compilers, test runners, linters) see a coherent view
  of the project with changes applied.

  ## Lifecycle

      # Session starts with changeset: true
      {:ok, cs} = MingaAgent.Changeset.create("/path/to/project")

      # Agent file tools route through the changeset
      :ok = MingaAgent.Changeset.write_file(cs, "lib/math.ex", new_content)
      :ok = MingaAgent.Changeset.edit_file(cs, "lib/util.ex", "old", "new")

      # External tools see changes through the overlay
      {output, 0} = MingaAgent.Changeset.run(cs, "mix compile")

      # Session ends: merge back with three-way merge
      :ok = MingaAgent.Changeset.merge(cs)
  """

  alias MingaAgent.Changeset.Server

  @type changeset :: pid()

  @spec create(String.t(), keyword()) :: {:ok, changeset()} | {:error, term()}
  @spec write_file(changeset(), String.t(), binary()) :: :ok | {:error, term()}
  @spec edit_file(changeset(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @spec read_file(changeset(), String.t()) :: {:ok, binary()} | {:error, term()}
  @spec delete_file(changeset(), String.t()) :: :ok | {:error, term()}
  @spec undo(changeset(), String.t()) :: :ok | {:error, :nothing_to_undo}
  @spec reset(changeset()) :: :ok
  @spec merge(changeset()) :: :ok | {:ok, :merged_with_conflicts, list()} | {:error, term()}
  @spec discard(changeset()) :: :ok
  @spec run(changeset(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  @spec overlay_path(changeset()) :: String.t()
  @spec modified_files(changeset()) :: %{modified: [String.t()], deleted: [String.t()]}
  @spec summary(changeset()) :: [map()]
  @spec record_attempt(changeset()) :: {:ok, pos_integer()} | {:budget_exhausted, pos_integer(), pos_integer()}
  @spec attempt_info(changeset()) :: %{attempts: non_neg_integer(), budget: pos_integer() | :unlimited}

  # All functions delegate to Server via GenServer.call
  # (Port the delegation bodies from experiments/changeset/lib/changeset.ex)
end
```

**Constraints:**
- `MingaAgent.Changeset.Server` starts under `MingaAgent.Supervisor` (DynamicSupervisor), same as sessions
- The `merge/1` call must use `Minga.Core.Diff.merge3/3`. Verify the interface: the experiment's `Changeset.Merge.three_way/3` takes `(ancestor_string, ours_string, theirs_string)` and splits on `"\n"` internally. `Minga.Core.Diff.merge3/3` may take line lists directly. Adapt the call site accordingly.
- Broadcast `:changeset_merged` event on successful merge, `:changeset_budget_exhausted` on budget exhaustion. Add these topics and payload structs to `Minga.Events`.
- `terminate/2` must call `Overlay.cleanup/1` (same as experiment) to prevent tmp dir leaks

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga_agent/changeset/server_test.exs
```

---

**PR B-5.3: Wire Session to optionally use Changeset**

When `changeset: true` is passed to `SessionManager.start_session/1`, the session creates a `MingaAgent.Changeset` in its `init/1` and routes file tool calls through it.

**Files to modify:**
- `lib/minga_agent/internal_state.ex` → add `changeset: pid() | nil` field
- `lib/minga_agent/session.ex` → create changeset in `init/1` when opted in, merge/discard in `terminate/2`
- `lib/minga_agent/tools/write_file.ex` → check session's changeset; route through it if present
- `lib/minga_agent/tools/edit_file.ex` → same routing
- `lib/minga_agent/tools/multi_edit_file.ex` → same routing
- `lib/minga_agent/tools/read_file.ex` → read from changeset if present (sees modified files)
- `lib/minga_agent/tools/shell.ex` → run commands in overlay directory if changeset present

**Tool routing pattern:**
```elixir
# In write_file.ex callback:
defp do_write(path, content, session_pid) do
  case get_changeset(session_pid) do
    {:ok, cs} -> MingaAgent.Changeset.write_file(cs, path, content)
    :none -> File.write(path, content)  # existing behavior
  end
end
```

The exact mechanism for tools to access the session's changeset depends on how tools currently receive context. Read the tool callback signatures in `lib/minga_agent/tools/*.ex` to determine whether the session PID or a context map is passed. The key constraint: tools must not need to know whether a changeset is active. They call a routing function that checks and delegates.

**Budget integration:** When `MingaAgent.Changeset.record_attempt/1` returns `{:budget_exhausted, attempts, budget}`, the session should:
1. Broadcast a `:changeset_budget_exhausted` event
2. Set session status to `:error` with a descriptive message
3. NOT auto-discard the changeset (let the user/client decide)

**Merge on completion:** When the session transitions to `:idle` after the agent finishes, or on explicit `stop_session/1`:
1. If changeset is active and dirty, call `MingaAgent.Changeset.merge/1`
2. If merge returns `:ok`, broadcast `:changeset_merged` event
3. If merge returns `{:ok, :merged_with_conflicts, details}`, broadcast `:changeset_conflict` event with the details. The Editor (or API client) handles conflict resolution.
4. If the session is being discarded (user aborts), call `MingaAgent.Changeset.discard/1` instead of merge

**Constraints:**
- Do NOT modify `MingaAgent.Session` directly for the tool routing. The session is 1500+ lines. Instead, create a `MingaAgent.Changeset.ToolRouter` helper that tools call. This keeps the changeset awareness out of the Session GenServer.
- The `changeset` field on InternalState is `pid() | nil`. The session monitors the changeset pid (it's a GenServer under `MingaAgent.Supervisor`). If the changeset crashes, the session clears the field and continues without isolation (graceful degradation).
- Pass `project_root` from the session's context to `MingaAgent.Changeset.create/2`. The project root is available from `Minga.Project.root/0` or the session's init opts.

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga_agent/changeset/tool_router_test.exs
# Integration test: start a session with changeset: true, write a file,
# verify the original is untouched, merge, verify the original is updated.
mix test test/minga_agent/changeset/integration_test.exs
```

---

### Track C: API Gateway (1 agent)

WebSocket + JSON-RPC gateway exposing `MingaAgent.Runtime` to external clients. Uses Bandit + WebSock (~5 deps, all pure Elixir). Not Phoenix (15+ transitive deps for a single WebSocket endpoint). Not raw `:gen_tcp` (reimplementing RFC 6455 is not "build it right"). Not Unix domain socket with binary protocol (limits client ecosystem to custom implementations; WebSocket + JSON-RPC is universal).

**Important: the macOS GUI keeps its Port protocol.** The Port is binary, zero-overhead, frame-paced, with automatic lifecycle management (BEAM exits, pipe closes, Swift process gets EOF). WebSocket adds latency, framing overhead, and reconnection complexity that have zero benefit for a co-located renderer. The API gateway is for external tools (IDEs, CLI agents, CI pipelines, web dashboards) that want semantic interaction, not frame rendering.

**Chrome opcodes (0x70-0x78) are NOT exposed to API clients.** Chrome is rendering data optimized for native GUI widgets. API clients get semantic queries through the Runtime facade: `list_buffers`, `get_file_tree`, etc. Same underlying data, completely different abstraction level.

**Files to read:**
- `lib/minga_agent/runtime.ex` → the facade this gateway binds to (Track A output)
- `lib/minga_agent/session_manager.ex` → session lifecycle API
- `lib/minga/events.ex` → event bus for streaming notifications
- `lib/minga_agent/session.ex` → event subscription pattern (`subscribe/2` uses raw `send/2`)
- `lib/minga/application.ex` → supervision tree (gateway starts under MingaAgent.Supervisor)

**PR C-5.1: Add Bandit + WebSock dependencies**

**File to modify:** `mix.exs`

Add to deps:
```elixir
{:bandit, "~> 1.6"},
{:websock_adapter, "~> 0.5"}
```

Bandit pulls in `websock`, `thousand_island`, `hpax`, and `plug` as transitive deps. `plug` is already in the dep tree (optional dep of `req`). Net new deps: ~4.

**Constraints:**
- Run `mix deps.get && mix compile --warnings-as-errors` to verify no conflicts with existing deps
- Do NOT add Phoenix, Ecto, or any framework-level deps

**Verification:**
```bash
mix deps.get
mix compile --warnings-as-errors
make lint
```

---

**PR C-5.2: Create Gateway modules**

Five modules in `lib/minga_agent/gateway/`:

**Files to create:**
- `lib/minga_agent/gateway/server.ex` → GenServer that starts Bandit listener
- `lib/minga_agent/gateway/router.ex` → Plug router: `/ws` routes to WebSocket, `/health` returns 200
- `lib/minga_agent/gateway/websocket.ex` → WebSock behaviour implementation
- `lib/minga_agent/gateway/json_rpc.ex` → Pure dispatch: decode JSON-RPC request, call Runtime, encode response
- `lib/minga_agent/gateway/event_stream.ex` → Subscribes to Minga.Events, pushes JSON-RPC notifications to connected clients

**`gateway/server.ex`:**
```elixir
defmodule MingaAgent.Gateway.Server do
  @moduledoc """
  Starts and owns the Bandit HTTP/WebSocket listener.

  Does not start by default. Started on-demand when the headless runtime
  boots with `gateway: true` or when `MingaAgent.Runtime.start_gateway/1`
  is called. The Editor never starts this.
  """
  use GenServer

  @default_port 4820

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)

    {:ok, bandit_pid} =
      Bandit.start_link(
        plug: MingaAgent.Gateway.Router,
        port: port,
        scheme: :http
      )

    Minga.Log.info(:agent, "[Gateway] listening on port #{port}")
    {:ok, %{bandit: bandit_pid, port: port}}
  end

  @impl true
  def terminate(_reason, %{bandit: pid}) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
    :ok
  end
end
```

**`gateway/router.ex`:**
```elixir
defmodule MingaAgent.Gateway.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(MingaAgent.Gateway.WebSocket, [], timeout: 60_000)
    |> halt()
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

**`gateway/websocket.ex`:**
```elixir
defmodule MingaAgent.Gateway.WebSocket do
  @moduledoc """
  WebSocket handler for external clients.

  Each connection gets its own process (Bandit does this automatically).
  On connect, subscribes to relevant Minga.Events topics for push
  notifications. Incoming frames are JSON-RPC requests dispatched
  through `Gateway.JsonRpc`.
  """
  @behaviour WebSock

  alias MingaAgent.Gateway.{JsonRpc, EventStream}

  @impl true
  def init(_opts) do
    event_state = EventStream.subscribe_all()
    {:ok, %{events: event_state}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case JsonRpc.dispatch(text) do
      {:ok, response_json} -> {:push, {:text, response_json}, state}
      {:error, error_json} -> {:push, {:text, error_json}, state}
      :notification -> {:ok, state}  # no response for notifications
    end
  end

  @impl true
  def handle_info({:minga_event, _topic, _payload} = event, state) do
    case EventStream.format_notification(event) do
      {:ok, json} -> {:push, {:text, json}, state}
      :skip -> {:ok, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
```

**`gateway/json_rpc.ex`:**

Pure dispatch module. Takes a JSON string, decodes the JSON-RPC request, pattern-matches on the method name, calls `MingaAgent.Runtime.*`, and returns a JSON-RPC response string. No state, no side effects beyond what the delegated function does.

```elixir
defmodule MingaAgent.Gateway.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 request dispatch.

  Pure function: decode request → call MingaAgent.Runtime → encode response.
  Easy to test in isolation without WebSocket machinery.
  """

  alias MingaAgent.Runtime

  @spec dispatch(String.t()) :: {:ok, String.t()} | {:error, String.t()} | :notification
  def dispatch(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}} ->
        result = call_method(method, params)
        {:ok, encode_response(id, result)}

      {:ok, %{"jsonrpc" => "2.0", "method" => method, "params" => params}} ->
        # Notification (no id): fire and forget
        call_method(method, params)
        :notification

      {:ok, _} ->
        {:error, encode_error(nil, -32600, "Invalid Request")}

      {:error, _} ->
        {:error, encode_error(nil, -32700, "Parse error")}
    end
  end

  # ── Method dispatch ─────────────────────────────────────────────────────────

  @spec call_method(String.t(), map()) :: {:ok, term()} | {:error, term()}
  defp call_method("runtime.capabilities", _params), do: {:ok, Runtime.capabilities()}
  defp call_method("runtime.describe_tools", _params), do: {:ok, Runtime.describe_tools()}
  defp call_method("runtime.describe_sessions", _params), do: {:ok, Runtime.describe_sessions()}
  defp call_method("session.start", params), do: start_session(params)
  defp call_method("session.stop", %{"session_id" => id}), do: wrap(Runtime.stop_session(id))
  defp call_method("session.prompt", %{"session_id" => id, "prompt" => p}), do: wrap(Runtime.send_prompt(id, p))
  defp call_method("session.abort", %{"session_id" => id}), do: wrap(Runtime.abort(id))
  defp call_method("session.list", _params), do: {:ok, Runtime.describe_sessions()}
  defp call_method("tool.execute", %{"name" => n, "args" => a}), do: Runtime.execute_tool(n, a)
  defp call_method("tool.list", _params), do: {:ok, Runtime.describe_tools()}
  defp call_method(method, _params), do: {:error, {:method_not_found, method}}

  # ── Helpers ─────────────────────────────────────────────────────────────────
  # (encode_response, encode_error, start_session helper, wrap helper)
end
```

**`gateway/event_stream.ex`:**

Subscribes to `Minga.Events` topics on behalf of a WebSocket connection. Formats domain events as JSON-RPC notifications for push delivery. Exposes the domain events (`text_delta`, `tool_started`, `tool_ended`, `status_changed`, `approval_pending`), NOT rendered state.

```elixir
defmodule MingaAgent.Gateway.EventStream do
  @moduledoc """
  Event subscription and JSON-RPC notification formatting.

  Subscribes to domain events from Minga.Events. Each WebSocket
  connection calls `subscribe_all/0` in its init and receives
  `{:minga_event, topic, payload}` messages that `format_notification/1`
  converts to JSON-RPC notification strings.
  """

  @topics [
    :agent_session_stopped,
    :buffer_saved,
    :buffer_changed,
    :log_message,
    :changeset_merged,
    :changeset_budget_exhausted
  ]

  @spec subscribe_all() :: :ok
  def subscribe_all do
    Enum.each(@topics, &Minga.Events.subscribe/1)
    :ok
  end

  @spec format_notification({:minga_event, atom(), term()}) :: {:ok, String.t()} | :skip
  def format_notification({:minga_event, topic, payload}) do
    case encode_event(topic, payload) do
      nil -> :skip
      params -> {:ok, JSON.encode!(%{jsonrpc: "2.0", method: "event.#{topic}", params: params})}
    end
  end

  # Per-topic encoders that convert typed structs to JSON-safe maps
  @spec encode_event(atom(), term()) :: map() | nil
  defp encode_event(:agent_session_stopped, %{session_id: id, reason: reason}) do
    %{session_id: id, reason: inspect(reason)}
  end
  defp encode_event(:log_message, %{text: text, level: level}) do
    %{text: text, level: level}
  end
  defp encode_event(:buffer_saved, %{path: path}) do
    %{path: path}
  end
  # ... other topics
  defp encode_event(_topic, _payload), do: nil
end
```

**Constraints:**
- Gateway.Server starts under `MingaAgent.Supervisor`, NOT `Minga.Runtime.Supervisor`. It's a Layer 1 service.
- Gateway does NOT start by default. Add a `start_gateway/1` function to `MingaAgent.Runtime` that starts it on-demand. The Editor boot path (`Minga.Application`) never starts it.
- `Minga.Runtime.start/1` (headless entry point) accepts a `gateway: true` option that starts the gateway after the supervision tree is up.
- Default port: 4820. Configurable via opts.
- `json_rpc.ex` is a pure function module. No state, no GenServer. All dispatch goes through `MingaAgent.Runtime` (never directly to SessionManager or Tool.Executor).
- JSON-RPC 2.0 compliance: method names use dot notation (`session.start`, `tool.execute`), errors use standard codes (-32700 parse, -32600 invalid, -32601 method not found, -32602 invalid params, -32603 internal).
- Event streaming pushes domain events, NOT rendered state. API clients get incremental deltas (`text_delta`, `tool_started`), not full chat message lists.

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga_agent/gateway/json_rpc_test.exs
mix test test/minga_agent/gateway/event_stream_test.exs
mix test test/minga_agent/gateway/integration_test.exs
```

```elixir
# test/minga_agent/gateway/json_rpc_test.exs
# Test the pure dispatch function without WebSocket machinery:
test "runtime.capabilities returns a capabilities manifest" do
  request = JSON.encode!(%{jsonrpc: "2.0", method: "runtime.capabilities", params: %{}, id: 1})
  {:ok, response_json} = JsonRpc.dispatch(request)
  response = JSON.decode!(response_json)
  assert response["id"] == 1
  assert response["result"]["tool_count"] >= 0
end

test "unknown method returns method_not_found error" do
  request = JSON.encode!(%{jsonrpc: "2.0", method: "bogus", params: %{}, id: 2})
  {:error, response_json} = JsonRpc.dispatch(request)
  response = JSON.decode!(response_json)
  assert response["error"]["code"] == -32601
end
```

---

**PR C-5.3: Wire gateway startup into Runtime**

**Files to modify:**
- `lib/minga_agent/runtime.ex` → add `start_gateway/1` function
- `lib/minga/runtime.ex` → accept `gateway: true` opt, start gateway after supervision tree
- `lib/minga_agent/supervisor.ex` → no changes needed (gateway starts as a child dynamically)

**Verification:**
```bash
make lint && mix test.llm
# End-to-end test: boot headless runtime with gateway, connect via WebSocket,
# send JSON-RPC request, receive response:
mix test test/minga_agent/gateway/integration_test.exs
```

```elixir
# test/minga_agent/gateway/integration_test.exs
defmodule MingaAgent.Gateway.IntegrationTest do
  use ExUnit.Case, async: false
  # async: false because we start a full supervision tree + network listener

  test "external client connects and lists tools via JSON-RPC" do
    {:ok, sup} = Minga.Runtime.start(gateway: [port: 0])  # port 0 = random available
    # Get the actual port from the gateway server
    # Connect via :gun or Mint WebSocket client
    # Send: {"jsonrpc":"2.0","method":"tool.list","params":{},"id":1}
    # Assert response contains tool descriptions
    Supervisor.stop(sup)
  end
end
```

The exact WebSocket client library for tests depends on what's available. Options: `:gun` (Erlang, already available via Finch's deps), `Mint.WebSocket`, or `WebSockex`. Check `mix.lock` for what's already in the dep tree before adding a new test-only dep.

### Wave 5 gate: EXTERNAL CLIENTS CONNECT

This is the second product gate. After this, Minga is a platform.

```bash
make lint
mix test.llm          # all pass
# Runtime facade works:
mix test test/minga_agent/runtime_test.exs
mix test test/minga_agent/introspection_test.exs
# Changeset works:
mix test test/minga_agent/changeset/
# Gateway works:
mix test test/minga_agent/gateway/
# End-to-end: boot headless + gateway, connect via WebSocket, execute a tool:
mix test test/minga_agent/gateway/integration_test.exs
# No upward deps:
grep -rn "alias MingaEditor\|import MingaEditor" lib/minga/ lib/minga_agent/ | wc -l   # 0
```

---

## Wave 6: Buffer Forking + Polish

**Duration:** 3-4 weeks
**Agents:** 2 (one per track)
**Gate:** Agent sessions use buffer forks for open files, boundary allowlist is empty, docs are updated

`Minga.Buffer.Fork` already exists and works (three-way merge via `Minga.Core.Diff.merge3`). This wave wires it into agent sessions as a complement to changesets, cleans up remaining boundary violations, and updates documentation.

**Key insight: Buffer.Fork and Changeset are complementary, not alternatives.** Buffer.Fork handles in-memory isolation for files that are open in a buffer (instant, no disk I/O, gives undo integration). Changeset handles filesystem-level isolation for files that aren't open in a buffer, or for running external tools that need a coherent filesystem view. A session can use both: Buffer.Fork for the 5 files the user has open, Changeset overlay for the 200 files the compiler needs to see.

### Track A: Buffer.Fork wiring + self-description tools (1 agent)

**Files to read:**
- `lib/minga/buffer/fork.ex` → existing fork implementation (create, content, merge, ancestor_content)
- `lib/minga/buffer/server.ex` → Buffer.Server GenServer (the parent that forks are created from)
- `lib/minga_agent/changeset.ex` → changeset API (Wave 5 Track B output)
- `lib/minga_agent/tools/write_file.ex` → file tool routing (Wave 5 Track B modified this)
- `lib/minga_agent/tools/edit_file.ex` → same
- `lib/minga_agent/tools/read_file.ex` → same
- `lib/minga_agent/internal_state.ex` → session internal state (has `changeset` field from Wave 5)
- `lib/minga_agent/introspection.ex` → introspection module (Wave 5 Track A output)

**PR A-6.1: Wire Buffer.Fork into agent tool routing**

Extend the tool routing from Wave 5 Track B (which routes through Changeset) to also use Buffer.Fork for files that are open in a buffer.

**Decision tree for file tools:**
```
Agent writes to "lib/foo.ex":
  1. Is there an open Buffer.Server for this path?
     YES → Is there already a fork for this buffer?
           YES → Route through fork
           NO  → Create fork (Buffer.Fork.create(parent_pid)), store in session state, route through fork
     NO  → Is there an active changeset?
           YES → Route through changeset (filesystem overlay)
           NO  → Direct file write (existing behavior)
```

**Files to modify:**
- `lib/minga_agent/internal_state.ex` → add `buffer_forks: %{String.t() => pid()}` field (path to fork pid)
- `lib/minga_agent/changeset/tool_router.ex` → rename to `lib/minga_agent/tool_router.ex` (it now handles both changesets and forks), add fork routing logic
- `lib/minga_agent/tools/write_file.ex` → use updated tool router
- `lib/minga_agent/tools/edit_file.ex` → use updated tool router
- `lib/minga_agent/tools/read_file.ex` → read from fork if available

**Fork lifecycle:**
- Forks are created lazily (first write to an open buffer creates the fork)
- Forks are stored in session state as `%{path => fork_pid}`
- Session monitors each fork pid. If a fork crashes, remove it from state and fall back to changeset or direct write.
- On session completion:
  - For each fork, call `Buffer.Fork.merge/1`
  - If merge returns `{:ok, merged_text}`, apply the merged text to the parent buffer via `Buffer.Server.replace_content/3`
  - If merge returns `{:conflict, hunks}`, broadcast a `:buffer_fork_conflict` event. The Editor (or API client) handles conflict resolution.

**Constraints:**
- Buffer.Fork is Layer 0 (`Minga.Buffer.*`). Tool routing is Layer 1 (`MingaAgent.*`). The tool router calls `Buffer.Fork.create/1` and `Buffer.Fork.merge/1` (downward dependency, correct).
- Finding open buffers by path: use `Minga.Buffer.Registry` (the `:unique` Registry). Look up the buffer pid by path. If no buffer is registered for the path, fall back to changeset/direct write.
- Fork creation is synchronous in the tool callback. `Buffer.Fork.create/1` snapshots the parent's content (one GenServer call), which is fast (milliseconds for any reasonable file size).
- Do NOT create forks eagerly at session start. Lazy creation avoids forking buffers the agent never touches.

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga_agent/tool_router_test.exs
```

```elixir
# test/minga_agent/tool_router_test.exs (additions to existing test from Wave 5)
test "routes through buffer fork when buffer is open" do
  # Start a buffer for "lib/foo.ex" with known content
  {:ok, buf} = start_supervised({Minga.Buffer.Server, content: "original", path: "lib/foo.ex"})
  # Register it in the buffer registry
  Registry.register(Minga.Buffer.Registry, "lib/foo.ex", buf)

  # Create session state with fork routing enabled
  state = %{buffer_forks: %{}, changeset: nil}

  # Route a write: should create a fork
  {:ok, new_state} = ToolRouter.route_write(state, "lib/foo.ex", "modified")
  assert Map.has_key?(new_state.buffer_forks, "lib/foo.ex")

  # Original buffer is untouched
  assert Minga.Buffer.Server.content(buf) == "original"

  # Fork has the new content
  fork_pid = new_state.buffer_forks["lib/foo.ex"]
  assert Minga.Buffer.Fork.content(fork_pid) == "modified"
end
```

---

**PR A-6.2: Add `:changesets` and `:buffer_fork` to Introspection features**

Update `MingaAgent.Introspection.enabled_features/0` to report `:changesets` and `:buffer_fork` as available features. External clients use this to know whether they can request changeset-enabled sessions.

**File to modify:** `lib/minga_agent/introspection.ex`

**Verification:**
```bash
make lint && mix test.llm
mix test test/minga_agent/introspection_test.exs
```

---

### Track B: Boundary cleanup + documentation (1 agent)

**PR B-6.1: Resolve remaining Layer 1 → Layer 2 violations**

The 9 pre-existing violations tracked in #1368 must be resolved. Same technique as Wave 1 Track B: replace direct imports with `Minga.Events` broadcasts or restructure so the dependency points downward.

**Files to read:**
- `#1368` issue → the specific 9 violations and which files contain them
- `credo/checks/dependency_direction_check.exs` → the `@allowed_references` list (these are the violations)
- `lib/minga/events.ex` → existing event topics for the broadcast pattern

**For each violation:**
1. Read the violating module and find the `MingaEditor.*` reference
2. Determine whether it's a function call, type reference, or docstring reference
3. For function calls: replace with `Minga.Events.broadcast/2` (add new event topic if needed, have the Editor subscribe in its startup)
4. For type references: move the type to Layer 0 or Layer 1, or use a behaviour/protocol
5. For docstring references: rewrite the doc to reference the concept, not the module

**Constraints:**
- After this PR, `@allowed_references` in the credo check must be empty (or contain only structural dispatch entries that archie has approved)
- `make lint` must pass with zero violations
- Each violation fix must have a test verifying the behavior still works (the event is received, the type is correct, etc.)

**Verification:**
```bash
make lint && mix test.llm
# Verify allowlist is empty:
grep -A 20 "@allowed_references" credo/checks/dependency_direction_check.exs
# Should show only structural dispatch entries, no Layer 1→2 violations
```

---

**PR B-6.2: Documentation pass**

Update docs to reflect the runtime-first architecture.

**Files to modify:**
- `docs/ARCHITECTURE.md` → add "Headless Runtime" section describing `Minga.Runtime`, the three-namespace layer architecture, and the API gateway. Update the supervision tree diagram to show `MingaAgent.Supervisor` as a top-level peer.
- `docs/ARCHITECTURE.md` → add "API Gateway" section describing WebSocket + JSON-RPC, method names, event streaming.
- `AGENTS.md` → update the module grouping table to reflect the three-namespace layout. Add `MingaAgent.*` and `MingaEditor.*` module directories.
- `AGENTS.md` → add a "Changeset" subsection under "New or modified agent tool" explaining the opt-in changeset pattern and Buffer.Fork routing.
- `README.md` → add a brief section on the headless runtime and API gateway for external integrators.

**Constraints:**
- Follow the project's documentation voice (read `docs/EXTENSIBILITY.md` or `docs/FOR-EMACS-USERS.md` for the tone). Why before how. Concrete examples. No em-dashes.
- Cross-reference related docs. The architecture doc should link to PROTOCOL.md, GUI_PROTOCOL.md, and the new API gateway section.
- Do NOT document FastOverlay, remote GUI connections, or other future work that hasn't been built. Document what exists.

**Verification:**
```bash
# All links in docs are valid:
grep -rn '\[.*\](.*\.md)' docs/ | while read line; do
  file=$(echo "$line" | grep -oP '\(\K[^)]+\.md')
  if [ ! -f "docs/$file" ] && [ ! -f "$file" ]; then
    echo "BROKEN LINK: $line"
  fi
done
# Expected: no broken links
```

### Wave 6 gate: PLATFORM POLISHED

```bash
make lint
mix test.llm
# Buffer.Fork routing works:
mix test test/minga_agent/tool_router_test.exs
# Boundary violations are zero:
grep "@allowed_references" credo/checks/dependency_direction_check.exs
# Should show only structural dispatch entries
# No upward deps:
grep -rn "alias MingaEditor\|import MingaEditor" lib/minga/ lib/minga_agent/ | wc -l   # 0
```

---

## Summary

| Wave | Duration | Agents | What ships | Hard gate |
|------|----------|--------|-----------|-----------|
| 1 | 1 week | 3 | Boundary enforcement, upward deps severed, timers quarantined | `make lint` clean, 0 upward deps |
| 2 | 1 week | 1 | Three namespaces: `Minga.*`, `MingaAgent.*`, `MingaEditor.*` | Namespace boundary enforced |
| 3 | 3 weeks | 3 | Tool registry, session manager, headless entry point | **Headless runtime boots** |
| 4 | 3-4 weeks | 2 | RenderPipeline.Input contract, chrome dirty tracking | Pipeline reads narrow contract |
| 5 | 3-4 weeks | 3 | Runtime facade + introspection, changeset integration, WebSocket + JSON-RPC gateway | **External clients connect** |
| 6 | 3-4 weeks | 2 | Buffer.Fork routing, boundary violations to zero, documentation pass | Allowlist empty, docs updated |

**Total: ~15-18 weeks, 2-3 agents average, peak 3.**

**The two product gates:**
1. Wave 3: headless runtime works (Minga becomes a runtime)
2. Wave 5: external clients connect (Minga becomes a platform)

---

## Rules for agents executing this plan

**Read the wave you're in, not the whole plan.** Each wave is self-contained. If you're working on Wave 3 Track B, read Track B's items and the Wave 3 gate. You don't need context from Wave 5.

**The boundary check is your safety net.** After Wave 1 Track A lands, `make lint` catches layer violations. If your PR adds an import that violates boundaries, the build tells you. Fix it before requesting review.

**After Wave 2, namespaces are the rules.** `Minga.*` is Layer 0. `MingaAgent.*` is Layer 1. `MingaEditor.*` is Layer 2. If you're writing code in `lib/minga_agent/` and you type `alias MingaEditor.`, stop. That's an upward dependency. Find another way.

**One PR per item.** Don't bundle A-3.1 and A-3.2. Don't "clean up" adjacent code. Unrelated changes create merge conflicts with parallel tracks.

**Test your changes.** Every item has an acceptance criterion. Write a test. Run `make lint && mix test.llm` before requesting review.

**Update this document when your track finishes.** After all items in your track are merged to `main` and the verification commands pass:

1. Add a row to the **Progress Log** at the bottom of this file with the date, wave/track, PR numbers, and what shipped.
2. If any item's scope changed during implementation (files were different than listed, a constraint was wrong, an extra PR was needed), **update that item's section in-place** so the next agent reading it sees accurate information, not stale instructions.
3. If you discovered something that affects a future wave (an API that doesn't exist yet, a file that moved, a constraint that no longer holds), add a bullet to the **Discoveries** section tagging the affected wave.
4. Commit the doc update as part of your final PR in the track.

---

## Progress Log

| Date | Wave / Track | PRs | What shipped |
|------|-------------|-----|-------------|
| pre-plan | Wave 1 (prior work) | various | A1-A4, B2-B3, C1-C4 from UI stability plan already shipped |
| 2026-03-31 | Wave 1 / Track B | #1366 | Severed all 7 upward Layer 0/1 → Layer 2 deps: LogMessageEvent + FaceOverridesChangedEvent added to Events; LSP (4 sites), Git, Buffer.Server, Agent.Session replaced direct Editor calls with broadcasts |
| 2026-03-31 | Wave 1 / Track A | #1364 | Boundary check promoted to hard failure. Existing `Minga.Credo.DependencyDirectionCheck` already covered everything the planned `mix check.layers` task would do; flipped `exit_status: 0` to default (non-zero). |
| 2026-03-31 | Wave 1 / Track C | — | All timer quarantine guards already in place; verified all sites in editor.ex and sub-modules; updated plan status and fixed verification command |
| 2026-03-31 | Wave 2 / NS-1 | #1367 | Created `MingaAgent.*` namespace: 58 agent domain modules moved from `lib/minga/agent/` to `lib/minga_agent/`. Presentation modules stayed. |
| 2026-03-31 | Wave 2 / NS-2+NS-3 | #1370 | Created `MingaEditor.*` namespace: 276 lib + 248 test files moved. Updated `DependencyDirectionCheck` for three-namespace architecture. NS-3 merged into NS-2. 9 pre-existing Layer 1→2 violations tracked in #1368. |
| 2026-04-01 | Wave 4 / Track A | #1383 | RenderPipeline.Input contract: (A-4.1) Input struct with from_editor_state/1 + apply_render_output/2, (A-4.2) pipeline wired to use Input.t() across all 6 stages, 27 files updated, (A-4.3) chrome dirty tracking via fingerprint, skips rebuild when chrome inputs unchanged. |
| 2026-04-01 | Wave 4 / Track B | #1382 | Extracted `MingaAgent.RuntimeState` (4 domain fields: active_session_id, status, model_name, provider_name). Composed into `MingaEditor.State.Agent` via `runtime` field. Updated 6 lib files + 15 test files. |
| 2026-04-01 | Wave 5 / Track C | #1385 | WebSocket + JSON-RPC API gateway: Bandit + WebSock deps, 7 new modules (Runtime facade, Introspection, Gateway.Server/Router/WebSocket/JsonRpc/EventStream). Gateway starts on-demand, default port 4820. 34 new tests including WS integration. Also created MingaAgent.Runtime and MingaAgent.Introspection (planned for Track A) since the gateway depends on them. |

---

## Discoveries

Notes from completed tracks that affect future waves. Tag the wave so agents can find relevant context.

- **Wave 2 NS-1:** `lib/minga/tool/` is the extension/plugin management system (installs LSP servers, formatters, etc.), NOT the AI agent tool infrastructure described in the plan. The plan's NS-1 section listed non-existent files (`spec.ex`, `registry.ex`, `executor.ex`, `approval.ex`, `schema.ex`). `lib/minga/tool/` stays as `Minga.Tool.*` — it's a Layer 1 service and doesn't belong in `MingaAgent.*`. Future Wave 3 AI agent tool infrastructure will create `MingaAgent.Tool.*` afresh.

- **Wave 2 NS-1:** `edit_boundary.ex` was listed as a "presentation module" that should stay for NS-2, but it's actually a pure domain struct (no presentation deps). Moved to `lib/minga_agent/edit_boundary.ex` → `MingaAgent.EditBoundary` in NS-1. NS-2 no longer needs to handle it.

- **Wave 2 NS-1:** Used a Python migration script (`scripts/ns1_migrate.py`) to automate the rename. The script: (1) git-moves 57 lib files + 47 test files, (2) applies word-boundary aware module renames across 146 files. Key edge case: `test/minga_agent/providers/pi_rpc_test.exs` needed its `@fake_pi` relative path adjusted from `../../../` to `../../` after the directory depth changed.

- **Wave 2 NS-2:** The rename from `Minga.Editor` to `MingaEditor` exposed bare `Editor.` references in code that used `alias Minga.Editor` and then called `Editor.start_link`. After the rename, `alias MingaEditor` doesn't bring `Editor` into scope. Fixed 42 files with a script that replaced bare `Editor.` with `MingaEditor.` in code (not comments).

- **Wave 2 NS-2:** The rename exposed 9 pre-existing Layer 1 → Layer 2 violations that were invisible when all modules lived under `Minga.*`. These are tracked in #1368. Added to `@allowed_references` temporarily.

- **Wave 2 NS-2:** NS-3 (update boundary check for namespaces) was merged into NS-2 since the credo check needed fixing as part of the rename anyway. The check now recognizes `MingaEditor.*` as Layer 2 and `MingaAgent.*` as Layer 1, with a `minga_module?/1` helper that accepts all three namespace prefixes.

- **Wave 2 NS-2:** Snapshot files under `test/snapshots/minga/integration/` moved to `test/snapshots/minga_editor/integration/` since snapshot paths are derived from module names. The `.dialyzer_ignore.exs` file also needed path updates.

- **Wave 1 Track A:** The plan called for a new `mix check.layers` Mix task, but `Minga.Credo.DependencyDirectionCheck` (in `credo/checks/dependency_direction_check.exs`) already enforces the same rules via AST walking. It has its own `@allowed_references` allowlist for structural dispatch. Future waves that reference `mix check.layers` should use `mix credo --checks Minga.Credo.DependencyDirectionCheck` instead, or just rely on `make lint` which runs the full credo suite.

- **Wave 1 / Track C:** `lib/minga/editor/state/session.ex:start_timer` calls `Process.send_after` without an inline headless guard. In practice it is triple-protected: (1) `EditorCase` does not pass `session_dir`, so the nil-clause guard in `start_timer` fires before reaching the send; (2) `editor.ex:396` already wraps the call in `if new_state.backend != :headless`; (3) `session_handler.ex` only emits `{:restart_session_timer}` when `state.backend != :headless`. When Wave 2 moves `State.Session` out of `lib/minga/editor/`, consider adding a `backend` parameter to `start_timer` so the guard is internal and the function is self-contained.

- **Wave 4 / Track B:** The plan listed only 4 fields for RuntimeState (`active_session_id`, `status`, `model_name`, `provider_name`). `error` and `pending_approval` were considered but kept on `MingaEditor.State.Agent` since they're cached projections for rendering, not domain state the headless runtime needs. `status` is the only field that genuinely represents domain lifecycle state. If Wave 5 needs error/approval in the headless path, they can move then.

- **Wave 4 / Track B:** `MingaEditor.State.rebuild_agent_from_session/2` directly updates `State.Agent` fields via `%{agent | status: ..., pending_approval: ..., error: ...}` inside an `AgentAccess.update_agent` closure. This is a pre-existing Rule 2 violation (external module mutating a struct it doesn't own). Updated it to use `RuntimeState.set_status/2` for the status field. A proper fix would add a `State.Agent.rebuild_from_snapshot/3` function, but that's out of scope for this track.

- **Wave 4 / Track A:** The plan called for `MingaEditor.State.build_render_input/1` but the function was named `Input.from_editor_state/1` on the Input module instead, with `EditorState.apply_render_output/2` for the write-back (Rule 2 compliance: EditorState owns its struct mutations). The plan's gate command (`grep "def run(%MingaEditor.RenderPipeline.Input{})"`) assumed a struct match in the function head, but the implementation uses `@spec run(input())` with a type alias, which is idiomatic Elixir.

- **Wave 4 / Track A:** Input stores workspace fields as a plain map (not a WorkspaceState struct) so that existing `state.workspace.X` pattern-matches throughout the pipeline work unchanged. This was a pragmatic choice: updating every pattern-match site to read from Input fields directly would have been a much larger change with no functional benefit. The workspace map has the same keys as WorkspaceState.

- **Wave 4 / Track A:** Wiring the pipeline exposed 8 downstream modules that pattern-matched on `%EditorState{}` or used EditorState-specific APIs (like `EditorState.split?/1`, `EditorState.tree_rect/1`). These were fixed with map-matching fallback clauses or by calling the underlying module directly (e.g., `Windows.split?` instead of `EditorState.split?`). Affected modules: TreeRenderer, ViewContext, StatusBarData, Title, Layout (TUI + GUI), SearchHighlight, SemanticWindow.Builder, MingaEditor.Editing. One `get_in(state, [:workspace, :buffers, :active])` in Title was also fixed (structs don't implement Access).

- **Wave 4 / Track A:** Chrome fingerprinting uses `:erlang.phash2` over a tuple of 17+ fields plus active buffer cursor/version (fetched via GenServer call). The buffer cursor and version are included because the status bar displays them; without them, the chrome skip would cause a stale status bar during typing. The fingerprint is cached in the process dictionary (`chrome_prev_fingerprint`, `chrome_prev_result`) following the same pattern as emit tracking.

- **Wave 5 / Track C:** Track C created `MingaAgent.Runtime` and `MingaAgent.Introspection` (planned for Track A) because the gateway depends on them. Track A should expand these modules rather than recreating them. The Runtime facade has `defdelegate` wiring for SessionManager, Tool.Registry, Tool.Executor, and Introspection. Track A's planned introspection tool registration (PR A-5.3) and any additional Runtime methods can be added on top.

- **Wave 5 / Track C:** `ThousandIsland.listener_info/1` works directly on the Bandit supervisor pid (returns `{:ok, {address, port}}`). The plan's suggestion to call `Supervisor.which_children` on Bandit and find the ThousandIsland server doesn't work because Bandit's first child is a `ShutdownListener` that doesn't handle `:which_children` calls. Use `ThousandIsland.listener_info(bandit_pid)` instead.

- **Wave 5 / Track C:** The WebSocket integration test uses raw `:gen_tcp` + manual HTTP upgrade + RFC 6455 frame encoding rather than adding a test-only WebSocket client dependency. This avoids adding deps but makes the test helpers (~60 lines) somewhat fragile. If more WebSocket tests are needed in Wave 6, consider adding `:gun` or `Mint.WebSocket` as a test-only dep.

- **Wave 5 / Track C:** Zig binaries (`priv/minga-renderer`, `priv/minga-parser`) are not shared between git worktrees. New worktrees need the binaries copied from the main checkout or built from scratch. The custom `:minga_zig` Mix compiler triggers a rebuild if the binaries are missing, which fails if the Zig toolchain isn't set up in the worktree's environment.

- **Wave 1 / Track C:** The original verification command `grep ... | grep -v "headless"` was written incorrectly — it checks for the word "headless" on the *same line* as the timer call, but all guards are on a separate `if` line. The context-aware Python check is the correct approach. Updated the verification command in the Track C section above.
