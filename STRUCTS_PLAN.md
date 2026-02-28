# Plan: Replace Anonymous Maps with Named Structs (DDD)

## Goal

Replace anonymous `%{}` maps used as domain state throughout Minga with named
structs, leveraging Elixir 1.19's set-theoretic type system for compile-time
narrowing, enforced field presence, and domain-expressive naming.

## Context

### Current State

The codebase has **3 proper structs** (`Command`, `Viewport`, `GapBuffer`) and
**8 anonymous map types** used as data clumps. The anonymous maps are the FSM
mode state, GenServer internal states, and trie nodes — all core domain concepts
that deserve names.

### Why This Matters for Elixir 1.19

Elixir 1.19's set-theoretic type system narrows types through pattern matching.
With structs:

```elixir
# Struct: compiler knows exactly which fields exist and their types
def handle(%ModeState{count: count, leader_node: node}) when is_nil(node) do
  # compiler narrows `node` to nil, `count` to its type
end
```

With anonymous maps:

```elixir
# Map: compiler only knows it has :count key, everything else is optional(atom()) => term()
def handle(%{count: count, leader_node: node}) when is_nil(node) do
  # compiler can't narrow — `term()` stays `term()`
end
```

Structs also give us:
- `@enforce_keys` — crashes at construction time if you forget a field
- Pattern match on `%StructName{}` — can't accidentally pass the wrong map type
- Better error messages — "expected %ModeState{}" vs "expected a map"

### DDD Naming Principle

Each struct should name a domain concept, not an implementation detail:

| ❌ Anonymous / generic | ✅ Named domain concept |
|----------------------|----------------------|
| `%{count: nil, leader_node: nil, ...}` | `%ModeState{}` |
| `%{buffer: pid, viewport: ...}` | `%Editor.State{}` |
| `%{gap_buffer: ..., file_path: ...}` | `%Buffer.State{}` |
| `%{port: nil, subscribers: ...}` | `%PortManager.State{}` |
| `%{children: ..., command: ...}` | `%Trie.Node{}` |
| `%{key: "f", description: "..."}` | `%WhichKey.Binding{}` |

## Approach

Convert anonymous maps to structs one domain at a time, starting with the
most impactful (most `Map.put`/`Map.get` calls, most pattern matches). Each
struct gets `@enforce_keys`, `@type t`, and compile-time field validation.

The FSM mode state is the trickiest — it's currently a single polymorphic map
that different modes add/remove keys from dynamically. This is the biggest DDD
win: splitting it into distinct per-mode state structs eliminates the
`optional(atom()) => term()` escape hatch.

### Alternatives Considered

| Alternative | Why rejected |
|-------------|-------------|
| Keep maps, add more `@type` annotations | Doesn't help the compiler narrow; `optional(atom()) => term()` is a type hole |
| One giant `ModeState` struct with all fields | Violates DDD; visual fields shouldn't exist in normal mode state |
| Protocol-based state dispatch | Over-engineered for internal state; struct pattern matching is simpler |

## Steps

### 1. `Minga.Mode.State` — Base FSM state struct

- **Files**: `lib/minga/mode/state.ex`, `lib/minga/mode.ex`
- **Changes**:
  - Define `Minga.Mode.State` with the shared base fields:
    ```elixir
    defmodule Minga.Mode.State do
      @enforce_keys [:count]
      defstruct [
        count: nil,
        leader_node: nil,
        leader_keys: []
      ]

      @type t :: %__MODULE__{
        count: non_neg_integer() | nil,
        leader_node: Minga.Keymap.Trie.Node.t() | nil,
        leader_keys: [String.t()]
      }
    end
    ```
  - Update `Mode.initial_state/0` to return `%Mode.State{}`
  - Update `Mode.state()` type to `Mode.State.t()`
  - This is the base that all mode modules work with
  - Normal mode stays with this base (it only uses count + leader fields)

### 2. `Minga.Mode.OperatorPendingState` — Operator-pending context

