# Minga for Pi Users

You read Mario's blog post. You like the philosophy: minimal system prompt, minimal toolset, full observability, YOLO by default, file-based plans over ephemeral modes. You use pi because it gives you control over what goes into the model's context and doesn't hide things behind sub-agent black boxes.

**Minga already embeds pi.** Its agent backend spawns `pi --mode rpc` as a supervised BEAM Port. You keep everything pi gives you and gain an editor architecture that was designed from the ground up for AI-assisted coding.

---

## The "two tools" problem

Here's the workflow you're running today:

1. Open a terminal. Run pi.
2. The agent reads files, writes code, runs commands.
3. You open a second terminal (or a split, or a different app) with Neovim/VS Code/Emacs to *review* what the agent did.
4. You navigate the codebase, check diffs, trace call chains, verify types.
5. You switch back to pi. Give it more instructions.
6. Repeat.

You're running two tools because neither one is complete. Pi can't show you the codebase the way an editor can. Your editor can't see or control the agent. So you play air traffic controller between them, context-switching constantly, losing flow state every time you alt-tab.

**Minga collapses this into one tool.** The agent works in the left pane. The editor shows the affected files in the right pane. Diffs appear inline as the agent edits. You review and keep editing in the same viewport. No window switching. No "let me check what it did."

---

## What you keep from pi

Minga's agent backend *is* pi. The `PiRpc` provider spawns `pi --mode rpc` as a supervised OS process, communicates via JSON lines on stdin/stdout, and translates pi's event protocol into Minga's internal event system. Every pi capability flows through:

| Pi feature | How it works in Minga |
|-----------|----------------------|
| Minimal system prompt | Same. Pi's prompt is under 1,000 tokens. |
| 4 core tools (read, write, edit, bash) | Mapped to Minga's agent tools with identical semantics |
| Multi-provider support | Pi handles provider switching; Minga surfaces it |
| Session management | Minga adds its own persistence layer on top (`SPC a h` to browse sessions) |
| AGENTS.md context files | Pi loads them. Minga's project detection feeds the right paths. |
| Model switching | Available through pi's model selection |
| Cost and token tracking | Surfaced in Minga's modeline and agent status |
| Abort support | `SPC a s` sends abort through pi's RPC protocol |
| YOLO mode | Minga adds optional tool approval on top for destructive operations |

You don't lose pi. You gain an editor around it.

---

## What you gain

### 1. Agent edits participate in undo

When pi writes to a file via its `write` or `edit` tool, the change flows through Minga's buffer GenServer. It enters the same undo stack as your manual edits. Press `u` to undo an agent change. No external diffing. No "what did it change?" No `git diff` to figure out what happened.

In pi alone, agent edits are disk writes. Your editor (if you have one open) picks them up via file watching, possibly with a "file changed on disk" dialog. Undo history is disconnected from the agent's changes.

### 2. Inline diff review

When the agent edits a file, Minga shows a unified diff in the preview pane. Navigate hunks with `]c`/`[c`. Accept with `y`, reject with `x`. Bulk-accept with `Y`, bulk-reject with `X`. You review agent changes the way you review code, not by reading chat output, but by reading diffs in context.

### 3. Structured split tool results (you already have this)

The blog talks about pi-ai's innovation of separating LLM-facing tool output from UI-facing tool output. Minga's tool-reactive preview pane does the same thing. The agent chat shows tool summaries ("Edited main.ex lines 42-50"). The preview pane shows the full output: streaming shell results, unified diffs, directory listings with file/folder icons. Same concept, different implementation.

### 4. Tool approval flow

Pi runs YOLO by default, and the blog argues this is correct because security measures in coding agents are mostly theater. Minga agrees philosophically but adds a configurable layer: destructive tools (write_file, edit_file, shell) can require user approval before executing. You see exactly what the agent wants to do, approve or reject, and move on. Configurable via `agent_tool_approval` and `agent_destructive_tools` in your config.

This isn't security theater. It's a review checkpoint. You're not trying to prevent the agent from being malicious; you're making sure it understood your intent before it writes to disk.

### 5. Your typing never freezes

Pi runs in a Node.js process. It's single-threaded. When pi is streaming a large response or executing a slow tool, pi's event loop is busy. This is fine because pi doesn't handle your typing; your terminal does.

But Minga hosts both the agent *and* the editor. If they shared a thread, a busy agent could lag your keystrokes. They don't share a thread. The BEAM runs a preemptive scheduler that gives every process fair CPU time. The agent session, each buffer, the renderer pipeline: all separate processes. The VM guarantees your typing gets CPU time regardless of what the agent is doing. This isn't async. It's true preemptive concurrency with fairness enforcement at the scheduler level.

### 6. Crash isolation

Pi is a single Node.js process. If it crashes, everything is gone: the session, the streaming response, the in-progress tool execution.

Minga's supervision tree isolates every component:

```
Minga.Supervisor (rest_for_one)
├── Buffer.Supervisor           ← buffers survive everything below
│    ├── Buffer "main.ex"       ← isolated process, private state
│    └── Buffer "router.ex"     ← isolated process, private state
├── Agent.Supervisor            ← agent crashes don't affect buffers
│    └── Agent.Session          ← supervised, restartable
│         └── PiRpc provider    ← pi process supervised by BEAM
├── Port.Manager                ← renderer crash doesn't lose state
└── Editor                      ← orchestration
```

If the pi RPC process crashes, the BEAM detects it, logs the error, and the agent session reports a failure state. Your buffers, undo history, cursor positions, and unsaved changes are untouched. They're in completely separate processes with completely separate memory.

