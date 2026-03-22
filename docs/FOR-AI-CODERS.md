# Minga for AI-Assisted Developers

You use Claude Code, Cursor, Copilot, pi, Aider, or similar tools. AI is part of your workflow, and your editor wasn't designed for it.

Minga was.

---

## The problem with current editors

Every editor you use today was built on the same assumption: one human, typing sequentially, in one buffer at a time. The entire architecture (single event loop, shared memory, global state) assumes a single operator.

Then AI agents showed up. Now you have external processes making API calls, reading your files, writing to your buffers, spawning shell commands, and running for minutes at a time. Your editor handles this by running everything on one event loop and hoping nothing contends too badly.

You've already seen what happens:

- An agent streaming a large response causes UI jank because it's competing with your keystrokes for the same thread
- An agent writes to a file you're editing and your undo history gets confused
- You have no visibility into what an agent is doing. Is it thinking? Stuck? Writing to the wrong file?
- A long-running agent operation blocks your ability to switch buffers or save files
- An API timeout hangs the extension and you have to force-quit

These aren't bugs in the AI tools. They're architectural limitations of editors designed decades before AI coding existed.

---

## What Minga does differently

Minga is built on the Erlang VM (BEAM), a runtime designed for systems with thousands of concurrent, independent processes. It treats "an external thing wants to modify a buffer" as a first-class operation, not an edge case.

### Your editor never freezes

Every component in Minga runs in its own isolated process. The BEAM's preemptive scheduler guarantees your typing always gets CPU time, regardless of what else is happening.

An agent streaming a 2,000-line response? You're still editing. An LSP server parsing a huge codebase? Your keystrokes don't queue up. Three agents working on three different files? The scheduler handles it.

This isn't async-with-callbacks like JavaScript or Neovim's event loop. The VM enforces fairness at the scheduler level. No single process can starve another.

### No buffer corruption from concurrent edits

You're editing line 50. An agent writes to line 200 of the same file. In most editors, this is a race condition. Undo history gets confused, cursor positions shift, or worse.

In Minga, every buffer is a GenServer (a process that handles one message at a time). Your keystroke and the agent's edit both arrive as messages. The buffer processes them sequentially, atomically, in order:

```
Your keystroke:     {:insert, "x", {50, 10}}     → processed first
Agent edit:         {:insert, code, {200, 0}}     → processed second
```

No locks. No mutexes. No "file changed on disk" dialogs.

> **Where we are today:** Agent tools currently write to the filesystem (`File.read/write`), bypassing the buffer. We're actively wiring agent tools to route through `Buffer.Server` so edits go through the same mailbox as your keystrokes, with full undo integration. See [Buffer-Aware Agents](BUFFER-AWARE-AGENTS.md) for the design.

### You can see what agents are doing

The BEAM has production-grade observability built in. You can inspect any running process, including agent sessions, without stopping them:

```elixir
# See all agent processes and their state
Agent.Session.list()
#=> [%{provider: :claude, status: :thinking, buffer: "main.ex"}]

# Watch messages flowing to a buffer in real-time
:dbg.tracer()
:dbg.p(buffer_pid, [:receive])

# Full system dashboard: every process, memory, CPU
:observer.start()
```

When an agent is doing something unexpected, you don't guess. You inspect the running system. This is how Erlang engineers debug telecom switches that can't be stopped.

### Agents are isolated from everything

Each agent session runs in its own supervised process tree. An agent can't corrupt buffer state because it communicates through message passing, the same interface the editor itself uses.

If an agent hits an error, its supervisor handles recovery. Your buffers, undo history, and unsaved changes are in completely separate processes with completely separate memory.

### Multiple agents, no conflicts

Want a code review agent on one buffer while a refactoring agent works on another? Those are just processes. The BEAM was built to run millions of them. Each agent has its own memory and communicates with buffers through message passing.