- **Files**: `lib/minga/mode/operator_pending_state.ex`, `lib/minga/mode/operator_pending.ex`, `lib/minga/mode/normal.ex`
- **Changes**:
  - Define struct:
    ```elixir
    defmodule Minga.Mode.OperatorPendingState do
      @enforce_keys [:operator, :op_count, :count]
      defstruct [
        operator: nil,
        op_count: 1,
        count: nil,
        pending_g: false,
        text_object_modifier: nil,
        leader_node: nil,
        leader_keys: []
      ]
    end
    ```
  - Replace `Map.put(state, :operator, :delete)` in Normal with struct construction
  - Replace `Map.delete(:operator)` in `clear_op_state` with conversion back to `%Mode.State{}`
  - Replace `Map.get(state, :op_count, 1)` with `state.op_count`

### 3. `Minga.Mode.VisualState` — Visual mode context

- **Files**: `lib/minga/mode/visual_state.ex`, `lib/minga/mode/visual.ex`, `lib/minga/mode/normal.ex`, `lib/minga/editor.ex`
- **Changes**:
  - Define struct:
    ```elixir
    defmodule Minga.Mode.VisualState do
      @enforce_keys [:visual_type, :count]
      defstruct [
        visual_type: :char,
        visual_anchor: {0, 0},
        count: nil,
        leader_node: nil,
        leader_keys: []
      ]
    end
    ```
  - Replace `Map.put(state, :visual_type, :char)` with struct construction
  - Replace `Map.get(ms, :visual_anchor, {0, 0})` with `ms.visual_anchor`
  - Editor can now pattern match `%VisualState{}` instead of checking `mode == :visual`

### 4. `Minga.Mode.CommandState` — Command line context

- **Files**: `lib/minga/mode/command_state.ex`, `lib/minga/mode/command.ex`, `lib/minga/editor.ex`
- **Changes**:
  - Define struct:
    ```elixir
    defmodule Minga.Mode.CommandState do
      @enforce_keys [:input, :count]
      defstruct [
        input: "",
        count: nil,
        leader_node: nil,
        leader_keys: []
      ]
    end
    ```
  - Replace `Map.get(state, :input, "")` with `state.input`
  - Replace `Map.put(state, :input, "")` with `%{state | input: ""}`
  - Editor can pattern match `%CommandState{}` for command-mode rendering

### 5. `Minga.Keymap.Trie.Node` — Trie node struct

- **Files**: `lib/minga/keymap/trie.ex`
- **Changes**:
  - Extract the anonymous `%{children: ..., command: ..., description: ...}` into:
    ```elixir
    defstruct [
      children: %{},
      command: nil,
      description: nil
    ]
    ```
  - All `%{children: children}` patterns become `%Node{children: children}`
  - `new/0` returns `%Node{}` instead of `%{children: %{}, command: nil, description: nil}`
  - This prevents accidentally passing a random map where a trie node is expected

### 6. `Minga.Editor.State` — Editor state struct

- **Files**: `lib/minga/editor.ex`
- **Changes**:
  - Extract `state` type into a proper struct:
    ```elixir
    defmodule Minga.Editor.State do
      @enforce_keys [:port_manager, :viewport, :mode, :mode_state]
      defstruct [
        buffer: nil,
        port_manager: nil,
        viewport: nil,
        mode: :normal,
        mode_state: nil,
        whichkey_node: nil,
        whichkey_timer: nil,
        show_whichkey: false,
        register: nil
      ]
    end
    ```
  - Replace `%{buffer: nil} = state` patterns with `%State{buffer: nil} = state`
  - Replace `%{state | mode: new_mode}` with `%State{state | mode: new_mode}`
  - All `execute_command` clauses get struct matching for free

### 7. `Minga.Buffer.State` — Buffer server state struct

- **Files**: `lib/minga/buffer/server.ex`
- **Changes**:
  - Extract:
    ```elixir
    defmodule Minga.Buffer.State do
      @enforce_keys [:gap_buffer]
      defstruct [
        gap_buffer: nil,
        file_path: nil,
        dirty: false,
        undo_stack: [],
        redo_stack: []
      ]
    end
    ```
  - Replace `%{gap_buffer: gb, file_path: fp}` patterns with `%State{}`
  - Replace `push_undo` helper to use struct updates

### 8. `Minga.Port.Manager.State` — Port manager state struct

- **Files**: `lib/minga/port/manager.ex`
- **Changes**:
  - Extract:
    ```elixir
    defmodule Minga.Port.Manager.State do
      @enforce_keys [:renderer_path]
      defstruct [
        port: nil,
        subscribers: [],
        renderer_path: "",
        ready: false,
        terminal_size: nil
      ]
    end
    ```
  - Replace all `%{port: nil} = state` patterns with `%State{port: nil} = state`

