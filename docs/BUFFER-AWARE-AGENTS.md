# Buffer-Aware Agents

How AI agents edit in-memory buffers instead of the filesystem, and why the BEAM makes multi-agent concurrent editing surprisingly tractable.

---

## Status

Phases 1 and 2 are shipped. Agent file tools route through `MingaAgent.ToolRouter`, which checks for open buffers (fork path) before falling through to the changeset overlay or direct filesystem I/O. Buffer forking with three-way merge works. Changeset overlays handle filesystem-level isolation for shell commands.

The sections below describe the design rationale and prior art analysis that motivated this work. Implementation details live in `MingaAgent.ToolRouter`, `MingaAgent.BufferForkStore`, `Minga.Buffer.Fork`, and `MingaAgent.Changeset`.

---

## The Problem (Before This Work)

Minga's agent tools (`EditFile`, `WriteFile`, `ReadFile`) used to bypass the buffer entirely. They went straight to `File.read` and `File.write` on disk. Meanwhile, the `Buffer.Server` GenServer was sitting right there, holding the same file's content in a gap buffer with undo tracking, dirty state, tree-sitter sync, and a batch `apply_text_edits/2` API built for exactly this kind of programmatic editing.

The old data flow looked like this:

```
Agent wants to edit main.ex
    │
    ▼
File.read("main.ex")           ← reads from disk
    │
    ▼
String.replace(content, ...)   ← edits in a throwaway variable
    │
    ▼
File.write("main.ex", new)     ← writes back to disk
    │
    ▼
User sees nothing until they reload the buffer
```

The agent was walking around the house to come in through the back door when the front door was open.

This causes real problems:

- **No undo.** Agent edits don't go on the undo stack. If the agent mangles your file, your only recourse is `git checkout`.
- **No live feedback.** You don't see changes until the buffer reloads from disk (triggered by file watcher or manual `:e`).
- **No tree-sitter sync.** The parser doesn't know about the edit, so highlights go stale until a full reparse.
- **Disk I/O on every edit.** Each `edit_file` call does a full read-modify-write cycle on the filesystem. For an agent making 20 edits to one file, that's 20 round-trips to disk.
- **Multi-agent conflicts.** Two agents editing the same file on disk will clobber each other. The only mitigation today is git worktrees (separate filesystem copies).

---

## The Idea

What if agents edited the buffer, not the filesystem?

The simplest version: agent tools call `Buffer.Server.apply_text_edits/2` instead of `File.read/write`. Edits happen in-memory, appear instantly in the editor, go on the undo stack, and trigger incremental tree-sitter updates.

The more ambitious version: each agent session gets its own fork of the buffer. Multiple agents edit concurrently without conflicts. When they're done, their changes merge back. The editor becomes a collaboration server, not just a viewing layer.

---

## Prior Art: How Existing Tools Handle Agent Edits

No existing tool does what this doc proposes. But the landscape splits into two categories that explain why.

### Editor-integrated agents (get Phase 1 for free)

**Cursor and Windsurf** (VS Code forks) apply AI edits through VS Code's `WorkspaceEdit` API, which routes through Monaco's `TextDocument` model. Edits land in the in-memory buffer, undo works, syntax highlighting updates. The editor also suppresses its own file watcher for writes it originated, avoiding the "file changed on disk, reload?" noise. But this isn't a deliberate architectural choice for AI agents. It's just how VS Code's extension API works. The AI uses the same API any extension would.

**Zed** is the most interesting comparison. Their collaboration system uses CRDT-inspired data structures (operational transform) for human-to-human collaborative editing. But that machinery serves human collaborators, not AI agents. Their AI assistant edits go through Zed's buffer system, same as Cursor, without any multi-agent coordination layer.

**Cline** (VS Code extension) goes through VS Code's buffer API. Same story as Cursor.

None of these do explicit batching to reduce filesystem churn. Each edit is applied individually through the editor's document model. VS Code groups edits into a single undo entry when they come from a `WorkspaceEdit`, but each edit still fires buffer change events internally.

### Standalone CLI agents (all filesystem-direct)

**Claude Code** uses `edit` (find-and-replace via read-modify-write) and `write` (full file overwrite). Each tool call is a separate disk round-trip. No batching. No buffer concept. It's a CLI tool; there are no buffers to route through.

