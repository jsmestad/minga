# Performance Optimizations for Minga

This document catalogues concrete performance improvements that leverage BEAM VM internals, JIT compiler behaviour (OTP 25+), and Elixir/Erlang idioms. Each section identifies the current bottleneck, explains *why* it's slow on the BEAM, and proposes a fix.

---

## Already Implemented

The following optimizations have been completed (see commit `8beec9d`):

- **Gap Buffer: `count_newlines`** uses `:binary.matches/2` (Boyer-Moore C) instead of `String.graphemes/1 |> Enum.count/2`.
- **Gap Buffer: multi-clause `move/2`** split from single `case` into 4 function clauses for JIT jump table optimization.
- **Gap Buffer: `clear_line/2` + `content_and_cursor/1`** compound operations that eliminate multiple GenServer round-trips. `change_line` went from N+5 GenServer calls to 1.
- **Motion: tuple indexing** all grapheme lists converted to tuples; `elem/2` (O(1)) replaces `Enum.at/2` (O(n)), turning O(n²) motions to O(n).
- **Motion: binary pattern matching for char classification** `classify_char/1` with guards replaces `word_char?` regex. Hot helpers inlined with `@compile {:inline, ...}`.
- **Motion: multi-clause functions replacing `cond`** `advance_word_forward/4`, `advance_word_end/4`, bracket scan helpers extracted as multi-clause functions.
- **Editor: `content_and_cursor/1`** 12 separate `content()` + `cursor()` GenServer call pairs replaced with single round-trip.
- **Git: in-memory diffing** `Git.Buffer` caches HEAD content and diffs against current buffer using `List.myers_difference/2` in pure Elixir. No `git diff` subprocess spawned on edits. Git commands only run at buffer open and explicit stage operations.
- **BEAM VM tuning** (see below)

---

## BEAM VM Tuning

The BEAM's defaults are tuned for web servers: many concurrent connections, high throughput, long-running processes. An editor is the opposite: single user, latency-sensitive, few processes, bursty allocations from the render loop, and long idle periods between keystrokes. Minga ships custom VM flags that address three areas:

### Scheduler and thread configuration (`rel/vm.args.eex`, `bin/minga`)

Scheduler count (`+S`) and dirty IO threads (`+SDio`) are left at BEAM defaults. Reducing schedulers provides negligible benefit once busy-waiting is disabled (see below), and risks starving background work (agent streaming, LSP, git) under load.

| Flag | Default | Minga | Why |
|------|---------|-------|-----|
| `+A 4` | 1 | 4 | Async threads handle Port I/O (Zig renderer, tree-sitter parser). 4 gives headroom for both Ports plus file operations. |

### Scheduler wake/sleep behavior

| Flag | Default | Minga | Why |
|------|---------|-------|-----|
| `+sbwt none` | short | none | Disable busy-waiting. The editor is idle between keystrokes; busy-waiting burns CPU and battery for nothing. |
| `+sbwtdcpu none` | short | none | Same for dirty CPU schedulers. |
| `+sbwtdio none` | short | none | Same for dirty IO schedulers. |
| `+swt very_low` | low | very_low | Wake schedulers faster when a keystroke arrives. Low latency matters more than throughput for an editor. |
| `+swtdcpu very_low` | low | very_low | Same for dirty CPU schedulers. |
| `+swtdio very_low` | low | very_low | Same for dirty IO schedulers. |

### Memory allocators

| Flag | Default | Minga | Why |
|------|---------|-------|-----|
| `+MBas aobf` | bf | aobf | Address-order best fit reduces fragmentation for bursty allocation patterns (render loop builds then discards IO lists every frame). |
| `+Mea min` | (default) | min | Return unused memory carriers to the OS sooner. Editors should have a small idle footprint. |
| `+MBacul 0` | (default) | 0 | Abandon carriers more aggressively. Don't hold memory the editor isn't using. |
| `+hmbs 32768` | 262144 | 32768 | Lower minimum binary virtual heap. Triggers binary GC sooner on processes that churn binaries (Editor, Buffer.Server during render and streaming). |

### Per-process GC tuning (Elixir code)

Applied in `init/1` of hot GenServer processes:

