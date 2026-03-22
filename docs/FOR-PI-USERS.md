# Minga for Pi Users

You read Mario's blog post. You like the philosophy: minimal system prompt, minimal toolset, full observability, YOLO by default, file-based plans over ephemeral modes. You use pi because it gives you control over what goes into the model's context.

Minga already embeds pi. Its agent backend spawns `pi --mode rpc` as a supervised BEAM Port. You keep everything pi gives you and gain an editor that was designed from the ground up for AI-assisted coding.

---

## The "two tools" problem

Here's the workflow you're running today:

1. Open a terminal. Run pi.
2. The agent reads files, writes code, runs commands.
3. Open a second terminal with Neovim or VS Code to review what the agent did.
4. Navigate the codebase, check diffs, trace call chains.
5. Switch back to pi. Give it more instructions.
6. Repeat.

Two tools because neither one is complete. Pi can't show you the codebase the way an editor can. Your editor can't see or control the agent. You context-switch constantly.

Minga collapses this into one tool. The agent works in the left pane. The editor shows affected files in the right pane. Diffs appear inline as the agent edits. No window switching.

---

## What you keep from pi

Minga's agent backend *is* pi. The `PiRpc` provider spawns `pi --mode rpc` as a supervised OS process, communicates via JSON lines on stdin/stdout, and translates pi's event protocol into Minga's internal events.

| Pi feature | How it works in Minga |
|-----------|----------------------|
| Minimal system prompt | Same. Under 1,000 tokens. |
| 4 core tools (read, write, edit, bash) | Mapped to Minga's agent tools with identical semantics |
| Multi-provider support | Pi handles switching; Minga surfaces it |
| Session management | Minga adds persistence on top (`SPC a h` to browse) |
| AGENTS.md context files | Pi loads them. Minga's project detection feeds the right paths. |
| Cost and token tracking | Surfaced in modeline and agent status |
| Abort support | `SPC a s` sends abort through pi's RPC protocol |
| YOLO mode | Minga adds optional tool approval on top for destructive operations |

You don't lose pi. You gain an editor around it.

---

## What you gain

### Agent edits participate in undo

When pi writes to a file, the change flows through Minga's buffer GenServer and enters the same undo stack as your manual edits. Press `u` to undo an agent change. No `git diff` to figure out what happened.

### Inline diff review

When the agent edits a file, Minga shows a unified diff in the preview pane. Navigate hunks with `]c`/`[c`. Accept with `y`, reject with `x`. Bulk-accept with `Y`, bulk-reject with `X`. You review agent changes as diffs in context, not by reading chat output.

### Tool approval flow

Pi runs YOLO by default. Minga adds a configurable layer: destructive tools (write_file, edit_file, shell) can require approval before executing. This isn't security theater. It's a review checkpoint so you can make sure the agent understood your intent.

### Your typing never freezes

Minga hosts both the agent and the editor. The BEAM's preemptive scheduler gives every process fair CPU time. The agent session, each buffer, the render pipeline: all separate processes. Your typing is responsive because the VM makes it structurally impossible for the agent to block your input.

### Crash isolation

Pi is a single Node.js process. If it crashes, everything is gone.

Minga's supervision tree isolates every component. If the pi RPC process crashes, the BEAM detects it, logs the error, and the agent session reports a failure. Your buffers, undo history, and unsaved changes are untouched. Completely separate processes, completely separate memory.

### Multiple agents

Pi runs one session per terminal. Minga can run multiple agent sessions as independent BEAM processes, each with its own provider and conversation.

### Observability

The blog emphasizes full observability. Minga surfaces it differently than pi's scrollback TUI:

- **Agent chat panel:** every message, tool call, and result with markdown rendering
- **Tool-reactive preview pane:** streaming shell output, diffs as they happen, directory listings
- **Modeline status:** `◯` idle, `⟳` thinking, `⚡` tool executing, `✗` error
- **`*Messages*` buffer:** runtime log via `SPC b m`
- **BEAM introspection:** `:sys.get_state(agent_pid)` to inspect any process live

---

## Philosophy alignment

The blog's strongest opinions map directly to how Minga works:

**"No built-in to-dos. Write to a file."** Minga agrees. The agent reads and updates `PLAN.md` or `TODO.md` like any other file.

**"No plan mode. Talk to the agent and write plans to files."** Minga agrees. The split view lets you see the plan file alongside the chat.

**"No MCP. Use CLI tools with READMEs."** Minga's default agent follows the same philosophy. For users with existing MCP infrastructure, Minga offers MCP as an optional extension ([#286](https://github.com/jsmestad/minga/issues/286)) with lazy tool discovery to avoid context bloat. If you don't enable it, it doesn't exist.

**"Context engineering is paramount."** Minga supports this through `@-mentions` for file context, configurable auto-context injection, session persistence, and session artifacts.

---

## What's different (and why)

**Full-screen TUI, not scrollback.** Pi uses scrollback for a linear chat. Minga is a full-screen editor with split windows, tab bars, gutter columns, and which-key popups. The tradeoff (losing native scrollback) is worth it for spatial layout.

**Agent processes, not bash self-spawn.** Minga has first-class agent processes with structured event streaming, inline diff review, and tool approval.

**Optional tool approval.** Pi is YOLO-only. Minga defaults to YOLO but lets you opt into approval for destructive tools. Not about security; about review cadence.

---

## Migration

1. **Install Minga.** Your pi binary stays where it is.
2. **Your AGENTS.md files work unchanged.** Pi loads them through its RPC protocol.
3. **Your pi config works unchanged.** Model settings, API keys, everything pi reads is separate from Minga's config.
4. **Learn the keybindings.** `SPC a a` toggles the agent. `SPC a s` stops it. `SPC a n` new session. `SPC a h` session history.
5. **Keep pi for standalone use.** Minga spawns pi as a subprocess. You can still run pi directly when that's what you want.

You're not replacing pi. You're giving it an editor to live in.