**pi** (the agent harness Minga's agent runs inside) has the same `edit` and `write` tools. Same filesystem-direct approach.

**Aider** generates git diffs and applies them with `git apply`. Clever in that it gets atomic multi-file changes via git's machinery, but still filesystem I/O underneath.

**OpenCode** (Go-based TUI) writes to the filesystem. Same pattern.

### The gap Minga sits in

Minga is an **editor with an integrated agent**, but its agent tools behave like a **standalone CLI agent**. It has buffers, `apply_text_edits/2`, undo stacks, tree-sitter sync, dirty tracking. All the infrastructure for Phase 1 exists. The agent tools just don't use any of it.

Cursor gets Phase 1 "for free" because the AI is a VS Code extension calling the editor's own API. Minga's agent lives inside the editor but bypasses it, going straight to disk.

### What nobody does

- **Buffer forking for multi-agent editing (Phase 2).** No tool supports this. Cursor doesn't run multiple concurrent AI agents. Zed's CRDTs serve human collaborators. Aider runs one session at a time.
- **Explicit edit batching to avoid filesystem churn.** No tool optimizes for this. Editor-integrated agents get partial protection from watcher suppression, but as a side effect of the extension API, not by design.
- **In-memory-first with selective flush.** Every tool either writes to disk immediately (CLI agents) or writes to a buffer that auto-saves on a timer (editors). Nobody treats the buffer as the source of truth with on-demand disk materialization.

The combination of Phase 1 (buffer-routed agent edits) and Phase 2 (forked buffers with three-way merge for concurrent agents) doesn't exist anywhere. The closest analogy is Zed's collaboration CRDTs, but applied to AI agents instead of human collaborators, and with three-way merge instead of character-level operational transforms.

### Why hasn't anyone done this?

Not because it's a bad idea. Because the use case didn't exist when the editors were designed.

**Editors are 10-40 years old. Agent editing is 2 years old.** VS Code's architecture was designed in 2015. Neovim inherited Vim's buffer model from the 1990s. Emacs's buffer system is from the 1980s. Zed is newer (2022) but was designed for human collaborative editing, not AI agents. Every one of these editors was built around the assumption that edits arrive at human speed: a few keystrokes per second, maybe a bulk formatter run occasionally. At that rate, filesystem churn is a non-issue. There's nothing to optimize.

**The editors that have agents are VS Code forks.** Cursor and Windsurf inherited Monaco's entire buffer and extension architecture. Redesigning how the buffer layer handles writes means rewriting core Monaco internals in a codebase with millions of lines of TypeScript. It's vastly easier to bolt the AI onto the existing `WorkspaceEdit` API and ship. The existing API works "good enough" for one agent making sequential edits.

**"Good enough" kills the motivation.** For most users today, Cursor's approach is fine. The agent edits a file, it shows up in the editor, undo works. The file watcher occasionally flickers. Sometimes you get a "file changed on disk" dialog. It's annoying, not broken. There's no acute pain driving a buffer architecture rewrite.

**Standalone agents can't do this even if they wanted to.** Claude Code, Aider, pi, OpenCode are not editors. They don't have buffers. There's no "in-memory" to route through. They'd need to either become an editor or deeply integrate with one. That's a fundamental architecture change, not an optimization toggle.

**The multi-agent case barely exists yet.** Almost nobody runs two AI agents concurrently on the same codebase. Cursor is single-agent. Claude Code is single-session. The scenario that makes buffer forking compelling (two agents, same file, concurrent edits) is still a power-user edge case. Editors optimize for the 99% case first.

### Is this actually a big win?

Yes, but the win is forward-looking, not backward-looking. The trajectory is clear: agents are getting faster, more autonomous, and people will run more of them concurrently. The editing pattern is shifting from "human types, agent suggests" to "human directs, multiple agents execute." Every editor will eventually need to deal with this. The ones built on shared-state, single-event-loop architectures (VS Code/Monaco, Neovim's single-threaded core) will have a much harder time retrofitting it than an editor with process isolation and message-passing serialization baked into the foundation.

Minga's position is genuinely unusual: it's being built now, in the agentic era, on a runtime (the BEAM) whose process model is accidentally perfect for this problem. The `Buffer.Server` GenServer already serializes concurrent access. `apply_text_edits/2` already exists for programmatic batch editing. `EditDelta` already tracks incremental changes for tree-sitter sync. Forking a `Document` struct into a new process is a few lines of code. The infrastructure is there. The agent tools are just wired to the wrong layer.

---

## Performance Reality Check

A natural question: is in-memory editing meaningfully faster than filesystem I/O on a modern NVMe SSD? The honest answer: barely, and that's not the reason to do this.

### Why the raw I/O gap is small

Modern SSDs are fast, but the OS page cache is faster. When an agent calls `File.read("lib/minga/editor.ex")`, that file is almost certainly hot in the kernel's page cache. The syscall copies bytes from kernel memory to userspace. It's not waiting on a disk platter or even an SSD chip. Actual latencies on a warm cache:

| Operation | Filesystem (page cache hit) | Buffer (GenServer call) |
|-----------|---------------------------|------------------------|
| Read a 10KB file | ~10-30µs (4 syscalls + memcpy) | ~2-5µs (message send + reply) |
| String search/replace | ~5-10µs (same either way) | ~5-10µs |
| Write result back | ~10-30µs (3 syscalls, async writeback) | 0µs (just mutated state) |
| **Single edit total** | **~25-70µs** | **~7-15µs** |

That's 3-5x faster per operation, but the absolute numbers are microseconds. Nobody notices 50 microseconds. For a single edit, the performance argument is irrelevant.

Even writes are deceptive. `File.write/2` without `fsync` writes to the page cache and returns immediately. The kernel flushes to SSD asynchronously. So Elixir's write is already effectively a memory operation for latency purposes.

### Where redundant work matters more than raw speed

**Batching.** An agent making 20 edits to one file today does 20 full read-modify-write cycles (20 `File.read` calls, 20 `String.replace` calls, 20 `File.write` calls). Through the buffer, that's one `apply_text_edits/2` call with a list of 20 edits. One GenServer message, one undo entry, one version bump. The win isn't "memory is faster than SSD." It's "1 round-trip vs 20."

**File watcher noise.** Each `File.write` triggers a filesystem notification, which `FileWatcher` picks up, which fires a "file changed on disk" check, which may trigger a buffer reload or auto-reload. Twenty writes in quick succession means twenty watcher events competing with the agent's next edit. Buffer edits produce zero filesystem events.

**Syscall overhead compounds.** A single `File.write` involves 3 syscalls (open, write, close), allocates a file descriptor, and updates directory metadata. One edit? Trivial. An agent rewriting 15 files in a refactoring pass, 20 edits each? That's 900 syscalls. The buffer path does zero.

### The real performance gap: Phase 2, not Phase 1

The strong performance argument lives in buffer forking vs git worktrees. Forking a `Document` struct (copying two binaries and a few integers into a new process) takes microseconds. Creating a git worktree (cloning a directory tree, writing thousands of files, cold `_build` and `deps` caches on first build) takes seconds to minutes. That's the performance gap worth talking about.

### The actual argument for Phase 1 is correctness and UX, not speed

1. **Undo works.** Agent edits go on the undo stack. `u` rolls them back. Today you need `git checkout`.
2. **Instant visibility.** Edits appear in the editor the same frame they're applied. No reload, no file watcher race.
3. **Tree-sitter stays in sync.** Incremental reparse via `EditDelta` instead of a full reparse after noticing the file changed on disk.
4. **No race conditions.** The GenServer mailbox serializes access. Two things editing the same buffer is just two messages in a queue, not two processes fighting over a file descriptor.

Performance is a cherry on top, not the sundae.

---

## Phase 1: Route Agent Tools Through Buffers

This is the 80/20 move. One agent, same buffer, instant edits.

### How it works

```
Agent wants to edit main.ex
    │
    ▼
Look up the Buffer.Server pid for main.ex
    │
    ├─ Found → call Buffer.Server.apply_text_edits/2
    │            ├─ Edit applied in-memory (gap buffer, O(1) at cursor)
    │            ├─ Undo entry pushed
    │            ├─ EditDelta sent to tree-sitter for incremental reparse
    │            ├─ Dirty flag set (user sees unsaved indicator)
    │            └─ Next render frame shows the change
    │
    └─ Not found → open a Buffer.Server for the file, then edit
                   (or fall back to filesystem I/O for unvisited files)
```

### What changes

The agent's `edit_file` tool currently does find-and-replace on raw file content. To work with buffers, it needs to:

1. **Find the match position.** Convert "find this text and replace it" into `{start_line, start_col, end_line, end_col, replacement}`. The buffer content is available via `Buffer.Server.content/1`, and the text search is the same `String.split` logic `EditFile` already uses.
2. **Call `apply_text_edits/2`.** This API already exists, takes a list of positional edits, applies them in a single GenServer call, pushes one undo entry, and bumps the version once.
3. **Handle the "file not open" case.** If no buffer exists for the file, either open one on demand (good for files the user will want to see) or fall back to filesystem I/O (fine for generated files or config that doesn't need undo).

`read_file` and `write_file` get similar treatment. `read_file` returns `Buffer.Server.content/1` when the buffer exists (always fresh, no disk read). `write_file` calls `Buffer.Server.replace_content/2` for existing buffers.

### What you get

- Agent edits appear instantly in the editor. No reload needed.
- Full undo/redo. `u` undoes the agent's last batch of edits.
- Tree-sitter stays in sync. Highlights update incrementally.
- Dirty tracking works. The modeline shows the file is unsaved.
- No disk I/O for reads or edits on open buffers.
- The agent and the user can't corrupt each other because the GenServer mailbox serializes all access. Two edits arriving at the same time are just two messages in a queue.

### What you don't get (yet)

- Two agents editing the same file will still serialize through the GenServer mailbox. They won't clobber each other (that's the benefit of message passing), but the second agent's edit might land in a different context than it expected if the first agent changed the same region.
- The agent still needs to flush to disk before running shell commands (`mix test`, `mix compile`). Builds read from the filesystem, not from buffer memory.

---

## Phase 2: Buffer Forking With Three-Way Merge

This is where multi-agent editing gets interesting.

### The model

When an agent session starts editing a file, Minga forks the `Document` struct: takes a snapshot of the current gap buffer content and hands the agent its own copy. The agent makes all its edits on the fork. The user continues editing the original. When the agent finishes (or when the user wants to review), Minga computes a three-way merge.

```
                    ┌─────────────────────────┐
                    │  Buffer.Server (main.ex) │
                    │  Document: original      │
                    │  User keeps editing here │
                    └───────────┬──────────────┘
                                │
                        fork (snapshot)
                                │
              ┌─────────────────┼─────────────────┐
              │                 │                  │
              ▼                 ▼                  ▼
     ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
     │  Agent Fork A │  │  Agent Fork B │  │  Agent Fork C │
     │  (refactoring)│  │  (tests)      │  │  (docs)       │
     └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
            │                 │                  │
            │      agent finishes editing        │
            │                 │                  │
            ▼                 ▼                  ▼
     ┌─────────────────────────────────────────────────┐
     │  Three-way merge (common ancestor + fork + current) │
     │  Clean merge → auto-apply                           │
     │  Conflict → diff review UI                          │
     └─────────────────────────────────────────────────────┘
```

### Why three-way merge, not CRDT?

CRDTs (Conflict-free Replicated Data Types) are the mathematically elegant solution to concurrent editing. They guarantee that all replicas converge to the same state regardless of operation ordering. Yjs, Automerge, and Diamond Types implement them for text.

But CRDTs solve a harder problem than what agents actually need.

**Human collaborative editing** is character-by-character, real-time, and continuous. Two people typing into the same paragraph simultaneously, seeing each other's cursors move. This demands character-level conflict resolution running on every keystroke. CRDTs were designed for exactly this.

**Agent editing** is discrete, batch-oriented, and sequential within each agent. An agent reads a file, thinks for a few seconds, then emits a block-level edit ("replace lines 45-60 with this new implementation"). It doesn't type character by character. Its edits are well-defined chunks with clear boundaries.

For that editing pattern, three-way merge gives the same practical result with a fraction of the complexity:

1. **Common ancestor:** the document content at fork time.
2. **Theirs:** the agent's final version.
3. **Ours:** the current buffer content (user edits since fork time).
4. **Merge:** apply non-overlapping changes from both sides. Flag overlapping regions as conflicts.

This is the same algorithm `git merge` uses, applied at the buffer level instead of the file level. Minga already has `List.myers_difference/2` for computing diffs (used by `Git.Diff`). The merge infrastructure is half-built.

### When CRDTs would matter

If two agents are editing the *same function* simultaneously, and you want both sets of changes to merge cleanly without human review, then you need something smarter than three-way merge. This is the CRDT use case.

But in practice, agents almost never do this. Good agent orchestration gives each agent a distinct task: "refactor module A" and "add tests for module B." They touch different files, or different regions of the same file. Three-way merge handles this cleanly.

If the Minga agent panel ever supports true multi-agent orchestration within a single file (e.g., "Agent A rewrites the function body while Agent B updates the typespec"), CRDTs become worth investigating. Until then, they're solving a problem that doesn't exist yet.

### The merge workflow

When an agent fork is ready to merge:

1. Compute the diff between the common ancestor and the fork (what the agent changed).
2. Compute the diff between the common ancestor and the current buffer (what the user changed).
3. If the changed regions don't overlap, apply both. Auto-merge. The buffer updates and the user sees the combined result.
4. If regions overlap, open the diff review UI (`Minga.Agent.DiffReview`, which already exists) and let the user accept, reject, or edit each conflicting hunk.

This is the same UX as reviewing a PR diff, applied to buffer content. The user stays in control.

### Fork implementation

A fork is cheap. The `Document` struct is immutable data (two binaries + some integers). "Forking" means copying the struct into a new process. No CoW tricks needed; Erlang's garbage collector handles it.

```elixir
# Conceptual API
{:ok, fork_pid} = Buffer.Fork.start_link(
  parent: buffer_pid,
  session: agent_session_id
)

# Agent tools route to the fork instead of the parent
Buffer.Fork.apply_text_edits(fork_pid, edits)

# When done, merge back
Buffer.Fork.merge(fork_pid)
# → :ok (clean merge, applied automatically)
# → {:conflict, hunks} (user needs to review)
```

Each fork is its own GenServer, supervised under the agent session's process tree. If the agent session crashes, the fork is cleaned up automatically. No orphaned state.

### What this replaces

Git worktrees exist today because two agents can't edit the same filesystem safely. Each worktree is a full checkout: separate directory, separate `_build`, separate `deps`. The first build is slow (cold caches), and you need to remember to clean up when done.

Buffer forking replaces worktrees for the common case of "multiple agents editing at the same time." The agents share the same BEAM process, the same compiled `_build`, and the same `deps`. Forks are instant (copy a struct) instead of slow (clone a directory tree). Merges happen in-memory instead of through git.

Worktrees would still be useful for truly isolated work that needs its own build environment (e.g., testing a dependency upgrade while the main checkout stays on the current version). But for "run two agents on different parts of the same project," buffer forking is faster and simpler.

---

## Phase 3: Flush-to-Disk for Shell Commands

One thing agents do that pure in-memory editing doesn't cover: running shell commands. `mix test`, `mix compile`, `cargo build`, `grep`, etc. all read from the filesystem. If the agent edited the buffer but never saved, the build sees stale files.

### The solution: selective flush

Before running a shell command, the agent flushes its dirty buffers to disk:

```
Agent calls `mix test`
    │
    ▼
Agent runtime checks: which buffers have I modified?
    │
    ▼
For each dirty buffer:
    Buffer.Server.save(pid)       ← writes to disk
    │
    ▼
Shell command runs against up-to-date files
    │
    ▼
After command completes:
    (files stay on disk, buffer dirty flag cleared)
```

This is the write-back cache pattern. The buffer is the source of truth during editing. Disk is a persistence layer that gets synced on demand (explicit save, pre-shell-command flush, or auto-save timer).

For forked buffers, the flush is trickier. You can't write the fork's content to the real file path without clobbering the user's version. Options:

1. **Temporary directory.** Write fork contents to a temp directory that mirrors the project structure. Set the shell command's working directory to the temp dir. This is essentially a lightweight worktree, but only for the files the agent actually modified.
2. **Overlay filesystem.** On Linux, use overlayfs to layer the fork's changes on top of the real project directory. The shell sees the combined view. This is elegant but platform-specific.
3. **Build in the real directory with explicit save.** The user explicitly merges the fork first, then the agent runs commands. This is the simplest option and avoids the whole "two versions of the same file" problem by making it sequential.

Option 3 is the pragmatic starting point. Options 1 and 2 are optimizations for later.

---

## Why the BEAM Is Uniquely Good at This

Most of this design is only practical because of specific BEAM properties:

**Process isolation means forks can't corrupt each other.** Each fork is its own process with its own heap. A bug in one agent's editing logic can't corrupt another agent's fork or the user's buffer. The VM enforces this, not convention.

**GenServer mailbox serialization eliminates races.** Two edits arriving at the same buffer are processed sequentially. No locks, no mutexes, no "check if modified" flags. The mailbox is the synchronization primitive.

**Cheap process spawning makes forks free.** Spawning a new BEAM process takes microseconds and ~2KB of memory. Creating a fork for each agent session is not a resource concern.

**Per-process GC means forks don't pause the editor.** A fork accumulating large undo histories gets garbage collected independently. The user's editing stays responsive.

**Supervision trees clean up automatically.** Agent session crashes? The supervisor tears down the session's forks. No cleanup code needed. No orphaned state to find and delete later.

**Message passing works across machines.** If Minga ever supports remote agent sessions (agent running on a beefy cloud machine, editor running locally), the same GenServer protocol works over distributed Erlang. The fork doesn't care where its parent buffer lives.

---

## What CRDTs Would Look Like (If We Ever Need Them)

For completeness, here's what a CRDT-based approach would involve. This is Phase 3+ territory, only worth building if Phase 2's three-way merge proves insufficient.

### The right CRDT for text

Sequence CRDTs like RGA (Replicated Growable Array) or YATA (Yet Another Transformation Approach, used by Yjs) assign each character a unique, globally ordered ID. Insertions and deletions are operations on these IDs rather than on positional indices. This means two replicas can independently insert text at "position 5" and the CRDT deterministically decides the final ordering without conflicts.

### Integration options

1. **Replace the gap buffer with a CRDT document.** The `Document` struct becomes a CRDT sequence internally. Every edit (user or agent) is a CRDT operation. Merging is free because the data structure handles it natively. The cost: the gap buffer is simple and fast (two binaries, O(1) insert at cursor). A CRDT sequence is more complex (per-character metadata, tombstones for deletes, causality tracking). Every editing operation gets slower by a constant factor.

2. **CRDT layer on top of the gap buffer.** Keep the gap buffer for the user's editing (fast, simple). When an agent forks, translate gap buffer content into a CRDT document. Agent edits are CRDT operations. At merge time, translate back. The cost: two representations of the same content, with a translation layer that must stay correct.

3. **Use an existing CRDT library via a Port or NIF.** Yjs has Rust bindings (y-crdt). Automerge has a Rust core. Either could run as a NIF or Port that the BEAM calls into for merge operations. The cost: external dependency, FFI boundary, another moving part.

### The semantic merge problem

CRDTs guarantee syntactic convergence: all replicas reach the same text. They do not guarantee semantic correctness. If Agent A adds a function calling `foo()` and Agent B renames `foo` to `bar`, the CRDT will merge both edits into a file that has a broken `foo()` call. The text merged cleanly. The code is wrong.

This is the same class of problem as a clean git merge that breaks tests. No text-level merge algorithm can solve it because it requires understanding the programming language's semantics, not just its text.

For AI agents, this means: even with perfect CRDT merge, you still want a "run tests after merge" step. The merge gives you a candidate. Tests tell you if the candidate is correct.

---

## Summary

| Phase | What | Effort | Benefit |
|-------|------|--------|---------|
| **1** | Agent tools route through `Buffer.Fork` for open buffers | ✅ Shipped | In-memory isolation, instant edits, undo integration |
| **2** | Buffer forking with three-way merge per agent session | ✅ Shipped | Multi-agent concurrent editing without worktrees |
| **3** | Filesystem overlay for shell commands | ✅ Shipped (via Changeset) | Agents can build/test against isolated edits |
| **4** | CRDT-based merge (if three-way merge proves insufficient) | Not started | True simultaneous editing of the same code region |

Phases 1-3 shipped as part of the runtime-first architecture work. Phase 4 is a research project that may never be needed. See the "When CRDTs Would Matter" section above for the conditions that would motivate it.

---

## Open Questions

- **Should forks share the undo stack with the parent?** Probably not. The fork is a separate editing context. But the user might want to undo-browse the agent's changes after merge. Maybe the fork's undo history gets appended to the parent's stack as a single "agent edit" entry.

- **How does this interact with LSP?** The language server sees the filesystem. If an agent's fork adds a new function, `elixir-ls` won't know about it until the fork is flushed to disk. This limits LSP-powered features (completion, diagnostics) in fork context. Possible fix: send `textDocument/didChange` notifications for fork content, using a virtual URI scheme.

- **What about agent tools that create new files?** `write_file` for a path that doesn't exist yet has no buffer to route to. You'd create a new buffer on demand, but it needs to be associated with the agent's fork context so it merges with the fork, not directly into the project.

- **Can forks be nested?** An agent might want to try two approaches and pick the better one. That's a fork of a fork. Three-way merge still works (the fork's parent is the common ancestor), but the UX for reviewing nested forks needs thought.

- **How do you visualize fork state?** The user needs to know: which agents have active forks, which files each fork has modified, how much the fork has diverged from the current buffer. A "branches" panel (like a git branch list but for buffer forks) could work here.
