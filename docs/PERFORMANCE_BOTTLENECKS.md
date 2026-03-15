# Performance Bottleneck Analysis

**Date:** 2026-03-15
**Focus:** End-user latency and AI agent edit throughput
**Related:** [Telemetry ticket #527](https://github.com/jsmestad/minga/issues/527), [PERFORMANCE.md](PERFORMANCE.md), [BUFFER-AWARE-AGENTS.md](BUFFER-AWARE-AGENTS.md)

## Summary

The editor's core architecture is sound for performance: dirty-line tracking, incremental tree-sitter sync via EditDelta, render debounce at 16ms, BEAM VM tuning, and ETS for read-heavy shared state all work well. The bottlenecks below are specific, fixable problems rather than architectural flaws.

The single most impactful fix is routing agent edits through the buffer instead of the filesystem. The second most impactful is adding telemetry so every subsequent optimization is data-driven.

## Priority-Ordered Bottlenecks

### P1: Agent File Edits Bypass Buffers

**Impact:** HIGH for AI agent workloads. Zero impact on human editing.
**Effort:** Medium. Pattern documented in BUFFER-AWARE-AGENTS.md.

Agent tools (`EditFile`, `MultiEditFile`, `WriteFile`) all go through the filesystem:

```
Agent edit → File.read → String.replace → File.write → FileWatcher → buffer reload → tree-sitter full reparse
```

For 20 edits to one file, this means:
- ~140 syscalls (7 per read/write cycle × 20)
- 20 FileWatcher notifications
- 20 potential tree-sitter full reparses
- 0 undo entries (changes aren't tracked)
- Race condition with user's active editing

`MultiEditFile` batches edits in memory (one read, one write), but still pays the FileWatcher and reparse costs.

The buffer already has `Buffer.Server.apply_text_edits/2` which would give:
- 0 syscalls
- 0 FileWatcher events
- 1 incremental tree-sitter reparse (via EditDelta)
- 1 undo entry (the entire batch)
- No race condition (serialized through the buffer's GenServer mailbox)

**Fix:** Add a `BufferRouter` module that resolves file path to buffer pid (if open) and routes through `apply_text_edits/2`. Fall back to filesystem I/O when no buffer exists. The string-match-to-position conversion can use `:binary.matches` to find offsets, then `Document.offset_to_position` (already exists) to convert.

**Why first:** Every agent feature built on filesystem I/O inherits this performance tax. The longer this waits, the more code depends on the slow path.

### P2: Telemetry Infrastructure (#527)

**Impact:** META. Enables data-driven decisions for every subsequent optimization.
**Effort:** Low-medium. `:telemetry` is a mature zero-dep library.

Currently: ad-hoc `Minga.Log.debug(:render, "[render:content] 24µs")` strings in the render pipeline. Not aggregatable, not structured, no histograms. Without telemetry, performance regressions are invisible until a user reports "it feels slow."

**What to instrument (from ticket #527):**

| Span | What it measures | Why it matters |
|------|------------------|----------------|
| `[:minga, :input, :dispatch]` | Key event → command resolution | Input latency floor |
| `[:minga, :command, :execute]` | Command execution duration | Per-command cost |
| `[:minga, :render, :pipeline]` | Full render with per-stage children | Frame budget tracking |
| `[:minga, :render, :stage]` | Individual stage (invalidation, layout, scroll, content, chrome, compose, emit) | Identify slow stages |
| `[:minga, :port, :emit]` | Encoding + writing to Port | Serialization overhead |
| `[:minga, :buffer, :operation]` | GenServer call duration per operation type | Buffer contention |
| `[:minga, :agent, :tool]` | Agent tool execution | Agent throughput |

**Development reporter:** A `Minga.Telemetry.Reporter` GenServer that aggregates spans into histograms and writes to `*Messages*` on demand (e.g., via a `:telemetry_report` command or `SPC h t`).

**Why second:** Priorities 3-7 are all "probably matters, but by how much?" questions. Telemetry turns guesses into measurements. Without it, you might spend a week optimizing the motion snapshot problem only to discover it's 200µs per keystroke (fine) while the real culprit is something you haven't measured.

### P3: Motion Execution Copies Full Document Across Process Boundary

**Impact:** HIGH for human editing on large files. Proportional to file size.
**Effort:** Quick win (low), structural fix (medium-high).

`Helpers.apply_motion` does:
1. `BufferServer.snapshot(buf)` copies the full `Document.t()` to the Editor process
2. Runs the motion function on it
3. `BufferServer.move_to(buf, new_pos)` sends the result back

For a 50K-line file (~3MB), every motion copies 3MB across the process boundary. But the severity varies by motion type:

| Motion | Snapshot needed? | Content materialized? | Cost |
|--------|------------------|-----------------------|------|
| `j`, `k` (up/down) | No (uses `BufferServer.move` directly) | No | Low |
| `h`, `l` (left/right) | Yes (checks boundary) | No | Medium |
| `0`, `$`, `^` (line) | Yes (snapshot) | No, uses `line_at` | Medium |
| `w`, `b`, `e` (word) | Yes (snapshot) | Yes (`content()` = O(n) concat) | **High** |
| `gg`, `G` (document) | Yes | No | Medium |

Word motions are the worst: they call `Readable.content(buf)` which concatenates `before <> after_` into a new binary, then search through it.

**Quick win:** For `h` and `l`, replace `snapshot` + boundary check + `move` with a single GenServer call `move_if_possible(buf, :left)` that does the check inside the buffer process. Eliminates the snapshot for the most common keystrokes.

**Structural fix:** Rewrite word motions to use `line_at` iteratively instead of materializing full content. Word motions search forward/backward from the cursor and rarely need more than 2-3 lines of context. This eliminates the O(n) content materialization entirely.

### P4: Undo Stack Stores Full Document Snapshots

**Impact:** MEDIUM. Bounded by coalescing (300ms) and stack cap (1000 entries).
**Effort:** High. Fundamental change to undo architecture.

`BufState.push_undo` stores `{version, document}` where `document` contains the full file as `before` + `after` binaries. Worst case for a 1MB file with 1000 undo entries: ~1GB in the buffer process heap.

In practice, the 300ms coalescing window limits human typing to 2-3 entries/second. Agent edits via `apply_text_edits/2` push one entry per batch, which is manageable. The real problem is the current agent path: filesystem writes trigger buffer reloads, and each reload may push a snapshot.

**Fix (when telemetry proves it matters):** Delta-based undo. Store the inverse operation (what was deleted/inserted + cursor positions) rather than the full document. This is how every production editor does it. Each entry shrinks from ~file_size to ~edit_size.

**Why deferred:** The coalescing window and stack cap bound the worst case. For typical files (10-50KB), the peak is 10-50MB, which is fine. Fix agent buffer routing (P1) first, which eliminates the reload-pushes-snapshot problem.

### P5: Scroll Stage GenServer Call Volume

**Impact:** MEDIUM. Already partially optimized via `render_snapshot`.
**Effort:** Low-medium.

The scroll stage makes 4-7 `BufferServer` calls per window per frame:
- `line_count` (1 call)
- `cursor` (1 call, active window only)
- `decorations` (1 call)
- `render_snapshot` (1 call, already batches 5 old calls)
- `get_option` × 2 (line_numbers, wrap)
- Conditionally: `file_path` for git signs

At 60fps, that's ~300-420 GenServer round-trips/second per window. Each GenServer call in the BEAM is 1-5µs, so the total overhead is maybe 1-2ms/second. **Measure with telemetry before optimizing.**

**Fix (if telemetry shows it matters):** A single `scroll_snapshot` call that returns everything the scroll stage needs: line count, cursor, decorations, render snapshot, options, file path. One round-trip instead of 4-7.

### P6: Line Index Cache Invalidation on Mutation

**Impact:** LOW-MEDIUM. Already well-designed.
**Effort:** Medium (incremental update is tricky for multi-line edits).

`Document.line_offsets` is lazily computed and invalidated (set to `nil`) on content mutations. The rebuild cost is `content()` (O(n) concatenation) + `:binary.matches` (single-pass C-level scan, fast). For a 50K-line file: ~1-2ms.

The invalidation is narrower than it appears: only `move_to` and content mutations set `line_offsets: nil`. Regular `move(:left/:right/:up/:down)` preserves the cache.

If agent edits route through `apply_text_edits/2` (P1 fix), they're batched, so you get one invalidation per batch, not per edit.

**Fix (when telemetry proves it matters):** Incremental offset update. Given an EditDelta, adjust offsets above the edit point rather than rebuilding from scratch.

### P7: Render Pipeline Runs in the Editor GenServer

**Impact:** LOW today. Could become medium as UI complexity grows.
**Effort:** High (major architectural change, not recommended now).

Every render frame blocks the Editor from processing input. If a render takes 5ms (plausible for complex syntax highlighting + chrome), that's 5ms of input latency on top of the 16ms debounce. At current complexity, this is fine. It would become a problem if future features add expensive render stages (LSP diagnostics overlay, inline diffs, rich agent UI).

**Not recommended now.** Moving rendering to a separate process requires snapshotting all render state atomically, which is a significant change. Monitor via telemetry first.

## Bottlenecks Identified by Archie

### `Document.move_to/2` is O(n) for Long-Distance Jumps

The gap buffer moves the cursor by shifting bytes between `before` and `after`. A jump from line 0 to line 50,000 rebuilds the entire gap. This matters for `gg`/`G` and for agent edits that jump around the file. This is inherent to gap buffers and not fixable without changing the data structure.

### Agent Tool String Matching is O(n×m)

`EditFile` uses `String.split(content, old_text)` to count occurrences, then `String.replace` to apply. For large files with long search strings, that's two full scans. If routed through the buffer (P1 fix), the tool layer needs to convert string matches to positions first, then hand off positions to `apply_text_edits/2`.

## What Already Works Well

These don't need optimization:

| System | Why it's fine |
|--------|---------------|
| Dirty-line tracking | Single-char edits re-render one line, not the whole viewport |
| Line index cache (when valid) | O(1) `line_at` via `binary_part` on cached offsets |
| Incremental tree-sitter sync | EditDelta sends compact diffs to the parser, not full content |
| Render debounce (16ms) | Coalesces rapid edits into single frames |
| BEAM VM flags | Scheduler wake, GC tuning, allocator config all well-configured |
| ETS for read-heavy state | Config.Options, Diagnostics, Keymap.Active bypass GenServer |
| `render_snapshot` batching | 5 old calls consolidated into 1 |
| Undo coalescing | 300ms window prevents stack explosion during human typing |

## Recommended Execution Order

```
1. Agent buffer routing (P1)     ← biggest win for AI workloads
2. Telemetry (#527) (P2)         ← enables data-driven decisions
3. Motion quick win: h/l (P3a)   ← low effort, measurable with telemetry
4. [measure with telemetry]      ← verify P3-P7 actually matter
5. Word motion refactor (P3b)    ← if telemetry confirms O(n) cost
6. Scroll snapshot (P5)          ← if telemetry shows GenServer overhead
7. Delta undo (P4)               ← if memory profiling shows pressure
8. Line index incremental (P6)   ← if telemetry shows rebuild cost
```

Steps 4-8 are conditional. Telemetry may reveal that some of these are already fast enough, or that a bottleneck we haven't identified is the real problem.