```elixir
Process.flag(:fullsweep_after, 20)   # Default is 65535; frequent full GC reclaims dead binary refs
Process.flag(:min_heap_size, 4096)   # Pre-allocate larger heap; avoids repeated grow-and-GC cycles
```

Processes with this tuning:
- `Minga.Editor` (render loop, state management)
- `Minga.Buffer.Server` (gap buffer, binary churn on edits)
- `Minga.Port.Manager` (binary render commands every frame; fullsweep only, no min_heap bump)

### Development vs release

- **`mix minga`**: VM flags aren't available after the BEAM starts. Use `bin/minga` wrapper script which sets `ERL_FLAGS` before launching Mix, or set `ERL_FLAGS` manually.
- **Release / Burrito**: `rel/vm.args.eex` is compiled into the release and read by the Burrito launcher automatically. No user action needed.
- **Per-process GC tuning**: Applied in Elixir code at process startup. Works in both dev and release.

### Overriding flags

Any flag can be overridden at runtime. Flags in `ERL_FLAGS` are appended after the vm.args defaults, so later flags win:

```bash
# Try more aggressive scheduler reduction
ERL_FLAGS="+S 2:2" bin/minga

# Disable all custom flags (pass empty to override)
ERL_FLAGS=" " mix minga
```

### Future work

- Measure memory footprint with `:erlang.memory/0` and OS RSS before/after.
- Profile render latency via `[render:content]` log timings.

---

## Agent Edit Performance

Agent tools (`EditFile`, `WriteFile`, `ReadFile`) are a distinct performance domain from human keystroke editing. An agent making 20 edits to a single file in a refactoring pass creates a different bottleneck profile than a human typing one character at a time.

### Current path: filesystem round-trips

Each `edit_file` call does: `File.read` (4 syscalls) → `String.split` (find match) → `String.replace` → `File.write` (3 syscalls). For 20 edits to one file, that's 20 full read-modify-write cycles, 140 syscalls, and 20 `FileWatcher` notifications that trigger "file changed on disk" checks.

The raw I/O isn't the bottleneck (OS page cache makes reads/writes effectively memory operations). The problems are:

1. **Redundant work per edit.** Each `File.read` re-reads content the buffer already holds. Each `File.write` triggers a watcher event that may cause a buffer reload, competing with the next edit.
2. **No batching.** 20 tool calls = 20 filesystem round-trips. Each one allocates a fresh binary for the full file content, does the string replace, then discards it.
3. **No incremental tree-sitter sync.** The parser doesn't learn about individual edits. It gets a full reparse trigger after each file watcher notification.

### Planned path: buffer-routed edits

Route through `Buffer.Server.apply_text_edits/2`: one GenServer call with a list of edits, one undo entry, one version bump, one `EditDelta` batch for tree-sitter. Zero filesystem events.

| Metric | Filesystem (20 edits) | Buffer (20 edits, 1 batch) |
|--------|----------------------|---------------------------|
| Syscalls | ~140 (7 per edit × 20) | 0 |
| Binary allocations | 40 (read + write per edit) | 1 (edit list) |
| FileWatcher events | 20 | 0 |
| Tree-sitter reparses | 20 (one per watcher notification) | 1 (incremental) |
| Undo entries | 0 (not on stack) | 1 |

### Buffer fork vs git worktree

For multi-agent concurrent editing, the performance gap is dramatic:

| Operation | Git worktree | Buffer fork |
|-----------|-------------|-------------|
| Create | Seconds to minutes (clone directory, cold caches) | Microseconds (copy a struct into a new process) |
| Memory | Full checkout + separate `_build` + `deps` | Two binaries + a few integers |
| First build | Cold (recompile everything) | Shared `_build` and `deps` |
| Merge | `git merge` (disk-based, may need conflict resolution) | Three-way merge in memory, instant for non-overlapping changes |
| Cleanup | `git worktree remove` + `git worktree prune` | Process exits, garbage collected automatically |

See [BUFFER-AWARE-AGENTS.md](BUFFER-AWARE-AGENTS.md) for the full design.

---

## Table of Contents