> **Where we are today:** Multiple agent sessions work, and process isolation prevents them from interfering at the BEAM level. But because agent tools write directly to the filesystem, two agents editing the same file can clobber each other on disk. The planned fix is [buffer forking](BUFFER-AWARE-AGENTS.md#phase-2-buffer-forking-with-three-way-merge): each agent gets its own in-memory copy of the document, and changes merge back via three-way merge.

---

## How this compares to what you use now

### vs. Cursor / Windsurf

Cursor is VS Code with AI bolted on. The agent runs as an extension in Electron's single-threaded JavaScript runtime. When the agent is working hard, you feel it.

Cursor's "background agent" runs in a separate process, which helps, but the results still flow back into the single-threaded extension host. Buffer modifications, diagnostics, and UI updates all contend on one thread.

**Minga:** Agents, buffers, and the editor run as separate BEAM processes with preemptive scheduling. There's no single thread to contend on.

### vs. Claude Code / pi / Aider (terminal agents)

These tools run outside your editor entirely. They read and write files on disk, and your editor picks up the changes via file watching. This works, but you see changes after the fact, there's no undo integration, and you can't edit the same file while the agent writes to it.

Here's the thing nobody says out loud: you still open an editor. You run Claude Code in one terminal, then flip to Neovim or VS Code to audit what it did. The agent is your writer; the editor is your reviewer. You're always running two tools because neither one is complete on its own.

**Minga today:** The built-in agent collapses this into one tool. You chat, watch the agent work, and review inline diffs without switching windows.

**Minga next:** Agent tools are being [rewired to route through `Buffer.Server`](BUFFER-AWARE-AGENTS.md) instead of the filesystem. Agent edits will flow through the same undo system as your typing, appear instantly, and trigger incremental tree-sitter updates.

### vs. Copilot / inline completions

Inline completion (ghost text) is the simplest AI integration, and most editors handle it fine. Minga will support this too.

The interesting problem is agentic editing: AI that reads your codebase, plans changes across multiple files, executes shell commands, and modifies buffers autonomously. That's where single-threaded editors hit their limits.

---

## The IDE isn't dead. It needs a new architecture.

There's a popular narrative that AI agents will replace the IDE. You'll just talk to a terminal, describe what you want, and the agent will write everything. The editor becomes a relic.

That hasn't happened. Nobody runs Claude Code and blindly commits the result. You review. You audit. You open files, check diffs, trace through logic, run tests. The editor is still essential; it's just been demoted to a review tool that has no idea an agent exists.

A PR diff shows you what changed, not why it's wrong. You can't jump to a definition from a diff view. You can't trace a call chain across three files. Telling an agent "fix line 47" only works when you already understand the problem. For the cases where you don't, you open an editor. Every time.

The concept of an IDE (a place where you read, write, navigate, build, and debug code) hasn't been made obsolete by AI. It needs to be reinvented for a world where you're not the only one editing. The old IDE assumed one operator. The new one needs to assume many: you, plus one or more agents, all working concurrently, all visible, all controllable from one place.

That's what Minga is building.

---

## What this enables

### Agent status in the modeline ✅

The editor monitors agent processes and reflects their status:

```
 NORMAL  main.ex [+]  ◐ Claude: refactoring extract_function  42:10
```

Running, thinking, writing, errored: the editor knows because it supervises the agent process.

### Inline diff review ✅

When the agent edits a file, the diff appears in the preview pane immediately. Navigate hunks with `]c`/`[c`, accept with `y`, reject with `x`, bulk-accept with `Y`, bulk-reject with `X`. No context switching.

### Agent-aware undo (planned)

Once agent tools [route through `Buffer.Server`](BUFFER-AWARE-AGENTS.md#phase-1-route-agent-tools-through-buffers), agent edits will participate in the undo system. Press `u` to undo an agent's changes the same way you undo your own typing. The buffer architecture supports this; the agent tools just need to be wired to use it.

### Buffer forking for concurrent agents (planned)

Multiple agents will edit the same file concurrently, each on their own [in-memory fork](BUFFER-AWARE-AGENTS.md#phase-2-buffer-forking-with-three-way-merge). Changes merge back via three-way merge. Conflicts go through the diff review UI.

### Pausable agents

Because agents are BEAM processes, you can suspend them:

```elixir
:sys.suspend(agent_pid)   # pause (keeps state)
:sys.resume(agent_pid)    # resume
```

Built-in BEAM capability. No special agent-side support needed.

---

## What you'd miss (honestly)

| Current tool has | Minga status |
|-----------------|-------------|
| VS Code's extension ecosystem | ✅ Extension system ships (Hex, git, local). Ecosystem is young. |
| Cursor's inline diff view | ✅ Shipped. |
| Copilot ghost text | Planned. |
| Agent undo integration | Planned. Requires [buffer-routed agent tools](BUFFER-AWARE-AGENTS.md). |
| Multi-agent concurrent editing | Planned. [Buffer forking](BUFFER-AWARE-AGENTS.md#phase-2-buffer-forking-with-three-way-merge) with three-way merge. |
| Claude Code's autonomous mode | Future. |

Minga isn't a drop-in replacement for Cursor today. It's building the editor architecture that AI-assisted coding actually needs.

---

## The bet

Your current editor was designed for you, sitting at a keyboard, typing one character at a time. AI coding agents are the biggest change in how code gets written since IDEs replaced `ed`.

Every other editor is retrofitting. Minga is building for this future from the ground up.

And unlike the flavor-of-the-week AI editors, Minga isn't built on hype. Emacs proved that an editor is really a Lisp runtime that happens to edit text. That insight (the editor should be a programmable environment, not a static tool) is almost 50 years old and still correct. Minga carries it forward: the editor is a BEAM runtime that happens to edit text. Buffers are processes. Modes are processes. Agents are processes.

Emacs survived every editor war because its architecture was deeper than its UI. Minga makes the same bet: get the runtime right and the editor can adapt to whatever comes next. Editors built as thin wrappers around a specific AI product have a shelf life. Editors built as programmable runtimes don't.
