# Performance Optimizations for Minga

This document catalogues concrete performance improvements that leverage
BEAM VM internals, JIT compiler behaviour (OTP 25+), and Elixir/Erlang
idioms. Each section identifies the current bottleneck, explains *why* it's
slow on the BEAM, and proposes a fix.

---

## Table of Contents

1. [Gap Buffer: Eliminate Repeated Full-Text Materialization](#1-gap-buffer-eliminate-repeated-full-text-materialization)
2. [Gap Buffer: Replace Grapheme Lists with Binary Walking](#2-gap-buffer-replace-grapheme-lists-with-binary-walking)
3. [Gap Buffer: Use IOdata Instead of Binary Concatenation](#3-gap-buffer-use-iodata-instead-of-binary-concatenation)
4. [Motion Module: Avoid Temporary GapBuffer + Content Copies](#4-motion-module-avoid-temporary-gapbuffer--content-copies)
5. [Motion Module: Replace `Enum.at/2` on Lists with Tuple/Binary Indexing](#5-motion-module-replace-enumat2-on-lists-with-tuplebinary-indexing)
6. [Motion Module: Replace `cond` with Multi-Clause Functions](#6-motion-module-replace-cond-with-multi-clause-functions)
7. [Editor: Eliminate Temporary GapBuffer Allocations in Commands](#7-editor-eliminate-temporary-gapbuffer-allocations-in-commands)
8. [Editor: Batch Buffer.Server Mutations into Single Calls](#8-editor-batch-bufferserver-mutations-into-single-calls)
9. [Editor: Pre-build Render Binaries with IOlists](#9-editor-pre-build-render-binaries-with-iolists)
10. [Undo/Redo: Structural Sharing via Zipper or Diff-Based Stack](#10-undoredo-structural-sharing-via-zipper-or-diff-based-stack)
11. [TextObject: Avoid Flattening Entire Buffer for Paren Matching](#11-textobject-avoid-flattening-entire-buffer-for-paren-matching)
12. [Picker: Cache Downcased Labels and Use ETS for Large Lists](#12-picker-cache-downcased-labels-and-use-ets-for-large-lists)
13. [Keymap Trie: Compile to a Persistent Map for JIT-Friendly Lookups](#13-keymap-trie-compile-to-a-persistent-map-for-jit-friendly-lookups)
14. [Port Protocol: Leverage Sub-Binary References](#14-port-protocol-leverage-sub-binary-references)
15. [GC Pressure: Reduce Short-Lived Allocations in the Render Loop](#15-gc-pressure-reduce-short-lived-allocations-in-the-render-loop)
16. [Process Architecture: Consider ETS for Shared Read-Only State](#16-process-architecture-consider-ets-for-shared-read-only-state)
17. [JIT-Specific: Help the BEAM JIT Generate Better Native Code](#17-jit-specific-help-the-beam-jit-generate-better-native-code)
18. [Benchmarking Strategy](#18-benchmarking-strategy)

---

## 1. Gap Buffer: Eliminate Repeated Full-Text Materialization

### Problem

Nearly every query function in `GapBuffer` calls `content/1` which does
`before <> after_`, an O(n) binary concatenation that allocates a fresh
copy of the entire buffer content. Functions like `line_at/2`, `lines/3`,
and `content_range/3` then immediately `String.split/2` that copy into
a list of lines.

For a 10,000-line file, every single cursor motion triggers:
1. `content/1` → allocate ~500 KB binary
2. `String.split("\n")` → allocate a list of 10,000 binaries
3. `String.graphemes()` → allocate a list of ~300,000 graphemes

This is the single largest performance bottleneck.

### Fix

**Cache line metadata on the struct.** Maintain a list (or tuple) of
`{byte_offset, grapheme_count}` per line, updated incrementally on
insert/delete. Then `line_at/2` can extract a sub-binary directly from
`before` or `after_` without materializing the full content:

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

This turns `line_at/2` from O(n) to O(1) and eliminates the temporary
allocation entirely. The JIT can optimize `binary_part/3` calls into
direct pointer arithmetic on the heap binary.

### Impact

**Critical.** Every keystroke in the editor calls `line_at` or `lines`
at least once (for rendering) and often 3–4 times (motion + render).
With a 10K-line file, this alone would cut per-keystroke allocations by
~90%.

---

## 2. Gap Buffer: Replace Grapheme Lists with Binary Walking

### Problem

Functions like `count_newlines/1`, `pop_last_grapheme/1`, and all motion
helpers call `String.graphemes/1`, which converts the entire binary into
a linked list of single-grapheme strings. This is O(n) in both time and
memory, and the resulting list is accessed with `Enum.at/2` (also O(n)).

### Fix

Use `String.next_grapheme/1` or `String.next_grapheme_size/1` to walk
the binary in-place without materializing the full list. The BEAM JIT
generates excellent native code for binary matching. It can process
UTF-8 bytes with near-C performance using the `bs_match` JIT primitive.

For `count_newlines/1`, use `:binary.matches/2` instead:

```elixir
@spec count_newlines(String.t()) :: non_neg_integer()
defp count_newlines(str) do
  length(:binary.matches(str, "\n"))
end
```

`:binary.matches/2` uses Boyer-Moore search internally and runs in
compiled C, much faster than grapheme iteration.

For random access by grapheme index, convert to a tuple of graphemes
once and use `elem/2` (O(1)) instead of `Enum.at/2` (O(n)):

```elixir
graphemes = text |> String.graphemes() |> List.to_tuple()
char = elem(graphemes, index)  # O(1) vs Enum.at(list, index) O(n)
```

### Impact

**High.** Every word motion currently allocates a full grapheme list and
does multiple `Enum.at/2` calls. Converting to tuple + `elem/2` makes
random access O(1). Binary walking eliminates the list entirely for
sequential scans.

---

## 3. Gap Buffer: Use IOdata Instead of Binary Concatenation

### Problem

`insert_char/2` does `before <> char` which copies the entire `before`
binary to append a single character. For rapid typing (e.g., pasting
text), this is O(n²) in the size of `before`.

### Fix

Store `before` as an iolist instead of a flat binary. Appending becomes
O(1): `[before | char]`. Flatten to binary only when needed (content
extraction, file save). The Port protocol's `IO.iodata_to_binary/1`
already handles iolists natively.

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

The BEAM's `iolist_to_binary` is implemented in C and does a single
allocation + memcpy pass, which is significantly faster than repeated
`<>` concatenation.

**Caveat:** This changes the internal representation. `binary_part/3`,
`byte_size/1`, and pattern matching on `before` would need adjustment.
Consider this a Phase 2 optimization after the line index cache.

### Impact

**Medium-High.** Primarily affects insert-heavy workloads (typing,
pasting). Transforms O(n) per character to O(1).

---

## 4. Motion Module: Avoid Temporary GapBuffer + Content Copies

### Problem

Every motion function in `Minga.Motion` receives a `GapBuffer.t()` and
immediately calls `GapBuffer.content/1` (binary concat), then
`String.graphemes/1` (list allocation), then `String.split/2` (another
list). This happens inside `Editor.apply_motion/2` which *also* creates
a temporary `GapBuffer.new(content)` — so the content is materialized
twice.

The flow for a single `w` motion:
1. `Editor.apply_motion` → `BufferServer.content(buf)` (GenServer call)
2. `GapBuffer.new(content)` → copies the string, counts newlines
3. `Motion.word_forward(tmp_buf, cursor)` → `GapBuffer.content(tmp_buf)`
   → another copy, `String.graphemes()` → list, `String.split()` → list

That's 3 full copies of the buffer content for one cursor movement.

### Fix

Refactor motions to accept raw content (binary) and cursor position
directly, not a `GapBuffer.t()`. The `Editor` already has the content
from the GenServer call:

```elixir
# Before
defp apply_motion(buf, motion_fn) do
  content = BufferServer.content(buf)
  cursor = BufferServer.cursor(buf)
  tmp_buf = GapBuffer.new(content)        # unnecessary copy
  new_pos = motion_fn.(tmp_buf, cursor)   # content copied again inside
  BufferServer.move_to(buf, new_pos)
end

# After
defp apply_motion(buf, motion_fn) do
  content = BufferServer.content(buf)
  cursor = BufferServer.cursor(buf)
  new_pos = motion_fn.(content, cursor)   # work on the binary directly
  BufferServer.move_to(buf, new_pos)
end
```

Better still, add a `content_and_cursor/1` call to `BufferServer` that
returns both in a single GenServer round-trip.

### Impact

**High.** Eliminates 2 out of 3 full-buffer copies per motion. For a
50,000-line file, that's ~3 MB saved per keystroke.

---

## 5. Motion Module: Replace `Enum.at/2` on Lists with Tuple/Binary Indexing

### Problem

The motion module uses `Enum.at(graphemes, offset)` extensively inside
recursive loops (e.g., `skip_while/4`, `do_word_forward/3`,
`find_run_start/3`). `Enum.at/2` on a linked list is O(n), making these
loops O(n²) in the worst case.

The BEAM JIT cannot optimize linked-list traversal — it must follow
pointer chains through the heap, causing cache misses.

### Fix

Convert the grapheme list to a tuple once at the call site, then use
`elem(tuple, index)` which is O(1) — the BEAM stores tuples as
contiguous arrays and `elem/2` compiles to a single indexed load:

```elixir
def word_forward(%GapBuffer{} = buf, {line, col} = pos) do
  text = GapBuffer.content(buf)
  graphemes = text |> String.graphemes() |> List.to_tuple()
  total = tuple_size(graphemes)
  # ... use elem(graphemes, offset) instead of Enum.at(graphemes, offset)
end
```

The JIT generates a bounds-checked array load for `elem/2`, which is
substantially faster than list traversal and much more cache-friendly.

### Impact

**High.** Converts O(n²) motion calculations to O(n). Most noticeable
on large files where word motions currently lag.

---

## 6. Motion Module: Replace `cond` with Multi-Clause Functions

### Problem

Per the project's own coding standards (AGENTS.md), `cond` blocks should
be replaced with multi-clause functions. The motion module has several
`cond` blocks in `do_word_forward/3`, `do_word_end/3`, and the bracket
matching helpers.

Beyond style, this matters for JIT performance: multi-clause functions
with guards compile to efficient jump tables or sequential test chains
in native code. The JIT can specialize each clause independently and
inline small functions. `cond` blocks compile to nested `case` expressions
that the JIT handles less efficiently.

### Fix

Extract `cond` blocks into private multi-clause functions:

```elixir
# Before
defp do_word_forward(graphemes, offset, max) do
  current = elem(graphemes, offset)
  cond do
    whitespace?(current) -> ...
    word_char?(current) -> ...
    true -> ...
  end
end

# After
defp do_word_forward(graphemes, offset, max) do
  current = elem(graphemes, offset)
  advance_word(graphemes, offset, max, classify(current))
end

defp advance_word(graphemes, offset, max, :whitespace) do ...end
defp advance_word(graphemes, offset, max, :word) do ...end
defp advance_word(graphemes, offset, max, :punctuation) do ...end
```

### Impact

**Low-Medium.** Measurable improvement when the JIT can specialize
clause dispatch. Also makes the code more consistent with project
standards and easier to test.

---

## 7. Editor: Eliminate Temporary GapBuffer Allocations in Commands

### Problem

Many `execute_command/2` clauses in `Editor` create a temporary
`GapBuffer.new(content)` just to call a motion or text object function:

```elixir
defp execute_command(%{buffer: buf} = state, :word_forward) do
  apply_motion(buf, &Minga.Motion.word_forward/2)
  state
end

defp apply_motion(buf, motion_fn) do
  content = BufferServer.content(buf)       # GenServer call
  cursor = BufferServer.cursor(buf)         # GenServer call
  tmp_buf = GapBuffer.new(content)          # allocate + count newlines
  new_pos = motion_fn.(tmp_buf, cursor)
  BufferServer.move_to(buf, new_pos)        # GenServer call
end
```

Each motion requires **3 GenServer round-trips** and creates a
throwaway GapBuffer struct.

### Fix

1. **Add a `content_and_cursor/1` call** to `BufferServer` that returns
   `{content, cursor}` in one GenServer call.

2. **Move motion execution into the Buffer.Server process** via a
   `apply_motion/2` GenServer call. The motion function runs inside the
   server where the gap buffer already lives (zero copies):

```elixir
# In Buffer.Server
def handle_call({:apply_motion, motion_fn}, _from, state) do
  new_pos = motion_fn.(state.gap_buffer, GapBuffer.cursor(state.gap_buffer))
  new_buf = GapBuffer.move_to(state.gap_buffer, new_pos)
  {:reply, :ok, %{state | gap_buffer: new_buf}}
end
```

This eliminates the content copy, the temporary GapBuffer, and reduces
3 GenServer calls to 1.

### Impact

**High.** Reduces per-motion latency from ~3 GenServer round-trips
(~30–60 µs) to 1 (~10–20 µs) and eliminates all temporary allocations.

---

## 8. Editor: Batch Buffer.Server Mutations into Single Calls

### Problem

Several editor commands issue multiple sequential GenServer calls to
`BufferServer`:

```elixir
# change_line: up to N+3 GenServer calls for an N-character line
defp execute_command(%{buffer: buf} = state, :change_line) do
  {line, _col} = BufferServer.cursor(buf)              # call 1
  yanked = BufferServer.get_lines_content(buf, ...)    # call 2
  case BufferServer.get_lines(buf, line, 1) do         # call 3
    [text] when text != "" ->
      line_len = String.length(text)
      BufferServer.move_to(buf, {line, 0})             # call 4
      for _ <- 1..line_len do
        BufferServer.delete_at(buf)                    # calls 5..N+4
      end
  end
  BufferServer.move_to(buf, {line, 0})                 # call N+5
end
```

A 100-character line causes **105 GenServer round-trips** for a single
`cc` command.

### Fix

Add compound operations to `BufferServer` / `GapBuffer` that perform
the entire mutation in one call:

```elixir
# In Buffer.Server
def handle_call({:clear_line, line}, _from, state) do
  {yanked, new_buf} = GapBuffer.clear_line(state.gap_buffer, line)
  {:reply, {:ok, yanked}, push_undo(state, new_buf) |> mark_dirty()}
end
```

Similarly, `join_lines`, `indent_line`, `dedent_line`, and
`delete_range` + `move_to` sequences should be single calls.

### Impact

**High.** Eliminates O(n) GenServer overhead for line operations.
Each GenServer call involves message copying, scheduling, and reply
matching — eliminating 100+ calls per command is substantial.

---

## 9. Editor: Pre-build Render Binaries with IOlists

### Problem

`do_render/1` builds render commands by concatenating strings with `<>`
for padding (`String.pad_trailing`, `String.duplicate`) and joining.
Each `Protocol.encode_draw/4` call allocates a fresh binary.

The full render pipeline allocates hundreds of small binaries per frame
that are immediately sent to the Port and become garbage.

### Fix

Use iolists throughout the render pipeline. The Port's `Port.command/2`
accepts iolists natively — no need to flatten to binary:

```elixir
# Current: allocates a binary per draw command
def encode_draw(row, col, text, style) do
  <<@op_draw_text, row::16, col::16, fg::24, bg::24, attrs::8,
    text_len::16, text::binary>>
end

# Alternative: return iolist, let Port.command flatten once
# (Only if profiling shows this is a bottleneck — binary construction
#  with the <<>> syntax is already very efficient on the BEAM JIT)
```

More impactful: in `PortManager.handle_cast({:send_commands, ...})`,
the current code already does `IO.iodata_to_binary(commands)` then
`Port.command(state.port, batch)`. Since `Port.command/2` accepts
iolists, skip the intermediate flattening:

```elixir
# Before
def handle_cast({:send_commands, commands}, state) do
  batch = IO.iodata_to_binary(commands)  # unnecessary flatten
  Port.command(state.port, batch)
end

# After
def handle_cast({:send_commands, commands}, state) do
  Port.command(state.port, commands)  # Port flattens internally
end
```

**Note:** This only works if `{:packet, 4}` framing is compatible
with the iolist. Since each command is a separate binary and the Port
uses `{:packet, 4}`, commands need to be sent individually or the
framing must be handled manually. Validate this with the Zig side.

### Impact

**Medium.** Saves one full-buffer-sized allocation per render frame.
At 60 fps with a full-screen terminal, that's ~60 allocations/second
of 10–50 KB each.

---

## 10. Undo/Redo: Structural Sharing via Zipper or Diff-Based Stack

### Problem

Every mutation pushes a **complete copy** of the `GapBuffer.t()` struct
onto the undo stack. The struct contains `before` and `after_` binaries
which together hold the full file content. For a 1 MB file, each
keystroke adds ~1 MB to the undo stack. With `@max_undo_stack` of 1000,
that's potentially ~1 GB of undo history.

The BEAM's garbage collector runs per-process, so this all lives in the
`Buffer.Server` process heap and causes increasingly expensive GC
pauses.

### Fix

Store diffs instead of full snapshots:

```elixir
@type undo_entry :: {
  cursor_before :: position(),
  operations :: [{:insert, position(), String.t()} | {:delete, position(), String.t()}]
}
```

Each undo entry is typically a few bytes (the inserted/deleted text +
cursor position). Undo replays the inverse operations; redo replays
forward.

Alternative: use Erlang's reference-counted binaries. When `before` and
`after_` are > 64 bytes, the BEAM stores them as reference-counted
heap binaries. If mutations produce sub-binaries (via `binary_part/3`),
they share the underlying allocation. This already provides some
structural sharing *if* the gap buffer avoids full copies. But the
current `push_undo` stores the struct which includes the binary
references, so at least the struct + pointers are copied.

The diff approach is the clear winner for memory.

### Impact

**High for large files.** Reduces undo stack memory from O(n × stack_size)
to O(delta × stack_size). For a 1 MB file with 1000 undo entries, this
could reduce memory from ~1 GB to ~1 MB.

---

## 11. TextObject: Avoid Flattening Entire Buffer for Paren Matching

### Problem

`find_delimited_pair/4` calls `flatten_with_positions/1`, which creates
a list of `{grapheme, {line, col}}` tuples for the *entire* buffer.
For a 10,000-line file with 50 chars/line, that's 500,000 tuples
(~40 MB of list cells + tuple headers).

Then it does linear scans with `Enum.at/2` on this flat list.

### Fix

Scan backward/forward from the cursor position using binary walking on
the raw content, tracking line/col as you go. This requires no
allocation beyond the final result positions:

```elixir
defp find_open(content, byte_offset, open, close, depth) do
  # Walk backward through the binary using binary_part/3
  # Track nesting depth
  # Return {line, col} when unmatched open is found
end
```

Alternatively, use the gap buffer's `before` and `after_` directly:
scan backward through `before` for the opening delimiter, forward
through `after_` for the closing one. This naturally splits the
search and avoids materializing `content`.

### Impact

**High for large files.** Eliminates a 40 MB allocation for paren
matching on a 500K-character file. Makes `di(`, `ci{`, etc. usable
on large codebases.

---

## 12. Picker: Cache Downcased Labels and Use ETS for Large Lists

### Problem

`refilter/1` runs on every keystroke in the picker. For each item, it
calls `String.downcase/1` on the label and description. With 10,000
files in a project, that's 20,000 `String.downcase/1` calls per
keystroke.

The `length/1` function is also called repeatedly on the same lists
(`length(filtered)` appears in `move_down`, `move_up`, `visible_items`,
`count`). `length/1` is O(n) on linked lists.

### Fix

1. **Pre-compute downcased labels** at picker construction time:

```elixir
defstruct [..., :items_downcased]

def new(items, opts) do
  downcased = Enum.map(items, fn {id, label, desc} ->
    {id, label, desc, String.downcase(label), String.downcase(desc)}
  end)
  %__MODULE__{items: items, items_downcased: downcased, ...}
end
```

2. **Cache the filtered count** as a field instead of calling `length/1`:

```elixir
defstruct [..., :filtered_count]
```

3. For very large candidate sets (>5000 items), consider using
   `:ets.tab2list/1` with match specs for filtering, or maintaining a
   sorted index for prefix matching.

### Impact

**Medium.** Eliminates 20K+ `String.downcase/1` allocations per
keystroke in the picker. The count cache eliminates O(n) list traversals.

---

## 13. Keymap Trie: Compile to a Persistent Map for JIT-Friendly Lookups

### Problem

The keymap trie is already efficient. `Map.fetch/2` on small maps is
fast. However, the trie is rebuilt from `Defaults` every time the
editor starts. For the leader trie, `Defaults.leader_trie()` is called
on every SPC keypress.

### Fix

1. **Module-attribute compile-time construction**: Build the trie at
   compile time using module attributes, so `leader_trie()` returns a
   pre-built constant:

```elixir
# In Defaults
@leader_trie (
  Trie.new()
  |> Trie.bind([{?f, 0}, {?s, 0}], :save, "Save file")
  |> Trie.bind([{?f, 0}, {?f, 0}], :find_file, "Find file")
  # ...
)

def leader_trie, do: @leader_trie
```

Module attributes are evaluated at compile time and stored as literals
in the BEAM bytecode. The JIT can inline the reference, and the data
lives in the literal pool (never GC'd, shared across processes).

2. **Use `:persistent_term`** for runtime-registered keybindings:

```elixir
:persistent_term.put({Minga.Keymap, :leader_trie}, trie)
```

`:persistent_term` lookups compile to a single load instruction on
the JIT and are the fastest possible read path on the BEAM. Writes are
expensive (triggers a global GC), but keymaps change rarely.

### Impact

**Low.** The trie is already small and fast. This is a polish
optimization that eliminates a function call + map construction on every
SPC press.

---

## 14. Port Protocol: Leverage Sub-Binary References

### Problem

`Protocol.decode_event/1` uses binary pattern matching, which is
already JIT-optimized. However, if the incoming Port data is a
reference-counted binary (> 64 bytes), sub-binary references created
by pattern matching will keep the entire original binary alive until
all sub-binaries are GC'd.

### Fix

This is already mostly fine — input events are small (5–9 bytes).
For render commands going *out*, ensure large text payloads in
`encode_draw/4` use sub-binaries of the original line text rather than
copies:

```elixir
# If line_text is already a heap binary, this creates a sub-binary
# reference (zero-copy) rather than a new allocation:
text_slice = binary_part(line_text, start, length)
```

The JIT generates specialized code for `binary_part/3` that avoids
copying when the source is a reference-counted binary.

### Impact

**Low.** The protocol is already efficient. This is a micro-optimization
for large text payloads in draw commands.

---

## 15. GC Pressure: Reduce Short-Lived Allocations in the Render Loop

### Problem

The render loop (`do_render/1`) runs on every keystroke and allocates:
- Line text list from `render_snapshot` (~100 strings)
- Grapheme lists for visual selection highlighting
- Modeline segment strings (mode badge, file name, padding)
- Tilde row strings (`"~"` × remaining rows)
- Which-key popup strings
- Picker item strings

All of these become garbage after `Port.command/2` sends them. The BEAM
runs per-process GC, so the Editor process accumulates garbage quickly
during fast typing.

### Fix

1. **Reduce allocations in the hot path:**
   - Pre-compute tilde row commands once and reuse them (they're the
     same every frame unless the terminal resizes).
   - Cache the modeline template and only rebuild segments that changed
     (mode, cursor position, dirty flag).
   - Use `@compile {:inline, [...]}` for small helper functions in the
     render path to avoid function call overhead.

2. **Force a minor GC after each render** if profiling shows GC pauses
   during typing:

```elixir
# After sending render commands:
:erlang.garbage_collect(self(), type: :minor)
```

This spreads GC work evenly instead of allowing it to accumulate into
a major collection pause.

3. **Use `Process.flag(:min_heap_size, n)`** on the Editor process to
   pre-allocate a larger heap, reducing the frequency of heap growth
   and GC triggers:

```elixir
def init(opts) do
  Process.flag(:min_heap_size, 65536)  # 512 KB initial heap
  # ...
end
```

### Impact

**Medium.** Smooths out latency spikes from GC pauses during rapid
typing. Most noticeable on large files where render allocations are
bigger.

---

## 16. Process Architecture: Consider ETS for Shared Read-Only State

### Problem

The Editor process calls `BufferServer.content/1` to get buffer content
for motions, then the BufferServer serializes the entire content string
across processes. For a 1 MB file, this is a 1 MB copy on every motion.

GenServer message passing always copies data between process heaps
(no shared memory on the BEAM).

### Fix

For read-heavy data like buffer content, consider using
`:persistent_term` or ETS:

```elixir
# In Buffer.Server, after each mutation:
:persistent_term.put({Minga.Buffer, self()}, content)

# In Editor (zero-copy read):
content = :persistent_term.get({Minga.Buffer, self()})
```

**Caveat:** `:persistent_term.put/2` triggers a global GC of all
processes that hold references to the old value. For frequent updates
(every keystroke), this is too expensive.

**Better alternative:** Use ETS with `{:read_concurrency, true}`:

```elixir
# At Buffer.Server startup:
table = :ets.new(:buffer_content, [:set, :public, {:read_concurrency, true}])

# After mutation:
:ets.insert(table, {:content, new_content})

# In Editor (single copy into reader's heap):
[{:content, text}] = :ets.lookup(table, :content)
```

ETS with `read_concurrency` uses optimistic locking that the JIT can
specialize. The content is still copied into the reader's heap, but
it avoids the GenServer scheduling overhead.

**Best alternative:** Keep motions inside the Buffer.Server process
(see recommendation #7). This eliminates the copy entirely.

### Impact

**Medium-High.** Most beneficial when combined with recommendation #7
(moving motion execution into the Buffer.Server).

---

## 17. JIT-Specific: Help the BEAM JIT Generate Better Native Code

The BEAM JIT (introduced in OTP 24, significantly improved in OTP 25+
and OTP 26+) generates native code for hot functions. Several patterns
help it produce better code:

### a. Use Guards Over Dynamic Dispatch

The JIT specializes function clauses based on guard types. Functions
with guards like `when is_binary(text)` or `when direction in [...]`
generate type-specialized native code:

```elixir
# Good — JIT specializes for atom values
def move(%__MODULE__{} = buf, :left), do: move_left(buf)
def move(%__MODULE__{} = buf, :right), do: move_right(buf)
def move(%__MODULE__{} = buf, :up), do: move_up(buf)
def move(%__MODULE__{} = buf, :down), do: move_down(buf)

# Less optimal (current code) — JIT must generate a case dispatch
def move(%__MODULE__{} = buf, direction) do
  case direction do
    :left -> move_left(buf)
    ...
  end
end
```

The current `move/2` uses a `case` inside a single clause. Splitting
into multiple clauses lets the JIT generate a jump table.

### b. Binary Pattern Matching Over `String` Functions

The JIT generates excellent code for binary pattern matching in function
heads and `case` expressions:

```elixir
# JIT-friendly: compiles to native binary matching
defp classify_char(<<c, _::binary>>) when c >= ?a and c <= ?z, do: :word
defp classify_char(<<c, _::binary>>) when c >= ?A and c <= ?Z, do: :word
defp classify_char(<<c, _::binary>>) when c >= ?0 and c <= ?9, do: :word
defp classify_char(<<?_, _::binary>>), do: :word
defp classify_char(<<?\s, _::binary>>), do: :whitespace
defp classify_char(<<?\t, _::binary>>), do: :whitespace
defp classify_char(<<?\n, _::binary>>), do: :whitespace
defp classify_char(_), do: :punctuation

# Less optimal (current code): regex match
defp word_char?(g), do: g =~ ~r/^[a-zA-Z0-9_]$/
```

The regex version compiles to a PCRE call (C function through NIF).
The pattern matching version compiles to native comparison instructions
that the JIT can fully inline. For functions called millions of times
per motion (character classification), this matters.

### c. Avoid `Enum` for Small, Known-Size Collections

`Enum` functions add overhead from protocol dispatch and anonymous
function calls. For small collections, use direct recursion or
comprehensions:

```elixir
# Slower: Enum protocol dispatch + closure allocation
Enum.map(segments, fn {text, fg, bg, opts} -> ... end)

# Faster for small lists: list comprehension (JIT-optimized)
for {text, fg, bg, opts} <- segments, do: ...
```

### d. Mark Hot Functions for Inlining

```elixir
@compile {:inline, [
  word_char?: 1,
  whitespace?: 1,
  classify_char: 1
]}
```

The `@compile {:inline, ...}` directive tells the BEAM compiler to
inline the function at the caller. The JIT then has a larger function
body to optimize, enabling better register allocation and dead code
elimination.

### Impact

**Medium overall.** Individual micro-optimizations, but they compound
in hot loops (character classification runs once per grapheme per
motion).

---

## 18. Benchmarking Strategy

### Tools

- **`Benchee`** micro-benchmarks for individual functions
- **`:timer.tc/1`** quick timing in IEx
- **`:erlang.statistics(:reductions)`** BEAM work units (proxy for CPU)
- **`:erlang.process_info(pid, :memory)`** per-process heap size
- **`:erlang.process_info(pid, :garbage_collection)`** GC stats
- **`recon`** production-ready process inspection
- **`eflame`** / **`eflambe`** flame graphs for BEAM processes

### What to Measure

1. **Per-keystroke latency**: Time from `handle_info({:minga_input, ...})`
   to `Port.command/2` completion. Target: < 1 ms for normal mode,
   < 5 ms for complex operations.

2. **Memory per buffer**: `:erlang.process_info(buf_pid, :memory)` with
   files of 1K, 10K, 100K lines. Track growth over 1000 edits.

3. **GC pause frequency**: Monitor `{:garbage_collection, info}` trace
   events on the Editor process during sustained typing.

4. **Allocation rate**: Use `:erlang.system_info(:alloc_util_allocators)`
   before/after a burst of operations.

### Existing Performance Test

The project already has `test/perf/gap_buffer_perf_test.exs`. Extend
this with benchmarks for:
- Motion on 10K-line buffer (word_forward, paragraph, bracket match)
- Render cycle with full viewport
- Picker filtering with 5000 candidates
- 1000 sequential inserts (typing simulation)

### Priority Order

Implement optimizations in this order for maximum impact:

1. **#1** Line index cache (eliminates the #1 allocation source)
2. **#7** — Move motions into Buffer.Server (eliminates cross-process copies)
3. **#8** — Batch mutations (eliminates O(n) GenServer calls)
4. **#5** — Tuple indexing in motions (O(n²) → O(n))
5. **#10** — Diff-based undo (memory)
6. **#2** — Binary walking (allocation reduction)
7. **#11** — TextObject scanning (large file paren matching)
8. **#17** — JIT-specific patterns (polish)
9. Everything else
