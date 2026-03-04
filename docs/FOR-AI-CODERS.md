# Minga for AI-Assisted Developers

You use Claude Code, Cursor, Copilot, pi, Aider, or similar tools. Maybe you write every line yourself with AI suggestions. Maybe you describe what you want and review what the agent produces. Either way, AI is part of your workflow, and your editor wasn't designed for it.

**Minga was.**

---

## The problem nobody's talking about

Every editor you use today was built on the same assumption: **one human, typing sequentially, in one buffer at a time.** The entire architecture (single event loop, shared memory, global state) assumes a single operator.

Then AI agents showed up.

Now you have external processes making API calls, reading your files, writing to your buffers, spawning shell commands, and running for minutes at a time. Your editor handles this by... bolting on async extensions and hoping nothing breaks.

You've already seen what happens when it does:

- **Cursor freezes** while the agent processes a large response
- An agent writes to a file you're actively editing and your undo history gets confused
- A long-running agent operation blocks your ability to switch buffers or save files
- An API timeout hangs the extension and you have to force-quit your editor
- You lose unsaved work because an agent integration crashed the whole process

These aren't bugs in the AI tools. They're architectural limitations of editors that were designed decades before AI coding existed.

---

## What Minga does differently

Minga is built on the Erlang VM (BEAM), a runtime designed for systems with thousands of concurrent, unreliable processes. It treats "an external thing wants to modify a buffer" as a first-class operation, not an edge case.

### Your editor never freezes

Every component in Minga runs in its own isolated process. The BEAM's preemptive scheduler guarantees your typing always gets CPU time, regardless of what else is happening.

An agent streaming a 2,000-line response? You're still editing. An LSP server parsing a huge codebase? Your keystrokes don't queue up. Three agents working on three different files? The scheduler handles it.

This isn't async-with-callbacks like JavaScript or Neovim's event loop. It's true preemptive concurrency. The VM enforces fairness at the scheduler level. No single process can starve another.

### Agent crashes don't kill your editor

In Cursor or VS Code, an extension crash can take down the editor or leave it in a broken state. In Minga, each agent session runs in its own supervised process tree:

```
Minga.Supervisor
├── Buffer "main.ex"           ← your work, untouchable
├── Buffer "router.ex"         ← your work, untouchable
├── Agent.Session (Claude)     ← crashes here
│   ├── API client             ← API timeout? just this dies
│   ├── File watcher
│   └── Tool executor          ← shell command hangs? just this dies
└── Editor                     ← keeps running, always
```

The supervisor detects the crash and restarts the agent session. Your buffers, undo history, cursor positions, and unsaved changes are in completely separate processes. They don't even know the agent crashed.

### No buffer corruption from concurrent edits

You're editing line 50. An agent writes to line 200 of the same file. In most editors, this is a race condition waiting to happen. Undo history gets confused, cursor positions shift unexpectedly, or worse.

In Minga, every buffer is a GenServer, a process that handles one message at a time. Your keystroke and the agent's edit both arrive as messages. The buffer processes them sequentially, atomically, in order. There is no race condition. The buffer's mailbox serializes all access naturally:

```
Your keystroke:     {:insert, "x", {50, 10}}     → processed first
Agent edit:         {:insert, code, {200, 0}}     → processed second
```

No locks. No mutexes. No "file changed on disk" dialogs. Just ordered message passing.

### You can see what agents are doing

The BEAM has production-grade observability built in. You can inspect any running process, including agent sessions, without stopping them:

```elixir
# See all agent processes and their state
Agent.Session.list()
#=> [%{provider: :claude, status: :thinking, buffer: "main.ex"}]

# Watch messages flowing to a buffer in real-time
:dbg.tracer()
:dbg.p(buffer_pid, [:receive])
# {:insert, "defmodule MyApp do\n", {1, 0}}
# {:insert, "  use Phoenix.Router\n", {2, 0}}

# Full system dashboard: every process, memory, CPU
:observer.start()
```

When an agent is doing something unexpected, you don't have to guess. You inspect the running system. This is how Erlang engineers debug telecom switches that can't be stopped. The same tools work for debugging agent behavior in your editor.

### Multiple agents, no conflicts

Want a code review agent examining one buffer while a refactoring agent works on another? Want a test-writing agent running alongside your manual editing?

