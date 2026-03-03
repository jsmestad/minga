# Minga Architecture

How a text editor built on telecom infrastructure actually works, and why
it's a surprisingly good idea.

---

## The Big Idea

Most text editors are single-process programs. Buffer state, rendering, input
handling, plugin execution, all living in one address space. A crash in any
component takes down everything. Your unsaved work disappears.

Minga splits the editor into **two OS processes** with completely isolated
memory:

```
┌─────────────────────────────────┐     ┌───────────────────────────┐
│         BEAM (Elixir)           │     │      Zig + libvaxis       │
│                                 │     │                           │
│  ┌───────────────────────────┐  │     │  Terminal rendering       │
│  │ Supervisor ("Stamm")      │  │     │  Keyboard input capture   │
│  │  ├── Buffer.Supervisor    │  │     │  Tree-sitter parsing      │
│  │  │    ├── Buffer A        │  │ ◄──►│  Screen drawing           │
│  │  │    ├── Buffer B        │  │     │  Floating panels          │
│  │  │    └── Buffer C        │  │     │                           │
│  │  ├── Port.Manager ────────│──│─────│──► stdin/stdout           │
│  │  └── Editor               │  │     │                           │
│  └───────────────────────────┘  │     └───────────────────────────┘
│                                 │
│  Command.Registry               │
│  Filetype.Registry              │
│  FileWatcher                    │
└─────────────────────────────────┘
```

The two processes communicate over a binary protocol on stdin/stdout. They
share no memory. Either can crash without corrupting the other.

This isn't a workaround for a limitation. It's the whole point.

---

## Why the BEAM?

The Erlang VM (BEAM) was designed in the 1980s to run telephone switches,
systems that serve millions of concurrent calls and literally cannot go down.
Its design priorities are exactly what a text editor needs but has never had:

### Fault isolation through processes

Every buffer in Minga is its own BEAM process (a GenServer). Processes don't
share memory. If a buffer process encounters a corrupt state, it crashes and
gets restarted by its supervisor. Other buffers are completely unaffected.

```
Buffer.Supervisor (DynamicSupervisor, one_for_one)
├── Buffer "main.ex"     ← crashes here
├── Buffer "router.ex"   ← completely unaffected
└── Buffer "schema.ex"   ← completely unaffected
```

In a traditional editor, a buffer corruption bug means restarting the entire
application. In Minga, it means one buffer reinitializes while everything
else keeps running.

### Supervision trees: "let it crash"

The BEAM's philosophy isn't "prevent all crashes." It's "crashes are normal,
recover from them automatically." Minga's supervision tree encodes the
dependency relationships between components:

```
Minga.Supervisor (rest_for_one)
├── Filetype.Registry        ← static data, crashes are rare
├── Buffer.Supervisor        ← if this dies, restart it (buffers survive)
├── Command.Registry         ← rebuilt from module attributes on restart
├── Diagnostics              ← source-agnostic diagnostic aggregation
├── LSP.Supervisor           ← DynamicSupervisor for LSP client processes
├── FileWatcher              ← OS file notifications
├── Port.Manager             ← owns the Zig renderer process
└── Editor                   ← orchestration, depends on everything above
```

The `rest_for_one` strategy means: if the Port Manager crashes, the Editor
restarts too (since it depends on the renderer), but buffers are untouched.
Your undo history, cursor positions, unsaved changes: all preserved. The
renderer comes back up, re-renders the current viewport, and you're exactly
where you were.

### Message passing over shared state

The Editor process never directly touches buffer memory. It sends messages:

```elixir
# Editor asks the buffer for its content
{content, cursor} = Buffer.Server.content_and_cursor(buffer_pid)

# Buffer process handles this in isolation
def handle_call(:content_and_cursor, _from, state) do
  {:reply, {GapBuffer.content(state.gap_buffer), GapBuffer.cursor(state.gap_buffer)}, state}
end
```

This eliminates an entire class of bugs: data races, torn reads, iterator
invalidation. The buffer's state is only ever accessed by the buffer's
process. Period.

### Per-process garbage collection

Each BEAM process has its own heap and its own garbage collector. When a
buffer process GCs, it doesn't pause the editor or the renderer. A large
file's buffer can collect its garbage without affecting the responsiveness
of a small file you're actively editing.

Traditional editors in GC'd languages (VS Code/Electron, editors in Java or
Go) have global GC pauses that cause visible input latency spikes. The BEAM's
per-process GC eliminates this entirely.

---

## Why Zig for Rendering?

The BEAM is excellent at concurrency and fault tolerance. It is terrible at
drawing characters on a terminal. It has no concept of raw terminal mode, ANSI
escape sequences, or low-level input decoding.

