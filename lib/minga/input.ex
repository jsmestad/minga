defmodule Minga.Input do
  @moduledoc """
  Key input dispatch infrastructure.

  Provides the default focus stack and re-exports the handler behaviour.
  The focus stack determines the priority order for key processing:
  highest-priority handlers (modal overlays) are first, the mode FSM
  is last.

  Only truly modal overlays (picker, completion, conflict prompt) appear
  as separate handlers in the stack. All view-type-specific keybindings
  (agent, file tree) are handled by `Minga.Input.Scoped` through the
  keymap scope system.
  """

  alias Minga.Input.Completion
  alias Minga.Input.ConflictPrompt
  alias Minga.Input.GlobalBindings
  alias Minga.Input.ModeFSM
  alias Minga.Input.Picker
  alias Minga.Input.Scoped

  @doc """
  Returns the default focus stack.

  Priority order (first handler wins):
  1. ConflictPrompt — modal, swallows all keys when active
  2. Scoped — keymap scope resolution (agent, file_tree, editor + side panel)
  3. Picker — modal overlay, blocks all input while active
  4. Completion — insert-mode sub-dispatch for popup navigation
  5. GlobalBindings — Ctrl+S save, Ctrl+Q quit (always active)
  6. ModeFSM — the normal vim mode system (fallback)
  """
  @spec default_stack() :: [module()]
  def default_stack do
    [
      ConflictPrompt,
      Scoped,
      Picker,
      Completion,
      GlobalBindings,
      ModeFSM
    ]
  end
end
