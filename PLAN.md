# Plan: Keystroke Latency Optimization

## Goal

Reduce keystroke-to-screen latency from O(n) in buffer size to O(1) for
typical editing operations, and cut per-keystroke overhead from 6+ GenServer
round-trips and 50+ Port syscalls to 1 of each. This brings Minga's
interactive responsiveness from "fine under 100KB, sluggish over 1MB" to
"smooth at any file size."

## Context

### Current Hot Path (per keystroke)

A single keypress currently follows this pipeline:

1. **Zig** detects keypress → encodes → writes to Port stdout (~µs)
2. **PortManager** decodes → sends `{:minga_input, ...}` to Editor (~µs)
3. **Editor** `handle_key` → Mode FSM → `execute_command`:
   - Typical command (e.g. `:move_right`): 1 `BufferServer.call` (sync)
   - Some commands (e.g. `:insert_line_below`): 3-4 `BufferServer.call`s
4. **Editor** `do_render` — 5 more `BufferServer.call`s:
   - `cursor/1`, `get_lines/3`, `file_path/1`, `dirty?/1`, `line_count/1`
5. **Editor** encodes ~50+ render commands → `PortManager.send_commands`
6. **PortManager** sends each command as a separate `Port.command` (1 syscall each)
7. **Zig** decodes each → draws to libvaxis → `batch_end` flushes to terminal

**Bottleneck #1 — O(n) buffer queries**: `cursor()` does
`String.split(before, "\n")` every call. `line_count()` concatenates
`before <> after_` then scans for newlines. `move_to()` rebuilds full content
and splits all lines. For a 1MB file, each query allocates and scans ~1MB.
With 6+ queries per keystroke, that's ~6MB of allocation per keypress.

**Bottleneck #2 — GenServer round-trips**: The render path alone makes 5
synchronous `GenServer.call` round-trips to `BufferServer`. Each round-trip
involves message send → scheduler pickup → execute → reply. Even at ~5-10µs
overhead per call, that's 25-50µs of pure scheduling overhead before any real
work.

**Bottleneck #3 — Port I/O**: `PortManager.send_commands` calls
`Port.command(state.port, cmd)` in a loop — one write syscall per render
command. A typical frame has 50-60 commands (clear + 50 lines + modeline +
minibuffer + cursor + shape + batch_end). That's 50-60 syscalls per keystroke.

### What We're NOT Changing

