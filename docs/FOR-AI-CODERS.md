# Minga for AI-Assisted Developers

You use Claude Code, Cursor, Copilot, pi, Aider, or similar tools. Maybe you write every line yourself with AI suggestions. Maybe you describe what you want and review what the agent produces. Either way, AI is part of your workflow, and your editor wasn't designed for it.

**Minga was.**

---

## The problem nobody's talking about

Every editor you use today was built on the same assumption: **one human, typing sequentially, in one buffer at a time.** The entire architecture (single event loop, shared memory, global state) assumes a single operator.

Then AI agents showed up.

Now you have external processes making API calls, reading your files, writing to your buffers, spawning shell commands, and running for minutes at a time. Your editor handles this by running everything on one event loop and hoping nothing contends too badly.

You've already seen what happens when it does:

- An agent streaming a large response **causes UI jank** because it's competing with your keystrokes for the same thread
- An agent writes to a file you're editing and **your undo history gets confused** because there's no serialization between concurrent modifications
- You have **no visibility** into what an agent is doing. Is it thinking? Stuck? Writing to the wrong file? You can't tell without checking the terminal
- A long-running agent operation **blocks your ability to switch buffers** or save files because the event loop is busy
- An API timeout **hangs the extension** and you have to force-quit or wait it out

These aren't bugs in the AI tools. They're architectural limitations of editors that were designed decades before AI coding existed.

---

## What Minga does differently

Minga is built on the Erlang VM (BEAM), a runtime designed for systems with thousands of concurrent, independent processes. It treats "an external thing wants to modify a buffer" as a first-class operation, not an edge case.

### Your editor never freezes

Every component in Minga runs in its own isolated process. The BEAM's preemptive scheduler guarantees your typing always gets CPU time, regardless of what else is happening.

An agent streaming a 2,000-line response? You're still editing. An LSP server parsing a huge codebase? Your keystrokes don't queue up. Three agents working on three different files? The scheduler handles it.

This isn't async-with-callbacks like JavaScript or Neovim's event loop. It's true preemptive concurrency. The VM enforces fairness at the scheduler level. No single process can starve another. Your typing is responsive not because of careful engineering, but because the runtime makes it structurally impossible for anything to block your input handling.

### No buffer corruption from concurrent edits

You're editing line 50. An agent writes to line 200 of the same file. In most editors, this is a race condition waiting to happen. Undo history gets confused, cursor positions shift unexpectedly, or worse.

In Minga, every buffer is a GenServer, a process that handles one message at a time. Your keystroke and the agent's edit both arrive as messages. The buffer processes them sequentially, atomically, in order. There is no race condition. The buffer's mailbox serializes all access naturally:

```
Your keystroke:     {:insert, "x", {50, 10}}     → processed first
Agent edit:         {:insert, code, {200, 0}}     → processed second
```

No locks. No mutexes. No "file changed on disk" dialogs. Just ordered message passing. The agent's edits participate in the same undo system as your typing, so you can undo them the same way you undo your own work.

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

### Agents are isolated from everything

Each agent session runs in its own supervised process tree. An agent can't corrupt buffer state because it doesn't have direct access to buffer memory. It communicates through the same message-passing interface the editor itself uses.

```
Minga.Supervisor
├── Buffer "main.ex"           ← isolated process, private state
├── Buffer "router.ex"         ← isolated process, private state
├── Agent.Session (Claude)     ← isolated process tree
│   ├── API client             ← API timeout? just this process is affected
│   ├── File watcher
│   └── Tool executor          ← shell command hangs? just this process
└── Editor                     ← keeps running, always
```

If an agent hits an error, its supervisor handles recovery. Your buffers, undo history, cursor positions, and unsaved changes are in completely separate processes with completely separate memory. They aren't affected because they *can't* be affected. The VM enforces the boundary.

### Multiple agents, no conflicts

Want a code review agent examining one buffer while a refactoring agent works on another? Want a test-writing agent running alongside your manual editing?

These are just processes. The BEAM was built to run millions of them. Each agent has its own memory, its own state, and communicates with buffers through message passing. There's no thread pool to configure, no async runtime to tune, no concern about one agent blocking another.

---

## How this compares to what you use now

### vs. Cursor / Windsurf

Cursor is VS Code with AI bolted on. The agent runs as an extension in Electron's single-threaded JavaScript runtime. When the agent is working hard, you feel it: UI lag, slow tab switching, occasional stutters.

Cursor's "background agent" runs in a separate process, which helps, but the results still flow back into the single-threaded VS Code extension host. Buffer modifications, diagnostics, and UI updates all contend on one thread.

**Minga:** Agents, buffers, and the editor run as separate BEAM processes with preemptive scheduling. There's no single thread to contend on. The scheduler guarantees fair CPU time for every process.

### vs. Claude Code / pi / Aider (terminal agents)

These tools run outside your editor entirely. They read and write files on disk, and your editor picks up the changes via file watching. This works, but:

