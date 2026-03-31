# What the Agentic Refactor Costs Us

An honest accounting of what breaks, what gets harder, and what the vision docs need to change when we shift from "editor with agent features" to "agentic runtime with an editor frontend."

Nothing in the refactor plan is technically wrong. The architecture is sound. But the current docs sell a specific vision, and the refactor quietly invalidates parts of it. This document names those parts so we can decide what to keep, what to rewrite, and what to let go.

---

## The One-Sentence Version

The refactor splits the world in two: **things that go through the Editor** and **things that go through the Runtime**. Every doc that promises "one unified path for everything" is now lying.

---

## 1. The Extension Advice System Loses Omniscience

**Current promise (EXTENSIBILITY.md, CONFIGURATION.md, EXTENSION_API.md):**

> "Advice wraps any command. Your extension can intercept, transform, or replace any editor behavior."

This is the Emacs `define-advice` equivalent. It's the crown jewel of the extensibility story. The pitch to Emacs users is literally "you keep the same power."

**What the refactor does:**

The refactor creates two execution paths:
- **Commands** go through `Command.Registry` → `Config.Advice.wrap/2` → `fn(EditorState) -> EditorState`
- **Tools** go through `Tool.Registry` → `Tool.Executor.execute/3` → `fn(args) -> {:ok, result}`

These are parallel universes. An extension that advises `:save` (the command) will fire when a human presses `SPC f s`. It will NOT fire when an agent calls the `write_file` tool through `Tool.Executor`, because tool execution doesn't go through the command advice chain.

**Concrete example of the break:**

```elixir
# User's config.exs (from CONFIGURATION.md's "full example")
advise :override, :save, fn state ->
  state = Minga.API.save()
  case Minga.Buffer.Server.file_path(state.buffers.active) do
    nil -> state
    path ->
      System.cmd("git", ["add", path], stderr_to_stdout: true)
      %{state | status_msg: "Saved and staged: #{Path.basename(path)}"}
  end
end
```

Today: every save goes through this advice. After the refactor: agent saves through the Runtime bypass it entirely. The user's "auto-stage on save" breaks silently for agent-originated saves.

**What the vision has to become:**

The advice system needs to work at BOTH levels, or we need to be explicit that it doesn't. Options:

- **Option A: Unify commands and tools.** Tools ARE commands with a different invocation surface. `Tool.Executor` runs through `Config.Advice.wrap` the same way command dispatch does. This preserves the "advise anything" promise but means tool execution gets slower (advice chain lookup on every tool call, including rapid-fire agent tool calls).
- **Option B: Two-tier advice.** `Config.Advice` wraps commands (human-speed, presentation-affecting). `Tool.Executor` has its own advice chain (agent-speed, domain-affecting). Extensions explicitly register for one or both. This is honest but more complex for extension authors.
- **Option C: Accept the split.** Document it. Extensions that want to see agent activity subscribe to Events (`:buffer_changed` with source identity), not advice. Advice is for human-facing commands only. This is the simplest to build but weakens the "you can intercept anything" pitch.

Recommendation: **Option A with a fast path.** Tools go through `Config.Advice.wrap`, but the advice table has a "has any advice registered?" fast check (one ETS read). For the 95% of tools with no advice, the cost is one ETS lookup (microseconds). For the 5% with advice, the extension gets to intercept it. This preserves the promise without meaningful performance cost.

---

## 2. `Minga.API` Assumes a Single Editor

**Current promise (EXTENSION_API.md, CONFIGURATION.md):**

> "The `Minga.API` module provides a user-friendly interface for common operations inside commands: `content/0`, `insert/1`, `cursor/0`, `move_to/2`, `save/0`, `message/1`."

Every function in `Minga.API` defaults to `Minga.Editor` as the server. It's a convenience wrapper that assumes there's one Editor process and one active buffer.

**What the refactor does:**

The Runtime facade (`Agent.Runtime`) provides a parallel API for buffer operations: `list_buffers/0`, `buffer_content/1`, `execute_tool/3`. These don't go through `Minga.API`. They don't go through the Editor at all.

In headless mode (no Editor process), `Minga.API.content()` fails. But `Agent.Runtime.buffer_content(path)` works fine. Two APIs, two worlds.

**What the vision has to become:**

`Minga.API` needs to work without an Editor, or we need a `Minga.Runtime.API` that extension authors use when writing tools (as opposed to commands). The current docs don't distinguish these roles.

Most likely outcome: `Minga.API` becomes a thin layer over `Minga.Buffer` and `Minga.Agent.Runtime`. Functions like `content/0` resolve the "active buffer" through either the Editor (if running) or the SessionManager (if in agent context). The API stays user-friendly but stops hardcoding `Minga.Editor` as the server.

---

## 3. The "Config IS the Language" Promise Forks

**Current promise (EXTENSIBILITY.md, CONFIGURATION.md):**

> "Your config file is real Elixir. When you outgrow your config, you're already writing the same code as the editor itself."

**What the refactor adds:**