These are just processes. The BEAM was built to run millions of them. Each agent has its own memory, its own state, and communicates with buffers through message passing. There's no thread pool to configure, no async runtime to tune, no concern about one agent blocking another.

---

## How this compares to what you use now

### vs. Cursor / Windsurf

Cursor is VS Code with AI bolted on. The agent runs as an extension in Electron's single-threaded JavaScript runtime. When the agent is working hard, you feel it: UI lag, slow tab switching, occasional freezes.

Cursor's "background agent" runs in a separate process, which helps, but the results still flow back into the single-threaded VS Code extension host. Buffer modifications, diagnostics, and UI updates all contend on one thread.

**Minga:** Agents, buffers, and the editor run as separate BEAM processes with preemptive scheduling. There's no single thread to contend on.

### vs. Claude Code / pi / Aider (terminal agents)

These tools run outside your editor entirely. They read and write files on disk, and your editor picks up the changes via file watching. This works, but:

- You see the changes after the fact, not as they happen
- No integration with your undo history; agent changes are just disk writes
- You can't edit the same file while the agent is writing to it
- No way to see the agent's progress from inside your editor

**Minga:** Terminal agents could communicate directly with Minga's buffer processes. Agent edits flow through the same undo system as your typing. You can edit one part of a file while an agent edits another. The buffer serializes both safely. And because Minga runs on the BEAM, it could host the agent runtime directly: no separate process, no file-watching lag, just another supervised process tree in the editor.

### vs. Copilot / inline completions

Inline completion (ghost text) is the simplest AI integration, and most editors handle it fine. Minga will support this too. It's not the interesting problem.

The interesting problem is **agentic editing**: AI that doesn't just suggest one line, but reads your codebase, plans changes across multiple files, executes shell commands, and modifies buffers autonomously. That's where single-threaded editors break down, and where Minga's architecture matters.

---

## What this enables (that no other editor can do)

### Agent-aware undo

Because agent edits flow through the buffer's GenServer, they participate in the undo system. You can undo an agent's changes the same way you undo your own typing (`u` in normal mode). No "accept/reject" modal dialog. Just undo.

### Agent status in the modeline

The editor can monitor agent processes and reflect their status:

```
 NORMAL  main.ex [+]  ◐ Claude: refactoring extract_function  42:10
```

Running, thinking, writing, errored: the editor knows because it supervises the agent process.

### Pausable agents

Because agents are BEAM processes, you can suspend them:

```elixir
# Pause an agent (it stops processing, but doesn't lose state)
:sys.suspend(agent_pid)

# Resume when ready
:sys.resume(agent_pid)
```

This is a built-in BEAM capability. No special agent-side support needed.

### Edit boundaries

Define regions of a file that an agent can or can't touch:

```elixir
# Agent can only edit lines 50-100 of this buffer
Agent.Session.set_boundary(session, buffer_pid, {50, 0}, {100, :end})
```

Because all buffer access goes through the GenServer, enforcing boundaries is just a guard clause on the message handler.

---

## What you'd miss (honestly)

| Current tool has | Minga status |
|-----------------|-------------|
| VS Code's extension ecosystem | Early. Core editor only. |
| Cursor's inline diff view | Planned. Agent edits as reviewable diffs. |
| Copilot ghost text | Planned. |
| Multi-file agent edits with preview | Planned. BEAM makes this architecturally clean. |
| Claude Code's autonomous mode | Future. Minga could host the agent runtime directly. |
| GUI (mouse-driven, graphical) | Terminal-based. Minga uses Zig + libvaxis for TUI. |

Minga isn't a drop-in replacement for Cursor today. It's building the editor architecture that AI-assisted coding actually needs, not the one that made sense when editors were designed for solo human typing.

---

## The bet

Your current editor was designed for you, sitting at a keyboard, typing one character at a time. AI coding agents are the biggest change in how code gets written since IDEs replaced `ed`. And they need an editor architecture that treats concurrent, crash-prone, autonomous processes as first-class citizens, not an afterthought.

Every other editor is retrofitting. Minga is building for this future from the ground up.

If you've ever:
- Had your editor freeze while an agent was working
- Lost unsaved changes because an AI extension crashed
- Wished you could keep editing while an agent runs in the background
- Wanted to undo agent changes the same way you undo your own
- Wondered why your editor can't handle two agents at once

Then Minga is the editor you've been waiting for. The age of AI-assisted coding needs an editor that was designed for it. This is that editor.
