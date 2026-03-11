defmodule Minga.Surface do
  @moduledoc """
  Behaviour for a view context that can receive input and render itself.

  A Surface owns its domain state and manages its own lifecycle. The
  Editor GenServer holds a reference to the active surface and delegates
  input/rendering to it. Surfaces communicate with the Editor through
  a narrow interface: declarative side effects returned from callbacks.

  ## Design

  Surfaces are pure `state -> {state, effects}` functions. The Editor
  interprets the returned effects (trigger render, open file, switch buffer,
  etc.) without knowing the surface's internal logic.

  Two implementations exist today:

  * `Minga.Surface.BufferView` — file editing (vim modes, windows, file tree)
  * `Minga.Surface.AgentView` — agentic chat (planned for Phase 2)

  ## Adding a new surface

  1. Create a module that `@behaviour Minga.Surface`
  2. Define a state struct with `@enforce_keys` and `@type t`
  3. Implement all callbacks
  4. Register the surface as a tab kind in `Minga.Editor.State.Tab`
  """

  alias Minga.Editor.DisplayList

  @typedoc "Opaque surface state. Each implementation defines its own struct."
  @type state :: term()

  @typedoc """
  Side effects the Editor must handle after a surface processes input.

  * `:render` — schedule a debounced render
  * `{:open_file, path}` — open a file in a new or existing buffer
  * `{:switch_buffer, pid}` — make this buffer active
  * `{:set_status, msg}` — show a status message in the minibuffer
  * `{:push_overlay, module}` — push an overlay handler onto the focus stack
  * `{:pop_overlay, module}` — pop an overlay handler from the focus stack
  """
  @type effect ::
          :render
          | {:open_file, String.t()}
          | {:switch_buffer, pid()}
          | {:set_status, String.t()}
          | {:push_overlay, module()}
          | {:pop_overlay, module()}

  @doc "Returns the keymap scope name for this surface."
  @callback scope() :: Minga.Keymap.Scope.scope_name()

  @doc "Processes a key press. Returns updated state and any side effects."
  @callback handle_key(state(), codepoint :: non_neg_integer(), modifiers :: non_neg_integer()) ::
              {state(), [effect()]}

  @doc "Processes a mouse event. Returns updated state and any side effects."
  @callback handle_mouse(
              state(),
              row :: integer(),
              col :: integer(),
              button :: atom(),
              modifiers :: non_neg_integer(),
              event_type :: atom(),
              click_count :: pos_integer()
            ) ::
              {state(), [effect()]}

  @doc "Renders the surface into the given rect. Returns display list draws."
  @callback render(
              state(),
              rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
            ) ::
              {state(), [DisplayList.draw()]}

  @doc "Processes a domain-specific event (e.g., LSP response, file watcher, agent event)."
  @callback handle_event(state(), event :: term()) :: {state(), [effect()]}

  @doc "Returns the cursor position and shape for the surface."
  @callback cursor(state()) ::
              {row :: non_neg_integer(), col :: non_neg_integer(), shape :: atom()}

  @doc "Called when this surface becomes the active tab."
  @callback activate(state()) :: state()

  @doc "Called when this surface is backgrounded (another tab activated)."
  @callback deactivate(state()) :: state()
end
