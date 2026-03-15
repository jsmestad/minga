defmodule Minga.Input do
  @moduledoc """
  Key input dispatch infrastructure.

  The input pipeline has two layers:

  1. **Overlay handlers** — modal UI overlays (picker, completion,
     conflict prompt) that take priority over everything. These live
     in the Editor's focus stack and are checked first.

  2. **Editor handlers** — scope-specific dispatch (Scoped), global
     bindings (Ctrl+S, Ctrl+Q), and the mode FSM (vim normal/insert/
     visual). These live inside the active surface and are called
     after overlays pass through.

  The `default_stack/0` returns the combined stack for backward
  compatibility. New code should use `overlay_handlers/0` and
  `surface_handlers/0` to build the split dispatch.
  """

  alias Minga.Input.AgentChatNav
  alias Minga.Input.AgentMouse
  alias Minga.Input.AgentPanel
  alias Minga.Input.AgentSearch
  alias Minga.Input.Completion
  alias Minga.Input.ConflictPrompt
  alias Minga.Input.Dashboard
  alias Minga.Input.DiffReview
  alias Minga.Input.FileTreeHandler
  alias Minga.Input.GlobalBindings
  alias Minga.Input.Hover
  alias Minga.Input.Interrupt
  alias Minga.Input.MentionCompletion
  alias Minga.Input.ModeFSM
  alias Minga.Input.Picker
  alias Minga.Input.Popup
  alias Minga.Input.Scoped
  alias Minga.Input.ToolApproval

  @doc """
  Returns the full default focus stack.

  Priority order (first handler wins):
  0. Interrupt — Ctrl-G escape hatch, always active, resets to known-good state
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
      Interrupt,
      Dashboard,
      ConflictPrompt,
      Picker,
      Hover,
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
      Interrupt,
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
      Dashboard,
      AgentSearch,
      MentionCompletion,
      ToolApproval,
      DiffReview,
      AgentPanel,
      FileTreeHandler,
      Popup,
      Scoped,
      AgentChatNav,
      GlobalBindings,
      AgentMouse,
      ModeFSM
    ]
  end

  @doc """
  Returns true when the vim mode FSM is mid-sequence and should receive
  the next key before any handler-specific dispatch runs.

  Covers leader key sequences, pending `g` prefix, operator-pending mode,
  and command-line mode. Used by AgentPanel and FileTreeHandler to decide
  whether to delegate directly to the Mode FSM.
  """
  @spec key_sequence_pending?(map()) :: boolean()
  def key_sequence_pending?(%{vim: %{mode_state: %{leader_node: node}}}) when node != nil,
    do: true

  def key_sequence_pending?(%{vim: %{mode_state: %{pending_g: true}}}), do: true

  def key_sequence_pending?(%{vim: %{mode: mode}}) when mode in [:operator_pending, :command],
    do: true

  def key_sequence_pending?(_state), do: false
end
