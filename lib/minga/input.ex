defmodule Minga.Input do
  @moduledoc """
  Key input dispatch infrastructure.

  The input pipeline has two layers:

  1. **Overlay handlers** — modal UI overlays (picker, completion,
     conflict prompt) that take priority over everything. These live
     in the Editor's focus stack and are checked first.

  2. **Surface handlers** — scope-specific dispatch (Scoped), global
     bindings (Ctrl+S, Ctrl+Q), and the mode FSM (vim normal/insert/
     visual). These live inside the active surface and are called
     after overlays pass through.

  The `default_stack/0` returns the combined stack for backward
  compatibility. New code should use `overlay_handlers/0` and
  `surface_handlers/0` to build the split dispatch.
  """

  alias Minga.Input.AgentChatNav
  alias Minga.Input.AgentPanel
  alias Minga.Input.AgentSearch
  alias Minga.Input.Completion
  alias Minga.Input.ConflictPrompt
  alias Minga.Input.DiffReview
  alias Minga.Input.FileTreeHandler
  alias Minga.Input.GlobalBindings
  alias Minga.Input.MentionCompletion
  alias Minga.Input.ModeFSM
  alias Minga.Input.Picker
  alias Minga.Input.Scoped
  alias Minga.Input.ToolApproval

  @doc """
  Returns the full default focus stack.

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

  @doc """
  Returns the overlay handlers that sit above the surface.

  These are modal UI elements (picker, completion menu, conflict
  prompt) that must intercept keys before any surface sees them.
  The Editor walks these first; if none consume the key, it
  delegates to the active surface.
  """
  @spec overlay_handlers() :: [module()]
  def overlay_handlers do
    [
      ConflictPrompt,
      Picker,
      Completion
    ]
  end

  @doc """
  Returns the editor-level handlers for buffer editing.

  These handle scope-specific dispatch, global bindings, and the
  vim mode FSM. They run after overlays have passed through.
  """
  @spec surface_handlers() :: [module()]
  def surface_handlers do
    [
      AgentSearch,
      MentionCompletion,
      ToolApproval,
      DiffReview,
      AgentPanel,
      FileTreeHandler,
      Scoped,
      AgentChatNav,
      GlobalBindings,
      ModeFSM
    ]
  end
end
