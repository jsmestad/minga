defmodule Minga.Input do
  @moduledoc """
  Key input dispatch infrastructure.

  Provides the default focus stack and re-exports the handler behaviour.
  The focus stack determines the priority order for key processing:
  highest-priority handlers (modal overlays) are first, the mode FSM
  is last.
  """

  alias Minga.Agent.View.Keys, as: AgenticViewKeys
  alias Minga.Input.AgentPanel
  alias Minga.Input.Completion
  alias Minga.Input.ConflictPrompt
  alias Minga.Input.FileTree
  alias Minga.Input.GlobalBindings
  alias Minga.Input.ModeFSM
  alias Minga.Input.Picker

  @doc """
  Returns the default focus stack.

  Priority order (first handler wins):
  1. ConflictPrompt — modal, swallows all keys when active
  2. AgenticViewKeys — full-screen agentic view (when active, handles all non-SPC keys)
  3. AgentPanel — agent chat input (temporary, until agent becomes a buffer)
  4. FileTree — file tree navigation (temporary, until tree becomes a buffer)
  5. Picker — modal overlay, blocks all input while active
  6. Completion — insert-mode sub-dispatch for popup navigation
  7. GlobalBindings — Ctrl+S save, Ctrl+Q quit (always active)
  8. ModeFSM — the normal vim mode system (fallback)
  """
  @spec default_stack() :: [module()]
  def default_stack do
    [
      ConflictPrompt,
      AgenticViewKeys,
      AgentPanel,
      FileTree,
      Picker,
      Completion,
      GlobalBindings,
      ModeFSM
    ]
  end
end