The `runtime_register_tool` and `runtime_eval` tools (Phase 8) let an LLM modify the runtime at runtime, through a completely different path than `config.exs`. An agent can:

```elixir
# Via runtime_register_tool:
Agent.Runtime.register_tool(%Tool.Spec{
  name: "deploy",
  callback: fn args -> ... end,
  ...
})
```

This tool now exists in the runtime but NOT in `config.exs`. It won't survive a restart (unless the agent also writes it to config). It won't show up in `SPC h` help. It's invisible to the user's config introspection.

**What the vision has to become:**

Runtime modifications need to be surfaceable. The user should be able to ask "what tools exist?" and see BOTH config-declared tools and runtime-registered tools. `Minga.Agent.Introspection.Describer.describe/0` handles this for the agent, but there's no user-facing equivalent.

This isn't a blocker. It's a documentation and introspection gap. The `describe` tool should be available as an editor command too, not just an agent tool. `SPC h d` (describe runtime) could dump the full capability set.

---

## 4. Extensions Don't Know About Headless Mode

**Current promise (EXTENSION_API.md):**

> "Your extension's `init/1` callback is where everything happens: register commands, bind keys, hook into the advice system."

**What the refactor enables:**

Headless mode (no Editor, no frontend). The Runtime starts, agent sessions work, tools execute, buffers exist. But there's no keymap, no command palette, no `fn(state) -> state` state to transform.

An extension that only registers commands and keybindings is useless in headless mode. The extension system has no concept of "I also provide tools" or "I work without an Editor."

**What the vision has to become:**

Extensions need a way to register tools alongside commands. The `use Minga.Extension` macro should support a `tool/3` declaration alongside `command/3`:

```elixir
defmodule MingaOrg do
  use Minga.Extension

  command :org_cycle_todo, "Cycle TODO keyword",
    execute: {MingaOrg.Todo, :cycle}

  tool :org_export, "Export org file to another format",
    parameter_schema: %{...},
    callback: &MingaOrg.Export.run/1
end
```

The command registers in `Command.Registry` (for the Editor). The tool registers in `Tool.Registry` (for the Runtime). In headless mode, only tools register. In full mode, both do.

This is new work that the refactor doc doesn't mention. It's a natural consequence of having two execution surfaces, but someone needs to build it.

---

## 5. ARCHITECTURE.md Supervision Tree Diagrams Are Wrong (But the Story Gets Better)

**Current state (ARCHITECTURE.md):**

Shows Agent.Supervisor under Services.Supervisor. Three Mermaid diagrams show this hierarchy.

**What the refactor does (Phase 4):**

Moves Agent.Supervisor to a top-level peer. This is strictly better for the architecture narrative: agents survive editor crashes, the runtime is more resilient.

**What needs updating:**

All three supervision tree Mermaid diagrams. The narrative text about cascade behavior. The "why this structure matters" section.

The story gets STRONGER, not weaker. "Your agents keep running even if the editor crashes" is a better pitch than "agents are a service within the editor." But the diagrams need to match reality.

---

## 6. AGENTIC_IDEAS.md's Infrastructure Foundations Partially Overlap

**Current state (AGENTIC_IDEAS.md):**