- You see the changes after the fact, not as they happen
- No integration with your undo history; agent changes are just disk writes
- You can't edit the same file while the agent is writing to it
- No way to see the agent's progress from inside your editor

And here's the thing nobody says out loud: **you still open an editor.** You run Claude Code in one terminal, then flip to Neovim or VS Code to audit what it did. You follow along, spot-check diffs, review file by file. The agent is your writer; the editor is your reviewer. You're always running two tools because neither one is complete on its own.

The terminal agent can't show you the codebase the way an editor can. The editor can't see or control the agent. So you play air traffic controller between them, context-switching constantly, losing flow state every time you alt-tab.

**Minga:** Terminal agents could communicate directly with Minga's buffer processes. Agent edits flow through the same undo system as your typing. You can edit one part of a file while an agent edits another. The buffer serializes both safely. And because Minga runs on the BEAM, it could host the agent runtime directly: no separate process, no file-watching lag, just another supervised process tree in the editor. The "sidecar editor" workflow collapses into one tool. You watch the agent work in real-time, review inline, and intervene without switching windows.

### vs. Copilot / inline completions

Inline completion (ghost text) is the simplest AI integration, and most editors handle it fine. Minga will support this too. It's not the interesting problem.

The interesting problem is **agentic editing**: AI that doesn't just suggest one line, but reads your codebase, plans changes across multiple files, executes shell commands, and modifies buffers autonomously. That's where single-threaded editors hit their limits, and where Minga's architecture matters.

---

## The IDE isn't dead. It's just wrong.

There's a popular narrative that AI agents will replace the IDE. You'll just talk to a terminal, describe what you want, and the agent will write everything. The editor becomes a vestige.

That hasn't happened. It won't happen, either.

Even the best AI coding agents hit a wall when they touch too many files too quickly. They make mistakes. They misunderstand context. They hallucinate function signatures. And when they do, you need to *see* the code, navigate it, understand what changed, and fix what's wrong. That's what an editor is for.

The proof is in your own workflow. Nobody runs Claude Code or Cursor's agent and then blindly commits the result. You review. You audit. You open files, check diffs, trace through logic, run tests. The editor is still essential; it's just been demoted to a review tool that has no idea an agent exists.

Some people push back here: "I just review the PR diff" or "I fix things by telling the agent what to change." Sure, and sometimes that works. But a PR diff shows you what changed, not *why it's wrong*. You can't jump to a definition from a diff view. You can't trace a call chain across three files. You can't set a breakpoint or run a single test from GitHub's review UI. And telling an agent "fix line 47" only works when you already understand the problem well enough to describe it. For the cases where you don't (where you need to read surrounding code, check types, follow imports, understand state flow) you open an editor. Every time.

The chat prompt has the same limitation. It's great for describing intent, terrible for spatial reasoning about code. "Move the validation before the database call" is easy to say, hard to verify without seeing both locations in context. You end up pasting code into the chat so the agent can see what you're already looking at in your editor. That's two tools doing one job, badly.

The concept of an IDE (a place where you read, write, navigate, build, and debug code) hasn't been made obsolete by AI. It just needs to be reinvented for a world where you're not the only one editing. The old IDE assumed one operator. The new one needs to assume many: you, plus one or more agents, all working concurrently, all visible, all controllable from one place.

That's what Minga is. Not a throwback to the IDE era, but the version of it that AI-assisted coding actually demands: an environment where human editing, agent editing, review, and orchestration all happen in the same process, with the same undo history, in the same viewport.

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

Your current editor was designed for you, sitting at a keyboard, typing one character at a time. AI coding agents are the biggest change in how code gets written since IDEs replaced `ed`. And they need an editor architecture that treats concurrent, independent, observable processes as first-class citizens, not an afterthought.

Every other editor is retrofitting. Minga is building for this future from the ground up.

And unlike the flavor-of-the-week AI editors that keep appearing (and disappearing), Minga isn't built on hype. It's built on a lineage. Emacs proved that an editor is really a Lisp runtime that happens to edit text. That insight, that the editor should be a programmable environment, not a static tool, is almost 50 years old and still correct. Minga carries that same philosophy forward: the editor is a BEAM runtime that happens to edit text. Buffers are processes. Modes are processes. Agents are processes. Everything is extensible, inspectable, and composable because the runtime makes it so.

Emacs survived every editor war because its architecture was deeper than its UI. Minga makes the same bet: get the runtime right and the editor can adapt to whatever comes next, whether that's today's LLM-based agents or whatever replaces them in five years. Editors built as thin wrappers around a specific AI product have a shelf life. Editors built as programmable runtimes don't.

If you've ever:
- Had your editor stutter while an agent was streaming a response
- Wished you could keep editing while an agent runs in the background without any jank
- Wanted to see exactly what an agent is doing from inside your editor
- Wanted to undo agent changes the same way you undo your own
- Wondered why your editor can't handle two agents at once without slowing down

Then Minga is the editor you've been waiting for. The age of AI-assisted coding needs an editor that was designed for it. This is that editor.