- The BEAM ↔ Zig Port architecture (it's architecturally sound)
- The gap buffer as the core data structure (it's correct for this use case)
- The GenServer-per-buffer isolation model
- The Mode FSM or command dispatch
- The Zig renderer or libvaxis integration

## Approach

Three independent, stackable optimizations ordered by impact:

1. **Cache derived state in GapBuffer** — eliminate O(n) queries
2. **Batch buffer queries for rendering** — 1 GenServer call instead of 5
3. **Batch Port commands into a single binary** — 1 syscall instead of 50+

Each step is independently valuable and testable. Together they reduce
keystroke latency from O(n) to O(1) and cut constant-factor overhead by ~10x.

### Alternatives Considered

1. **Replace gap buffer with rope/piece table** — Solves O(n) queries
   structurally but is a massive rewrite touching every buffer consumer. The
   caching approach gets us O(1) queries with surgical changes to one module.
   A rope can be considered later if needed for very large files (100MB+).

2. **Move buffer into Editor GenServer (eliminate BufferServer)** — Removes
   GenServer overhead entirely but sacrifices crash isolation. A single bad
   buffer operation would take down the editor. The batch-query approach gets
   most of the benefit while keeping isolation.

3. **ETS-based buffer storage** — Allows concurrent reads without GenServer
   serialization. But gap buffers aren't naturally decomposable into
   key-value pairs, and the complexity isn't justified when batch queries
   solve the problem.

4. **NIF-based gap buffer** — Move the gap buffer to C/Zig for raw speed.
   Maximum performance but sacrifices BEAM safety guarantees (NIF crash =
   VM crash). The caching approach gets 95% of the benefit without this risk.

## Steps

### 1. Cache cursor position and line count in GapBuffer

- **Files**: `lib/minga/buffer/gap_buffer.ex`, `test/minga/buffer/gap_buffer_test.exs`
- **Changes**:
  - Add `cursor_line`, `cursor_col`, and `line_count` fields to the
    `%GapBuffer{}` struct (with `@enforce_keys` updated)
  - `new/1`: compute initial values during construction (scan once)
  - `cursor/1`: return `{buf.cursor_line, buf.cursor_col}` — O(1)
  - `line_count/1`: return `buf.line_count` — O(1)
  - **Update cached fields incrementally in every mutation**:
    - `insert_char/2`: if inserting `"\n"`, increment `line_count` and
      `cursor_line`, set `cursor_col` to 0. Otherwise increment `cursor_col`.
      For multi-char inserts, count newlines in the inserted text and compute
      the new column from the last newline position.
    - `delete_before/1`: if the deleted grapheme is `"\n"`, decrement
      `line_count` and `cursor_line`, set `cursor_col` to the length of the
      line that now precedes the cursor (scan backward in `before` to the
      previous `"\n"` or start). Otherwise decrement `cursor_col`.
    - `delete_at/1`: if the deleted grapheme is `"\n"`, decrement
      `line_count`. Cursor position doesn't change.
    - `move_left/1`: if the character moved is `"\n"`, decrement
      `cursor_line` and set `cursor_col` to the length of the line now
      before the cursor. Otherwise decrement `cursor_col`.
    - `move_right/1`: if the character moved is `"\n"`, increment
      `cursor_line` and set `cursor_col` to 0. Otherwise increment
      `cursor_col`.
    - `move_up/1`, `move_down/1`: these call `move_to/2`, handled below.
    - `move_to/2`: already computes the target line/col during clamping —
      store them in the struct instead of recomputing in `cursor/1`.
    - `delete_range/2`, `delete_lines/2`: these reconstruct the buffer via
      `new()` + `move_to()` — the cache is rebuilt by those functions.
  - Keep the existing `cursor/1` logic as a private `compute_cursor/1` for
    use in `@assert` debug checks (verify cache consistency in test builds)
  - All existing tests must continue to pass unchanged (the API doesn't
    change, only the implementation)
  - Add new tests:
    - Cache accuracy after insert at start/middle/end of line
    - Cache accuracy after inserting newlines
    - Cache accuracy after delete_before at line start (joining lines)
    - Cache accuracy after delete_at on a newline character
    - Cache accuracy after move_to to arbitrary positions
    - Cache accuracy after delete_range spanning multiple lines
    - Cache accuracy after delete_lines
    - Property test: for any sequence of operations, cached values match
      computed values

### 2. Add `render_snapshot` to BufferServer (batch query)

- **Files**: `lib/minga/buffer/server.ex`, `lib/minga/editor.ex`,
  `test/minga/editor_test.exs`
- **Changes**:
  - **BufferServer**: Add a new `render_snapshot/3` function that returns all
    data needed for a single render frame in one GenServer.call:
    ```elixir
    @type render_snapshot :: %{
      cursor: GapBuffer.position(),
      line_count: pos_integer(),
      lines: [String.t()],
      file_path: String.t() | nil,
      dirty: boolean()
    }

    @spec render_snapshot(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
            render_snapshot()
    def render_snapshot(server, first_line, count) do
      GenServer.call(server, {:render_snapshot, first_line, count})
    end
    ```
  - **BufferServer handle_call**: Single clause that reads all fields from
    state in one shot — no repeated `content()` / `String.split()` calls:
    ```elixir
    def handle_call({:render_snapshot, first_line, count}, _from, state) do
      buf = state.gap_buffer
      snapshot = %{
        cursor: GapBuffer.cursor(buf),
        line_count: GapBuffer.line_count(buf),
        lines: GapBuffer.lines(buf, first_line, count),
        file_path: state.file_path,
        dirty: state.dirty
      }
      {:reply, snapshot, state}
    end
    ```
  - **Editor `do_render/1`**: Replace the 5 individual BufferServer calls with
    a two-step approach:
    1. First call `BufferServer.cursor/1` to get the cursor (needed to compute
       viewport scrolling and determine `first_line`)
    2. Then call `BufferServer.render_snapshot/3` with the computed
       `first_line` and `visible_rows` to get everything else in one call
    - This reduces the render path from 5 GenServer calls to 2
    - With step 1's cached cursor, both calls are O(1) in buffer size
  - **Editor**: Also review `execute_command` clauses that make multiple
    BufferServer calls (e.g. `insert_line_below` makes 4 calls). Where
    possible, add compound operations to BufferServer to batch these. This
    is a follow-up optimization noted but not required for this step.
  - Update existing editor tests as needed (the render output should be
    identical; only the call pattern changes)

### 3. Batch Port commands into a single binary

- **Files**: `lib/minga/port/manager.ex`, `lib/minga/port/protocol.ex`,
  `zig/src/protocol.zig`, `zig/src/main.zig`,
  `test/minga/port/protocol_test.exs`
- **Changes**:
  - **Protocol (Elixir)**: Add `encode_batch/1` that concatenates a list of
    encoded command binaries into a single binary, with each command prefixed
    by its own 2-byte length:
    ```elixir
    @spec encode_batch([binary()]) :: binary()
    def encode_batch(commands) when is_list(commands) do
      IO.iodata_to_binary(commands)
    end
    ```
    Actually, the simpler approach: since each command already starts with an
    opcode byte, and the Zig side knows the exact byte layout of each opcode,
    we can concatenate commands directly and decode them sequentially. The
    existing `{:packet, 4}` framing gives us the total message length, so
    the Zig side just walks through the payload decoding commands one at a
    time until the buffer is exhausted.
  - **PortManager `send_commands/2`**: Instead of calling `Port.command/2` in
    a loop, concatenate all commands into a single binary and send once:
    ```elixir
    def handle_cast({:send_commands, commands}, state) do
      batch = IO.iodata_to_binary(commands)
      Port.command(state.port, batch)
      {:noreply, state}
    end
    ```
    This sends one `{:packet, 4}` message containing all commands.
  - **Protocol (Zig)**: Add a `decodeBatch` function or modify the stdin
    handler in `main.zig` to process a payload containing multiple
    concatenated commands. After reading the 4-byte length prefix and the
    full payload, iterate through the payload calling `decodeCommand` on
    successive slices until exhausted:
    ```zig
    // In runEventLoop, replace single-command decode with batch decode:
    var offset: usize = 0;
    while (offset < msg_len) {
        const remaining = payload[offset..];
        const cmd = protocol.decodeCommand(remaining) catch |err| {
            std.log.warn("protocol decode error at offset {}: {}", .{offset, err});
            break;
        };
        rend.handleCommand(cmd) catch |err| {
            std.log.warn("renderer error: {}", .{err});
        };
        offset += protocol.commandSize(remaining);
    }
    ```
  - **Protocol (Zig)**: Add `commandSize(payload: []const u8) usize` that
    returns the byte size of the first command in a payload, based on the
    opcode:
    - `0x12` (clear): 1 byte
    - `0x13` (batch_end): 1 byte
    - `0x11` (set_cursor): 5 bytes
    - `0x15` (set_cursor_shape): 2 bytes
    - `0x10` (draw_text): 12 + text_len (read text_len from bytes 10-11)
  - Tests:
    - Elixir: `encode_batch/1` concatenates correctly
    - Zig: batch payload with multiple commands decodes to correct sequence
    - Zig: `commandSize` returns correct sizes for all opcodes
    - Zig: batch with draw_text (variable length) in the middle works
    - Integration: existing editor tests still pass (output unchanged)

## Testing

- `mix test --warnings-as-errors` — all existing + new tests pass after each
  step
- `zig build test` — all existing + new Zig protocol tests pass (step 3)
- **Step 1 verification**: Add a debug assertion in GapBuffer tests that
  compares cached cursor/line_count against recomputed values after every
  operation in property tests. This catches cache drift.
- **Step 2 verification**: Existing editor render tests produce identical
  output. New test verifies `render_snapshot` returns same data as individual
  calls.
- **Step 3 verification**: Existing render/protocol tests pass. New test sends
  a batched message through a mock port and verifies identical Zig-side
  command sequence.

### Performance Validation

After all three steps, we can validate with a simple benchmark:

```elixir
# In iex or a test
{:ok, buf} = BufferServer.start_link(content: String.duplicate("hello world\n", 100_000))
# 100K lines = ~1.2MB

# Before: each of these is O(n)
:timer.tc(fn -> BufferServer.cursor(buf) end)        # expect ~ms
:timer.tc(fn -> BufferServer.line_count(buf) end)     # expect ~ms

# After step 1: each is O(1)
:timer.tc(fn -> BufferServer.cursor(buf) end)         # expect ~µs
:timer.tc(fn -> BufferServer.line_count(buf) end)     # expect ~µs
```

## Risks & Open Questions

1. **Cache correctness is critical** — A wrong cached cursor position would
   cause silent editing corruption. Mitigation: property-based tests that
   verify cache against recomputed values for random operation sequences.
   Consider a debug-only `assert_cache_valid/1` guard in dev/test builds.

2. **Multi-grapheme insert cache update** — `insert_char/2` accepts arbitrary
   strings (e.g. paste), not just single characters. The cache update must
   handle multi-line inserts correctly by counting newlines in the inserted
   text and computing the column from the last newline's position. This is
   the trickiest part of step 1.

3. **Unicode column counting** — `cursor_col` currently tracks grapheme
   count, not byte offset. The cached value must match the grapheme-based
   counting used by `move_to` and `lines`. Since we're caching what
   `cursor/1` already returns, the semantics don't change.

4. **Batch protocol backward compatibility** — The Zig side currently expects
   one command per `{:packet, 4}` message. Step 3 changes this to multiple
   commands per message. Both sides must be updated atomically (same commit).
   If only one side is updated, the renderer will break.

5. **`lines/3` is still O(n)** — Even with cached cursor and line_count,
   `get_lines` still calls `content()` + `String.split("\n")` +
   `Enum.slice`. This is O(n) in buffer size. A true fix requires a line
   index (array of byte offsets to line starts), which is a larger change.
   For now, this is acceptable because `get_lines` returns only the visible
   lines (~50) and the split happens once per frame. A line index is a
   potential step 4 but out of scope for this plan.

6. **Undo memory** — Not addressed in this plan. The full-snapshot undo
   system will still consume O(edits × buffer_size) memory. This is a
   separate concern worth its own plan (diff-based undo). Noted here for
   completeness.

---

## GitHub Ticket

```markdown
# Editor responds instantly to keystrokes regardless of file size

**Type:** Feature

## What
Editing files larger than ~100KB introduces noticeable input lag because every
keystroke triggers multiple O(n) string operations across the full buffer
content, 5+ synchronous GenServer round-trips for rendering data, and 50+
individual system calls to send render commands to the terminal renderer. These
costs scale linearly with file size, making files over 1MB feel sluggish and
files over 10MB essentially unusable for interactive editing.

## Why
Keystroke responsiveness is the most fundamental quality of a text editor. Users
perceive latency above ~50ms as lag and above ~100ms as broken. Files in the
100KB-10MB range (large modules, generated code, logs, data files) are common
editing targets. If Minga cannot handle them smoothly, users will not trust it
as a primary editor. Every competing editor (Neovim, Emacs, Zed, VSCode)
handles multi-megabyte files with sub-millisecond keystroke latency.

## Acceptance Criteria

- Typing, cursor movement, and scrolling in a 1MB file feel identical to a 1KB
  file — no perceptible delay
- `GapBuffer.cursor/1` and `GapBuffer.line_count/1` execute in constant time
  (O(1)) regardless of buffer size
- A single render frame requires at most 2 GenServer calls to the buffer
  server, down from 5+
- All render commands for a single frame are sent to the Zig renderer as a
  single Port message, not individual messages per command
- All existing editor tests continue to pass without modification to their
  assertions
- Opening and editing a 10MB file does not introduce visible keystroke lag

### Developer Notes
- Three independent optimizations stacked: (1) cache cursor/line_count in the
  gap buffer struct and update incrementally on mutations, (2) add a
  `render_snapshot` batch query to BufferServer, (3) concatenate Port commands
  into a single binary per frame
- The gap buffer struct gains `cursor_line`, `cursor_col`, `line_count` fields
  — updated in O(1) by tracking what character was inserted/deleted/moved
- `get_lines/3` remains O(n) — a line index optimization is a separate future
  improvement
- Undo memory (full-snapshot storage) is a separate concern, not addressed here
- The batch Port protocol change requires both Elixir and Zig sides to be
  updated in the same commit
```