Defines four infrastructure foundations:
1. BufferChangedEvent with Source Identity (#1093)
2. Event Recording System (#1120)
3. Process Metrics Collector (#1122)
4. Global Buffer Registry (#1073)

**What the refactor builds:**

- Buffer.RefTracker (Phase 3) = a version of #4 (Global Buffer Registry)
- Events-based decoupling (Phase 1) = partial foundation for #1
- Agent.SessionManager (Phase 5) = partial foundation for #3's domain queries

**The tension:**

The refactor and the agentic ideas doc were written by different "brains" at different times. They solve overlapping problems with different approaches. Buffer.RefTracker tracks `{path, pid, ref_count}`. The Global Buffer Registry (#1073) proposes tracking `file_path -> pid` with workspace associations.

**What the vision has to become:**

The refactor plan should explicitly note which AGENTIC_IDEAS infrastructure items it satisfies, partially satisfies, or supersedes. Phase 3 (Buffer.RefTracker) should be designed with #1073's requirements in mind, not just the refactor's needs. Otherwise we build RefTracker for the refactor and then rebuild it for the workspace model.

Practical fix: the Buffer.RefTracker design should include a `holders(path)` function that returns which consumers (editor tabs, agent sessions) hold references, not just a count. This serves both the refactor's needs (lifecycle management) and the workspace model's needs (knowing which workspace a buffer belongs to).

---

## 7. FOR-EMACS-USERS.md's "Same Power" Claim Gets Asterisked

**Current promise:**

> "Minga keeps the programmability and fixes all of that."

The comparison table maps every Elisp concept to a Minga equivalent. The pitch is that you lose nothing.

**What the refactor complicates:**

In Emacs, `define-advice` wraps ANY function, including internal ones. There's one execution path. You can intercept anything because everything goes through Elisp.

After the refactor, there are two paths (commands vs tools). The advice system wraps commands but not tools (unless we fix this per item #1 above). An Emacs user who expects to `advise :around` the agent's file-writing behavior will find it doesn't work unless the tool path integrates with advice.

**What the vision has to become:**

If we go with Option A from item #1 (tools go through advice), the promise holds. If we go with Option C (accept the split), FOR-EMACS-USERS.md needs a new "honest comparison" row:

| Aspect | Elisp | Elixir |
|--------|-------|--------|
| Advice scope | Wraps any function (one execution path) | Wraps commands; tools have a separate interception mechanism |

This is still better than Neovim or VS Code (which have no advice system at all), but it's no longer "identical to Emacs."

---

## 8. BUFFER-AWARE-AGENTS.md Gets Validated (No Loss Here)

The refactor directly implements Phases 1-3 of this doc. Buffer.RefTracker enables the lifecycle management. Buffer.Fork (Phase 9) implements the forking model. The "selective flush before shell commands" PR maps to Phase 3.

This doc needs no changes beyond updating "planned" markers to "implemented in [refactor phase]."

This is the one doc that comes out purely stronger.

---

## Summary: What Changes

| Doc | Impact | Action |
|-----|--------|--------|
| **EXTENSIBILITY.md** | The "advise anything" promise breaks unless tools go through advice | Design decision needed (Option A/B/C above). Rewrite the advice section to reflect the chosen model. |
| **EXTENSION_API.md** | Extensions can't register tools, only commands. Headless mode makes command-only extensions useless. | Add `tool/3` macro to `use Minga.Extension`. Document the command vs tool distinction. |
| **CONFIGURATION.md** | `advise` section needs to explain scope (commands? tools? both?). Runtime modification (agent registering tools) isn't covered. | Add a "runtime modification" section. Clarify advice scope. |
| **ARCHITECTURE.md** | Supervision tree diagrams are wrong. Narrative gets stronger. | Update all three Mermaid diagrams. Rewrite cascade analysis. |
| **AGENTIC_IDEAS.md** | Infrastructure foundations partially overlap with refactor. Risk of building the same thing twice differently. | Add a cross-reference section mapping refactor phases to ideas infrastructure. Design RefTracker to serve both needs. |
| **FOR-EMACS-USERS.md** | "Same power" claim gets asterisked if tools don't go through advice. | Depends on Option A/B/C decision. If A, no change needed. If C, add honest comparison row. |
| **BUFFER-AWARE-AGENTS.md** | Validated. No loss. | Update "planned" markers to "implemented." |
| **FOR-NEOVIM-USERS.md** | Minor. Neovim has no advice system, so the comparison doesn't promise what it can't deliver. | Update supervision tree references if mentioned. |
| **PERFORMANCE.md** | No impact. The refactor doesn't change the render pipeline or keystroke path. | None. |
| **PROTOCOL.md / GUI_PROTOCOL.md** | No impact. The refactor explicitly avoids touching the port protocol. | None. |

---

## The Core Vision Shift

The current vision across all docs is: **Minga is an editor. Agents are a feature of the editor. Extensions customize the editor. Config configures the editor.**

The refactor shifts to: **Minga is a runtime. The editor is one frontend. Agents are peers of the editor. Extensions customize the runtime. Config configures the runtime.**

This is a better architecture. But the docs sell the first vision, and users (especially Emacs refugees) are buying the first vision. The second vision is harder to explain and less immediately compelling ("it's a runtime" vs "it's an editor you can program").

The docs don't need to abandon the editor narrative. They need to expand it: "Minga is an editor you can program, AND a runtime that works without the editor." The editor story is for humans choosing their daily driver. The runtime story is for the API gateway, headless mode, and the future where agents are first-class consumers.

Both stories can coexist. But they need to be explicitly told. Right now, only the editor story exists in the docs. The runtime story lives only in `MINGA_REWRITE_FOR_AGENTS.md` and `MINGA_REFACTOR_TO_AGENTIC.md`, which are implementation plans, not user-facing docs.

---

## The One Decision That Cascades Everywhere

**Do tools go through Config.Advice or not?**

If yes (Option A): the "advise anything" promise holds, extensions work the same way for humans and agents, FOR-EMACS-USERS.md is accurate, the vision docs need minimal updates. Cost: one ETS lookup per tool call.

If no (Option C): tools and commands are separate worlds, extensions need to register in both, the advice promise gets scoped, several docs need rewrites. Cost: simpler implementation, but more documentation and a weaker pitch to Emacs users.

Make this decision before starting the refactor. It affects the design of `Tool.Executor` (Phase 2), which is in Wave 1. Everything downstream inherits the choice.

My recommendation: **Option A.** The ETS lookup cost is negligible (microseconds per tool call; agents make at most a few tool calls per second). The architectural simplicity of "one advice system, one interception point" is worth far more than the microseconds saved by skipping it. And it keeps the Emacs comparison honest, which is the single most important marketing narrative for the target audience.