### 9. `Minga.WhichKey.Binding` — Binding display struct

- **Files**: `lib/minga/which_key.ex`
- **Changes**:
  - Replace `%{key: String.t(), description: String.t()}` with:
    ```elixir
    defmodule Minga.WhichKey.Binding do
      @enforce_keys [:key, :description]
      defstruct [:key, :description]

      @type t :: %__MODULE__{
        key: String.t(),
        description: String.t()
      }
    end
    ```
  - Replace `%{key: key, description: desc}` patterns with `%Binding{}`
  - `format_bindings/1` returns `[Binding.t()]`

## Testing

- Every step: existing tests must pass after the conversion (struct access is
  backwards-compatible with map access in pattern matching)
- Run `mix test --warnings-as-errors` after each step
- Run `mix dialyzer` after each step to verify type narrowing improves
- New tests aren't needed — this is a refactor, not new behavior. But any test
  that constructs state maps directly (e.g., `%{count: nil}`) needs updating
  to use the new struct constructors.

## Risks & Open Questions

1. **Mode state polymorphism** — Currently `Mode.process/3` returns a generic
   `state()` map. With per-mode structs, the return type becomes a union:
   `Mode.State.t() | VisualState.t() | CommandState.t() | OperatorPendingState.t()`.
   This is actually *better* for Elixir 1.19 — the compiler can narrow on
   struct pattern matches in the editor's `handle_key` dispatching.

2. **Test state construction** — Tests that do `%{count: 3}` or
   `%{count: nil, leader_node: nil}` need updating. This is mechanical but
   touches many test files.

3. **Backwards-compatible access** — `state.field` works identically on structs
   and maps. `Map.get(state, :field, default)` also works on structs. The main
   breaking change is `Map.put/3` and `Map.delete/2` — these need to become
   struct update syntax (`%{state | field: value}`). This is already the
   recommended pattern and is what we're targeting.

4. **Ordering** — Steps 1-4 (mode states) should go first since they touch the
   most code and provide the biggest type inference win. Steps 5-9 are simpler
   extractions of GenServer state.

---

## GitHub Ticket

```markdown
# Editor state types use named structs for compile-time safety and domain clarity

**Type:** Feature

## What
Core editor state is modeled as anonymous maps with `optional(atom()) => term()`
type holes. The compiler can't narrow these types through pattern matching, and
nothing prevents passing a random map where a mode state or editor state is
expected.

## Why
Elixir 1.19's set-theoretic type system provides real compile-time narrowing
when it can see struct types — but only if we use structs. Converting anonymous
maps to named domain structs eliminates an entire class of "wrong map shape"
bugs, enforces required fields at construction time via `@enforce_keys`, and
makes the domain model self-documenting. Every `Map.get(state, :field, default)`
call is a signal that the compiler doesn't know whether the field exists.

## Acceptance Criteria
- [ ] FSM mode state is modeled as distinct structs per mode: `Mode.State` (normal/base), `OperatorPendingState`, `VisualState`, `CommandState`
- [ ] Each mode's `handle_key/2` receives and returns its specific struct type, not a generic map
- [ ] `Editor.State`, `Buffer.State`, `Port.Manager.State` are named structs with `@enforce_keys` for required fields
- [ ] `Trie.Node` is a named struct instead of an anonymous map
- [ ] `WhichKey.Binding` is a named struct
- [ ] No `Map.put/3` or `Map.delete/2` calls remain on domain state — all use struct update syntax
- [ ] No `Map.get(state, :field, default)` calls remain on domain state — all use direct `state.field` access
- [ ] All existing tests pass after migration
- [ ] `mix dialyzer` passes clean

### Developer Notes
The mode state polymorphism is the most interesting part — `Mode.process/3`
currently returns a generic `state()` that any mode can add arbitrary keys to.
With per-mode structs, the return type becomes a union that Elixir 1.19 can
narrow through `%StructName{}` pattern matches. The editor's `handle_key`
and `execute_command` clauses benefit directly from this narrowing.

Order: mode states (1-4) first (biggest type inference win), then GenServer
states (5-8), then small value objects (9).
```