### 7. Multiple agents

Pi runs one agent session per terminal. Want to run a code review agent while a refactoring agent works on another file? Open two terminals. Coordinate manually.

Minga can run multiple agent sessions as independent BEAM processes. Each has its own provider, its own conversation, its own supervised process tree. They communicate with buffers through message passing, the same mechanism the editor uses internally. No thread pool to configure, no concern about one agent blocking another.

### 8. Observability you can't get from a CLI

The blog emphasizes full observability: seeing every tool call, every model interaction, every edit. Pi surfaces this in its scrollback-buffer TUI. Minga surfaces it differently:

- **Agent chat panel**: every message, tool call, and tool result visible with markdown rendering
- **Tool-reactive preview pane**: shell output streams in real time, diffs appear as edits happen, directory listings show with icons
- **Modeline status**: `◯` idle, `⟳` thinking, `⚡` tool executing, `✗` error
- **Notification toasts**: actions confirmed in the top-right corner
- **`*Messages*` buffer**: runtime log viewable via `SPC b m`
- **BEAM introspection**: `:sys.get_state(agent_pid)` to inspect any process live

You see everything the agent does without leaving the editor.

---

## Philosophy alignment

The blog's strongest opinions map directly to how Minga works:

### "No built-in to-dos. Write to a file."

Minga agrees. There's no to-do widget. The agent reads and updates `PLAN.md` or `TODO.md` like any other file. File-based artifacts are versionable, shareable, and persistent across sessions. The agent can `@-mention` files to include them as context.

### "No plan mode. Talk to the agent and write plans to files."

Minga agrees. There's no dedicated "plan UI." The agent chat is the planning interface. Plans go into files. The split view lets you see the plan file alongside the chat. `@-mentions` let you attach files as context when you need the agent to reference them.

### "No MCP. Use CLI tools with READMEs."

Minga agrees. No MCP support is planned. The agent uses bash, which is the universal adapter. A CLI tool with a README is cheaper to build, cheaper on tokens (progressive disclosure: read the README only when needed), and easier to debug than an MCP server. Minga's extension system for agent tooling follows the same principle: small, focused, discoverable.

### "Context engineering is paramount."

This is the blog's deepest insight. Controlling what goes into the model's context yields better outputs. Minga supports this through:

- **`@-mentions`**: type `@path` to attach specific files as context, with tab-completion
- **`agent_auto_context`**: configurable automatic context injection
- **Session persistence**: save and resume conversations, review what context was used
- **Session artifacts**: the agent can write summaries to files that feed future sessions

### "Observability over abstraction."

The blog criticizes Claude Code for hiding sub-agent activity behind black boxes. Minga's agent shows every tool call, every result, every diff. The BEAM's introspection tools let you go even deeper when you need to.

---

## What's different (and why)

Not everything from pi's design translates to an editor. A few places where Minga intentionally diverges:

### Full-screen TUI, not scrollback

Pi uses the scrollback-buffer TUI approach: append content to the terminal like a CLI program, get free scrolling and search from the terminal emulator. The blog explains why this makes sense for a linear chat interface.

Minga is a full-screen editor. It takes ownership of the terminal viewport and draws a cell grid. This is the right choice for an editor that needs split windows, a tab bar, gutter columns, diagnostic overlays, which-key popups, and pixel-level control over every region. The trade-off (losing native scrollback) is worth it because editors need spatial layout that scrollback can't provide.

### Agent processes, not bash self-spawn

The blog argues against built-in sub-agents, preferring to spawn pi via bash for observability. This makes sense for a CLI tool where tmux is a natural companion.

Minga has first-class agent processes. Each agent session is a supervised BEAM process tree with structured event streaming, inline diff review, and tool approval. The editor's split-panel design gives you observability that a raw bash sub-spawn can't: you see the chat, the diffs, and the affected files simultaneously in one viewport.

### Optional tool approval

Pi runs YOLO-only. The blog argues that security measures are theater. Minga defaults to YOLO but lets you opt into approval for destructive tools. This isn't about security; it's about review cadence. Sometimes you want the agent to explain what it's about to do before it does it, especially when you're learning a new codebase or the agent is working on something critical.

---

## Migration

If you're a pi user, the migration is trivial:

1. **Install Minga.** Your pi binary stays where it is.
2. **Your AGENTS.md files work unchanged.** Minga's pi RPC provider loads them through pi.
3. **Your pi config works unchanged.** Model settings, provider API keys, everything pi reads is separate from Minga's config.
4. **Learn the keybindings.** `SPC a a` toggles the agent view. `SPC a s` stops the agent. `SPC a n` starts a new session. `SPC a h` browses saved sessions. Normal vim keybindings work everywhere.
5. **Keep pi installed for standalone use.** Minga spawns pi as a subprocess. You can still run pi directly in a terminal when that's what you want.

You're not replacing pi. You're giving it an editor to live in.

---

## The bet

Pi proved that a minimal, opinionated coding agent can match or beat feature-heavy alternatives. The blog's benchmark results show pi with Claude Opus 4.5 competitive with Cursor, Codex, and Windsurf on Terminal-Bench 2.0.

But pi is still a CLI tool. When you're done talking to the agent, you open an editor. When you want to review what the agent wrote, you switch windows. When you want to trace a call chain across three files, you leave pi entirely.

Minga is the editor that pi users open after pi finishes. Except now you don't have to leave. The agent lives inside the editor, edits flow through the undo system, diffs appear inline, and the BEAM's preemptive scheduler guarantees your typing is always responsive regardless of what the agent is doing.

Same philosophy. Same agent. Better integration. One tool instead of two.