Rather than fight this with NIFs (which crash the entire VM when they segfault)
or Ports to C (which require manual memory management), Minga uses **Zig**:

- **No hidden allocations:** every byte of memory is explicit
- **Compiles C natively:** tree-sitter grammars (written in C) compile as
  part of the Zig build with zero FFI overhead
- **Safety without runtime cost:** bounds checking, null safety in debug;
  zero overhead in release
- **Single binary output:** no dynamic linking, no runtime dependencies

The Zig process uses [libvaxis](https://github.com/rockorager/libvaxis) for
terminal rendering, a modern library that handles the enormous complexity of
terminal emulator differences, Unicode width calculation, and efficient
screen updates.

### Why not a NIF?

NIFs (Native Implemented Functions) run inside the BEAM process. A segfault
in a NIF crashes the entire Erlang VM: every buffer, every process,
everything. This directly contradicts Minga's fault tolerance model.

A Port is an OS-level process boundary. The Zig renderer can segfault, and
the BEAM keeps running. The supervisor detects the Port died, restarts the
Port Manager, and the Editor re-renders. Zero data loss.

---

## The Port Protocol

BEAM and Zig communicate via `{:packet, 4}`. Each message is prefixed with
a 4-byte big-endian length, followed by a 1-byte opcode and opcode-specific
binary fields. This is a simple, fast, zero-copy-friendly wire format.

### Zig → BEAM (input events)

| Opcode | Event | Payload |
|--------|-------|---------|
| `0x01` | Key press | `codepoint::32, modifiers::8` |
| `0x02` | Resize | `width::16, height::16` |
| `0x03` | Ready | `width::16, height::16` |
| `0x04` | Mouse event | `row::16, col::16, button::8, mods::8, type::8` |
| `0x30` | Highlight spans | `version::32, count::32, [start::32, end::32, id::8]...` |
| `0x31` | Highlight names | `count::16, [len::16, name]...` |
| `0x32` | Grammar loaded | `success::8, name_len::16, name` |

### BEAM → Zig (render commands)

| Opcode | Command | Payload |
|--------|---------|---------|
| `0x10` | Draw text | `row::16, col::16, fg::24, bg::24, attrs::8, len::16, text` |
| `0x11` | Set cursor | `row::16, col::16` |
| `0x12` | Clear | (empty) |
| `0x13` | Batch end | (empty); signals Zig to flush the frame |
| `0x15` | Cursor shape | `shape::8` (block / beam / underline) |
| `0x20` | Set language | `len::16, name` |
| `0x21` | Parse buffer | `version::32, len::32, content` |
| `0x22` | Set highlight query | `len::32, query_text` |
| `0x23` | Load grammar | `name_len::16, name, path_len::16, path` |

Every render frame follows the pattern: `clear` → N × `draw_text` →
`set_cursor` → `set_cursor_shape` → `batch_end`. The Zig renderer
double-buffers and only writes changed cells to the terminal.

---

## Life of a Keystroke

Here's what happens when you press `dd` (delete a line) in normal mode:

```
1. Terminal delivers raw bytes to the Zig process
2. libvaxis decodes the key event (codepoint + modifiers)
3. Zig encodes a key_press message (0x01) and writes to stdout
4. BEAM Port reads the length-prefixed message
5. Port.Manager decodes the event and sends it to the Editor process
6. Editor passes the key to the Normal mode FSM
7. First `d`: Mode returns {:pending, :operator_pending}, waiting for motion
8. Editor transitions to operator-pending mode
9. Second `d`: Mode recognizes `dd`, returns {:execute, :delete_line}
10. Editor calls Operator.delete_line on the buffer's GenServer
11. Buffer.Server updates its gap buffer, pushes undo entry
12. Editor takes a render snapshot from the buffer
13. Renderer converts buffer state into draw_text commands
14. Port.Manager batches commands and writes to Port stdin
15. Zig process reads commands, updates its cell grid
16. batch_end triggers a flush; changed cells written to terminal
17. You see the line disappear
```

Total time: under 1ms for the BEAM side. The Zig render is
practically instant for typical terminal sizes.

---

## Syntax Highlighting Pipeline

Tree-sitter parsing runs in the Zig process to avoid sending parse trees
across the protocol boundary. The BEAM controls *what* to parse and *how*
to color it; Zig does the actual parsing.

```
File opened
    │
    ▼
BEAM detects filetype (:elixir)
    │
    ▼
BEAM sends set_language("elixir") to Zig
    │
    ▼
Zig selects pre-compiled grammar + embedded highlight query
    │
    ▼
BEAM sends parse_buffer(version, content) to Zig
    │
    ▼
Zig parses with tree-sitter, runs highlight query
    │
    ▼
Zig sends highlight_names (capture names) + highlight_spans back
    │
    ▼
BEAM maps capture names → Doom One theme colors
    │
    ▼
BEAM slices visible lines at span boundaries using binary_part (O(1))
    │
    ▼
BEAM emits draw_text commands with per-segment fg/bg/attrs
    │
    ▼
Zig renders colored text to terminal
```

All 24 grammars are compiled into the Zig binary. Highlight queries are
embedded via `@embedFile` and pre-compiled on a background thread at startup.
First-file highlighting appears in ~16ms.

Users can override queries by placing `.scm` files in
`~/.config/minga/queries/{lang}/highlights.scm`.

---

## Buffer Architecture

Each buffer is a GenServer wrapping a gap buffer, the classic data structure
used by Emacs since the 1980s. Text is stored as two binaries with a "gap"
at the cursor position:

```
Content: "Hello, world!"
Cursor after "Hello"

before: "Hello"
after:  ", world!"

Insert 'X': before becomes "HelloX", no copying of ", world!"
```

Insertions and deletions at the cursor are O(1). Only the text on one side
of the gap changes. Moving the cursor is O(k) where k is the distance moved,
but since most movements are small (next word, next line), this is fast in
practice.

### Byte-indexed positions

All positions in Minga are `{line, byte_col}`, byte offsets within a line,
not grapheme indices. This was a deliberate choice:

- **O(1) string slicing:** `binary_part/3` with byte offsets is a direct
  pointer operation. Grapheme indexing requires O(n) scanning.
- **Tree-sitter alignment:** tree-sitter returns byte offsets natively.
  No conversion needed for syntax highlighting.
- **ASCII fast path:** for ASCII text (>95% of code), byte offset equals
  grapheme index. Zero overhead for the common case.

Grapheme conversion happens only at the **render boundary**, when
converting cursor position to screen column. This runs only for visible
lines (~40–50 per frame), which is negligible.

---

## What This Enables

The two-process, supervision-based architecture isn't just about crash
recovery. It opens up possibilities that traditional editors can't easily
achieve:

### Runtime customization: the Emacs inheritance

One of the most powerful things about Emacs is that it's a living, mutable
environment. You can change any behavior at runtime (redefine a function,
tweak a variable, override a keybinding) and the editor adapts immediately
without restarting. This is what makes Emacs endlessly customizable: the
editor isn't a fixed binary, it's a runtime you reshape while you use it.

Minga inherits this philosophy through the BEAM. Every component in the
editor is a running process with mutable state. You can reach into any
process and change its behavior at runtime, not by patching global
variables, but by sending it a message that updates its state.

**This is the key insight: BEAM processes are living, isolated environments
with their own state.** Each buffer process carries its own configuration.
You don't need a global settings dictionary with special "buffer-local
override" lookup chains. You just change the state inside that buffer's
process. Global config stays untouched. Other buffers stay untouched.

```elixir
# Change tab size for just this one buffer, at runtime
Buffer.Server.set_option(buffer_pid, :tab_size, 2)

# The buffer process updates its own state. That's it.
# No global config mutated. No other buffers affected.
def handle_call({:set_option, key, value}, _from, state) do
  {:reply, :ok, put_in(state.options[key], value)}
end
```

This maps directly to how Emacs buffer-local variables work, but with
stronger guarantees. In Emacs, buffer-local variables are a layer on top of
a global symbol table, and the interaction between `setq`, `setq-local`,
`make-local-variable`, and `default-value` is notoriously confusing. In
Minga, the separation is structural: each process *is* its own namespace.
There's no mechanism for one buffer to accidentally mutate another's state
because processes don't share memory. The isolation isn't a convention you
have to follow. It's enforced by the VM.

The natural resolution order for any setting:

```
Buffer.Server state     (highest priority: runtime overrides for this buffer)
    ▼ falls through to
Filetype defaults       (conventions, e.g. Go uses tabs, Python uses 4 spaces)
    ▼ falls through to
Editor global defaults  (user's base config: tab_size, theme, scroll_off)
```

Each layer lives in a different process. Setting a buffer-local override is
a message to that buffer's GenServer. Setting a filetype default updates the
Filetype.Registry process. Changing a global default updates the Editor
process. No locks, no synchronization, no invalidation callbacks. Just
processes with state and a clear lookup order.

This extends beyond simple options. Keybindings, mode behavior, auto-pair
rules, highlight themes: anything that lives in process state can be
customized per-buffer at runtime. Open a Markdown file and want different
keybindings? That buffer's process holds its own keymap overlay. Working in
a monorepo where one subdirectory uses different formatting? Those buffers
carry their own formatter config. The process model makes "buffer-local
everything" the default architecture, not a special case bolted on later.

And because the BEAM supports hot code reloading, the customization story
goes even deeper: you can redefine *functions* at runtime, not just data.
Load a new module, replace a motion implementation, add a command, in a
running editor, without restarting. This is the same capability that lets
Erlang telecom systems upgrade without dropping calls. In Minga, it means
your editor is as malleable as Emacs, but with process isolation that
Emacs Lisp never had.

### Hot code reloading

The BEAM supports replacing running code without restarting the VM. In the
future, Minga could update its editor logic, add new commands, or fix bugs
in a running session without closing files or losing state.

### Distributed editing

BEAM processes can communicate across machines transparently. Two Minga
instances could theoretically share buffers over the network using the same
GenServer protocol they use locally. This is how Erlang was designed to work.

### Plugin isolation

Future plugins will run as supervised BEAM processes. A misbehaving plugin
crashes its own process tree. It can't corrupt buffer state, freeze the
renderer, or take down other plugins. The supervisor restarts it, and you
get an error message instead of a dead editor.

### Agentic AI integration

This is where Minga's architecture becomes genuinely prescient. AI coding
agents (tools like Claude Code, Cursor, Aider, and Copilot) work by
spawning external processes: LLM API calls, shell commands, file rewrites,
tool invocations. These processes are inherently unreliable. API calls time
out. Shell commands hang. File operations conflict with what you're editing.
An agent might try to write to a buffer you're actively modifying.

In a traditional editor, this is a nightmare. Agent processes share the
editor's address space or communicate through fragile async bridges. A hung
API call can freeze the UI. A botched file write can corrupt buffer state.
Editors bolt on agent support as an afterthought and pray nothing goes wrong.

Minga's architecture was *designed* for exactly this kind of workload:

- **Each agent session runs as its own supervised process tree.** If an agent
  crashes, hangs, or produces garbage, its supervisor detects the failure
  and cleans up. Your editor keeps running. Your buffers are untouched.

- **Buffer access goes through message passing.** An agent process that wants
  to modify a file sends a message to that buffer's GenServer. The buffer
  processes the edit atomically. There's no possibility of a torn write or a
  race condition between your typing and the agent's edits. The buffer's
  mailbox serializes them naturally.

- **The BEAM's preemptive scheduler prevents starvation.** A long-running
  agent can't freeze your UI. The scheduler guarantees every process gets
  CPU time, regardless of what any single process is doing. You keep editing
  while the agent works in the background, not because of careful async
  engineering, but because the VM enforces it at the scheduler level.

- **Process monitoring enables real-time feedback.** The editor can monitor
  agent processes and reflect their status in the UI: running, waiting for
  API response, applying changes, failed. When an agent process dies, the
  editor knows immediately and can display the error or offer to retry.

- **Concurrent agents are free.** Want to run a code review agent on one
  buffer while a refactoring agent works on another? Those are just processes.
  The BEAM was built to run millions of them. There's no thread pool to tune,
  no async runtime to configure, no event loop to worry about blocking.

Most editors are trying to retrofit agent support onto architectures that
assumed a single human operator making sequential edits. Minga's process
model treats "external thing wants to modify a buffer" as a first-class
operation, because that's literally how the editor itself works internally.

### Concurrent background work

LSP communication, file indexing, git operations: these can run as separate
BEAM processes without blocking the editor. The BEAM's preemptive scheduler
ensures no single process can starve the UI, even under heavy load. This is
qualitatively different from async/await in single-threaded runtimes. It's
true preemptive concurrency with fairness guarantees.

---

## Trade-offs

Honest accounting of what this architecture costs:

| Trade-off | Why we accept it |
|-----------|-----------------|
| **Serialization overhead** (every render frame crosses a process boundary) | The protocol is ~50 bytes per draw command. At 60fps with 50 visible lines, that's ~150KB/s, trivial for a pipe. |
| **Two binaries to ship** (Elixir release + Zig executable) | Burrito packages everything into a single distributable binary. |
| **BEAM startup time** (the Erlang VM isn't instant) | ~200ms cold start. Acceptable for an editor you keep open. |
| **Memory overhead** (the BEAM VM has a baseline footprint) | ~30MB for the VM + processes. Comparable to Neovim with plugins. |
| **Latency floor** (message passing adds microseconds vs direct function calls) | Measured end-to-end keystroke latency is <1ms. Below human perception. |

None of these are deal-breakers. The fault tolerance, process isolation, and
concurrency model more than compensate.
