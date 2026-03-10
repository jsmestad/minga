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
  2. Picker — modal overlay, blocks all input while active
  3. Completion — insert-mode sub-dispatch for popup navigation
  4. Scoped — keymap scope resolution (agent, file_tree, editor + side panel)
  5. GlobalBindings — Ctrl+S save, Ctrl+Q quit (always active)
  6. ModeFSM — the normal vim mode system (fallback)

  UI overlays (Picker, Completion) sit above Scoped so they intercept
  keys when active regardless of keymap scope. Without this ordering,
  Scoped's agent handler swallows keys (Enter, Escape, typed chars)
  before the Picker ever sees them, making the picker unusable from
  agentic view.
  """
  @spec default_stack() :: [module()]
  def default_stack do
    [
      ConflictPrompt,
      Picker,
      Completion,
      Scoped,
      GlobalBindings,
      ModeFSM
    ]
  end
end