1. [Gap Buffer: Eliminate Repeated Full-Text Materialization](#1-gap-buffer-eliminate-repeated-full-text-materialization)
2. [Gap Buffer: Replace Grapheme Lists with Binary Walking](#2-gap-buffer-replace-grapheme-lists-with-binary-walking)
3. [Gap Buffer: Use IOdata Instead of Binary Concatenation](#3-gap-buffer-use-iodata-instead-of-binary-concatenation)
4. [Motion Module: Avoid Temporary Document + Content Copies](#4-motion-module-avoid-temporary-gapbuffer--content-copies)
5. [Editor: Batch Remaining Buffer.Server Mutations into Single Calls](#5-editor-batch-remaining-bufferserver-mutations-into-single-calls)
6. [Editor: Pre-build Render Binaries with IOlists](#6-editor-pre-build-render-binaries-with-iolists)
7. [Undo/Redo: Structural Sharing via Zipper or Diff-Based Stack](#7-undoredo-structural-sharing-via-zipper-or-diff-based-stack)
8. [TextObject: Avoid Flattening Entire Buffer for Paren Matching](#8-textobject-avoid-flattening-entire-buffer-for-paren-matching)
9. [Picker: Cache Downcased Labels and Use ETS for Large Lists](#9-picker-cache-downcased-labels-and-use-ets-for-large-lists)
10. [Keymap Trie: Compile to a Persistent Map for JIT-Friendly Lookups](#10-keymap-trie-compile-to-a-persistent-map-for-jit-friendly-lookups)
11. [Port Protocol: Leverage Sub-Binary References](#11-port-protocol-leverage-sub-binary-references)
12. [GC Pressure: Reduce Short-Lived Allocations in the Render Loop](#12-gc-pressure-reduce-short-lived-allocations-in-the-render-loop)
13. [Process Architecture: Consider ETS for Shared Read-Only State](#13-process-architecture-consider-ets-for-shared-read-only-state)
14. [JIT-Specific: Help the BEAM JIT Generate Better Native Code](#14-jit-specific-help-the-beam-jit-generate-better-native-code)
15. [Benchmarking Strategy](#15-benchmarking-strategy)

---

## 1. Gap Buffer: Eliminate Repeated Full-Text Materialization

### Problem

Nearly every query function in `Document` calls `content/1` which does `before <> after_`, an O(n) binary concatenation that allocates a fresh copy of the entire buffer content. Functions like `line_at/2`, `lines/3`, and `content_range/3` then immediately `String.split/2` that copy into a list of lines.

For a 10,000-line file, every single cursor motion triggers:
1. `content/1` → allocate ~500 KB binary
2. `String.split("\n")` → allocate a list of 10,000 binaries
3. `String.graphemes()` → allocate a list of ~300,000 graphemes

This is the single largest performance bottleneck.

### Fix

**Cache line metadata on the struct.** Maintain a list (or tuple) of `{byte_offset, grapheme_count}` per line, updated incrementally on insert/delete. Then `line_at/2` can extract a sub-binary directly from `before` or `after_` without materializing the full content:

```elixir
defstruct [:before, :after, :cursor_line, :cursor_col, :line_count,
           :line_index]  # [{byte_offset, byte_length}]
```

For line extraction, use `binary_part/3` on the appropriate half:

```elixir
@spec line_at(t(), non_neg_integer()) :: String.t() | nil
def line_at(%__MODULE__{} = buf, line_num) do
  case lookup_line(buf.line_index, line_num) do
    nil -> nil
    {offset, length} -> extract_line(buf.before, buf.after, offset, length)
  end
end
```

This turns `line_at/2` from O(n) to O(1) and eliminates the temporary allocation entirely. The JIT can optimize `binary_part/3` calls into direct pointer arithmetic on the heap binary.

### Impact

**Critical.** Every keystroke in the editor calls `line_at` or `lines` at least once (for rendering) and often 3–4 times (motion + render). With a 10K-line file, this alone would cut per-keystroke allocations by ~90%.

---

## 2. Gap Buffer: Replace Grapheme Lists with Binary Walking

### Problem

Functions like `pop_last_grapheme/1` and motion helpers still convert binaries into grapheme data structures. While motions now use tuples (O(1) indexing), the initial `String.graphemes/1` call is still O(n) in both time and memory.

### Fix

Use `String.next_grapheme/1` or `String.next_grapheme_size/1` to walk the binary in-place without materializing the full list. The BEAM JIT generates excellent native code for binary matching. It can process UTF-8 bytes with near-C performance using the `bs_match` JIT primitive.

For random access by grapheme index, the current tuple approach is good. The next step is eliminating the need for full-buffer grapheme conversion in motions by working on individual lines (enabled by the line index cache from optimization #1).

### Impact

**High.** Eliminates the remaining O(n) allocation in every motion call. Most impactful after the line index cache is implemented.

---

## 3. Gap Buffer: Use IOdata Instead of Binary Concatenation

### Problem

`insert_char/2` does `before <> char` which copies the entire `before` binary to append a single character. For rapid typing (e.g., pasting text), this is O(n²) in the size of `before`.

### Fix

Store `before` as an iolist instead of a flat binary. Appending becomes O(1): `[before | char]`. Flatten to binary only when needed (content extraction, file save). The Port protocol's `IO.iodata_to_binary/1` already handles iolists natively.

```elixir
# Insert becomes O(1)
def insert_char(%__MODULE__{before: before} = buf, char) do
  %{buf | before: [before | char], ...}
end

# Content materialization (only when needed)
def content(%__MODULE__{before: before, after: after_}) do
  IO.iodata_to_binary([before | after_])
end
```

**Caveat:** This changes the internal representation. `binary_part/3`, `byte_size/1`, and pattern matching on `before` would need adjustment. Consider this a Phase 2 optimization after the line index cache.

### Impact

**Medium-High.** Primarily affects insert-heavy workloads (typing, pasting). Transforms O(n) per character to O(1).

---

## 4. Motion Module: Avoid Temporary Document + Content Copies

### Problem

Every motion function receives a `Document.t()` and calls `Document.content/1` (binary concat), then `String.graphemes/1` (tuple allocation), then `String.split/2` (another list). The Editor's `apply_motion/2` creates a temporary `Document.new(content)`, so the content is still materialized and copied into a throwaway struct.

While `content_and_cursor/1` reduced GenServer round-trips from 3 to 2, the temporary Document allocation and content copy remain.

### Fix

**Move motion execution into the Buffer.Server process** via an `apply_motion/2` GenServer call. The motion function runs inside the server where the gap buffer already lives (zero copies):

```elixir
# In Buffer.Server
def handle_call({:apply_motion, motion_fn}, _from, state) do
  new_pos = motion_fn.(state.document, Document.cursor(state.document))
  new_buf = Document.move_to(state.document, new_pos)
  {:reply, :ok, %{state | document: new_buf}}
end
```

This eliminates the content copy, the temporary Document, and reduces the remaining 2 GenServer calls to 1.

### Impact

**High.** Eliminates all temporary allocations per motion. For a 50,000-line file, that's ~3 MB saved per keystroke.

---

## 5. Editor: Batch Remaining Buffer.Server Mutations into Single Calls

### Problem

Several editor commands still issue multiple sequential GenServer calls to `BufferServer`. The `change_line` command was fixed (now uses `clear_line/1`), but others remain:

- **`join_lines`**: 4+ GenServer calls (cursor, get_lines, move_to, delete_at, N × delete_at for whitespace, insert_char)
- **`indent_line`**: 3 calls (cursor, move_to, insert_char, move_to)
- **`dedent_line`**: 3+ calls
- **`toggle_case`**: 4 calls (cursor, get_lines, delete_at, insert_char)

### Fix

Add compound operations to `BufferServer` / `Document`:

```elixir
# In Buffer.Server
def handle_call({:join_lines, line}, _from, state) do
  {new_buf, _} = Document.join_lines(state.document, line)
  {:reply, :ok, push_undo(state, new_buf) |> mark_dirty()}
end
```

Similarly for `toggle_case_at`, `indent_line`, `dedent_line`.

### Impact

**Medium-High.** Eliminates O(n) GenServer overhead for multi-step operations. Each GenServer call involves message copying, scheduling, and reply matching.

---

## 6. Editor: Pre-build Render Binaries with IOlists

### Problem

`do_render/1` builds render commands by concatenating strings with `<>` for padding (`String.pad_trailing`, `String.duplicate`) and joining. Each `Protocol.encode_draw/4` call allocates a fresh binary.

The full render pipeline allocates hundreds of small binaries per frame that are immediately sent to the Port and become garbage.

### Fix

Use iolists throughout the render pipeline. The Port's `Port.command/2` accepts iolists natively, so there's no need to flatten to binary.

More impactful: in `PortManager.handle_cast({:send_commands, ...})`, skip the intermediate `IO.iodata_to_binary(commands)` flattening since `Port.command/2` accepts iolists directly.

**Note:** Validate `{:packet, 4}` framing compatibility with iolists.

### Impact

**Medium.** Saves one full-buffer-sized allocation per render frame. At 60 fps with a full-screen terminal, that's ~60 allocations/second of 10–50 KB each.

---

## 7. Undo/Redo: Structural Sharing via Zipper or Diff-Based Stack

### Problem

Every mutation pushes a **complete copy** of the `Document.t()` struct onto the undo stack. The struct contains `before` and `after_` binaries which together hold the full file content. For a 1 MB file, each keystroke adds ~1 MB to the undo stack. With `@max_undo_stack` of 1000, that's potentially ~1 GB of undo history.

The BEAM's garbage collector runs per-process, so this all lives in the `Buffer.Server` process heap and causes increasingly expensive GC pauses.

### Fix

Store diffs instead of full snapshots:

```elixir
@type undo_entry :: {
  cursor_before :: position(),
  operations :: [{:insert, position(), String.t()} | {:delete, position(), String.t()}]
}
```

Each undo entry is typically a few bytes (the inserted/deleted text + cursor position). Undo replays the inverse operations; redo replays forward.

### Impact

**High for large files.** Reduces undo stack memory from O(n × stack_size) to O(delta × stack_size). For a 1 MB file with 1000 undo entries, this could reduce memory from ~1 GB to ~1 MB.

---

## 8. TextObject: Avoid Flattening Entire Buffer for Paren Matching

### Problem

`find_delimited_pair/4` calls `flatten_with_positions/1`, which creates a list of `{grapheme, {line, col}}` tuples for the *entire* buffer. For a 10,000-line file with 50 chars/line, that's 500,000 tuples (~40 MB of list cells + tuple headers).

Then it does linear scans with `Enum.at/2` on this flat list.

### Fix

Scan backward/forward from the cursor position using binary walking on the raw content, tracking line/col as you go. This requires no allocation beyond the final result positions.

Alternatively, use the gap buffer's `before` and `after_` directly: scan backward through `before` for the opening delimiter, forward through `after_` for the closing one.

### Impact

**High for large files.** Eliminates a 40 MB allocation for paren matching on a 500K-character file.

---

## 9. Picker: Cache Downcased Labels and Use ETS for Large Lists

### Problem

`refilter/1` runs on every keystroke in the picker. For each item, it calls `String.downcase/1` on the label and description. With 10,000 files in a project, that's 20,000 `String.downcase/1` calls per keystroke.

The `length/1` function is also called repeatedly on the same lists. `length/1` is O(n) on linked lists.

### Fix

1. **Pre-compute downcased labels** at picker construction time.
2. **Cache the filtered count** as a field instead of calling `length/1`.
3. For very large candidate sets (>5000 items), consider ETS with match specs or a sorted index for prefix matching.

### Impact

**Medium.** Eliminates 20K+ `String.downcase/1` allocations per keystroke in the picker.

---

## 10. Keymap Trie: Compile to a Persistent Map for JIT-Friendly Lookups

### Problem

The keymap trie is already efficient. `Map.fetch/2` on small maps is fast. However, the trie is rebuilt from `Defaults` every time the editor starts. For the leader trie, `Defaults.leader_trie()` is called on every SPC keypress.

### Fix

1. **Module-attribute compile-time construction**: Build the trie at compile time using module attributes so it lives in the literal pool.

2. **Use `:persistent_term`** for runtime-registered keybindings.

### Impact

**Low.** Polish optimization.

---

## 11. Port Protocol: Leverage Sub-Binary References

### Problem

For render commands going *out*, ensure large text payloads in `encode_draw/4` use sub-binaries of the original line text rather than copies.

### Fix

Use `binary_part/3` to create sub-binary references (zero-copy) when the source is a reference-counted binary.

### Impact

**Low.** Micro-optimization for large text payloads in draw commands.

---

## 12. GC Pressure: Reduce Short-Lived Allocations in the Render Loop

### Problem

The render loop allocates many short-lived binaries per frame that become garbage after `Port.command/2` sends them.

### Fix

1. Pre-compute tilde row commands once and reuse them.
2. Cache modeline template; only rebuild changed segments.
3. Use `@compile {:inline, [...]}` for small render helpers.
4. Consider `:erlang.garbage_collect(self(), type: :minor)` after render.
5. Use `Process.flag(:min_heap_size, n)` on the Editor process.

### Impact

**Medium.** Smooths out latency spikes from GC pauses during rapid typing.

---

## 13. Process Architecture: ETS for Shared Read-Only State

### Status: Partially Complete

The three highest-contention GenServer stores have been migrated to ETS with `read_concurrency: true`:

- ✅ **Config.Options** (#156): every render frame and keystroke read options via Agent.get. Now direct ETS lookup. ~4x faster per read.
- ✅ **Diagnostics** (#155): gutter signs and minibuffer hints read on every frame, serialized behind LSP publish writes. Reads now bypass the GenServer entirely; writes still go through GenServer for subscriber notifications.
- ✅ **Keymap.Active** (#157): binding lookups on every keystroke went through Agent.get. Now direct ETS lookup.

### Remaining

The Editor process still creates a temporary `Document.new(content)` for motions, copying the full content across processes. Best approach: move motions into the Buffer.Server process (see #4).

### Impact

**Medium-High.** The ETS migrations eliminate all GenServer.call round-trips from the per-keystroke and per-frame hot paths (#159). The remaining buffer content copy is addressed by #4.

---

## 14. JIT-Specific: Help the BEAM JIT Generate Better Native Code

Several patterns remain that can help the JIT:

### a. Avoid `Enum` for Small, Known-Size Collections

`Enum` functions add overhead from protocol dispatch and anonymous function calls. For small collections, use direct recursion or comprehensions:

```elixir
# Faster for small lists: list comprehension (JIT-optimized)
for {text, fg, bg, opts} <- segments, do: ...
```

### b. Mark Hot Functions for Inlining

Additional hot functions in the render path and buffer operations could benefit from `@compile {:inline, ...}`.

### Impact

**Low-Medium.** Individual micro-optimizations that compound in hot loops.

---

## 15. Benchmarking Strategy

### Telemetry

The keystroke-to-render critical path is instrumented with `:telemetry` spans. Set `:log_level_render` to `:debug` to see per-stage timing in `*Messages*`. See [CONTRIBUTING.md](../CONTRIBUTING.md#performance-debugging-with-telemetry) for the full event list, example output, and how to attach custom handlers for histograms or percentile tracking.

### Tools

- **`Benchee`** micro-benchmarks for individual functions
- **`:timer.tc/1`** quick timing in IEx
- **`:erlang.statistics(:reductions)`** BEAM work units (proxy for CPU)
- **`:erlang.process_info(pid, :memory)`** per-process heap size
- **`:erlang.process_info(pid, :garbage_collection)`** GC stats
- **`recon`** production-ready process inspection
- **`eflame`** / **`eflambe`** flame graphs for BEAM processes

### What to Measure

1. **Per-keystroke latency**: Time from `handle_info({:minga_input, ...})` to `Port.command/2` completion. Target: < 1 ms for normal mode, < 5 ms for complex operations.

2. **Memory per buffer**: `:erlang.process_info(buf_pid, :memory)` with files of 1K, 10K, 100K lines. Track growth over 1000 edits.

3. **GC pause frequency**: Monitor `{:garbage_collection, info}` trace events on the Editor process during sustained typing.

4. **Allocation rate**: Use `:erlang.system_info(:alloc_util_allocators)` before/after a burst of operations.

### Existing Performance Test

The project already has `test/perf/document_perf_test.exs`. Extend this with benchmarks for:
- Motion on 10K-line buffer (word_forward, paragraph, bracket match)
- Render cycle with full viewport
- Picker filtering with 5000 candidates
- 1000 sequential inserts (typing simulation)

### Priority Order

Implement optimizations in this order for maximum impact:

1. **#1** Line index cache (eliminates the #1 allocation source)
2. **#4** Move motions into Buffer.Server (eliminates cross-process copies)
3. **#5** Batch remaining mutations (eliminates O(n) GenServer calls)
4. **#7** Diff-based undo (memory)
5. **#2** Binary walking (allocation reduction)
6. **#8** TextObject scanning (large file paren matching)
7. **#14** JIT-specific patterns (polish)
8. Everything else
