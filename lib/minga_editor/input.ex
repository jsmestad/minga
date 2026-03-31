defmodule MingaEditor.Input do
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

  alias MingaEditor.Input.AgentMouse
  alias MingaEditor.Input.AgentNav
  alias MingaEditor.Input.AgentPanel
  alias MingaEditor.Input.Completion
  alias MingaEditor.Input.ConflictPrompt
  alias MingaEditor.Input.Dashboard
  alias MingaEditor.Input.DiffReview
  alias MingaEditor.Input.FileTreeHandler
  alias MingaEditor.Input.GitStatus
  alias MingaEditor.Input.GlobalBindings
  alias MingaEditor.Input.Hover
  alias MingaEditor.Input.Interrupt
  alias MingaEditor.Input.MentionCompletion
  alias MingaEditor.Input.ModeFSM
  alias MingaEditor.Input.Picker
  alias MingaEditor.Input.Popup
  alias MingaEditor.Input.Prompt
  alias MingaEditor.Input.Scoped
  alias MingaEditor.Input.SignatureHelp
  alias MingaEditor.Input.ToolApproval

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
      SignatureHelp,
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
      Prompt,
      Picker,
      Completion
    ]
  end

  @doc """
  Returns the editor-level handlers for buffer editing.

  These handle scope-specific dispatch, global bindings, and the
  editing model's key handler. The last handler in the list is
  determined by the active editing model: `ModeFSM` for vim,
  `CUA.Dispatch` for CUA.
  """
  @spec surface_handlers() :: [module()]
  def surface_handlers do
    surface_handlers(%{editing_model: Minga.Editing.active_model()})
  end

  @doc """
  Returns the surface handlers for the given editor state.

  The editing model is read from `state.editing_model` to determine
  whether the bottom-of-stack handler is ModeFSM (vim) or CUA.Dispatch.
  """
  @spec surface_handlers(map()) :: [module()]
  def surface_handlers(state) do
    bottom_handler = editing_dispatch_handler(state)

    base = [
      Dashboard,
      MentionCompletion,
      ToolApproval,
      DiffReview,
      AgentPanel,
      FileTreeHandler,
      GitStatus,
      Popup,
      MingaEditor.Input.CUA.TUISpaceLeader,
      Scoped,
      AgentNav,
      GlobalBindings,
      AgentMouse
    ]

    base ++ [bottom_handler]
  end

  @doc """
  Returns the appropriate bottom-of-stack dispatch handler for the
  active editing model.
  """
  @spec editing_dispatch_handler(map()) :: module()
  def editing_dispatch_handler(state) do
    case Minga.Editing.active_model(state) do
      Minga.Editing.Model.Vim -> ModeFSM
      Minga.Editing.Model.CUA -> MingaEditor.Input.CUA.Dispatch
    end
  end

  @doc """
  Returns true when the editing model is mid-sequence and should receive
  the next key before any handler-specific dispatch runs.

  For vim: leader key sequences, pending `g` prefix, operator-pending
  mode, and command-line mode. For CUA: always false (no multi-key
  sequences). Used by AgentPanel and FileTreeHandler to decide whether
  to delegate directly to the bottom-of-stack dispatch handler.
  """
  @spec key_sequence_pending?(MingaEditor.State.t()) :: boolean()
  def key_sequence_pending?(state) do
    Minga.Editing.key_sequence_pending?(state)
  end

  # ── Modifier constants ───────────────────────────────────────────────────

  @doc "Keyboard modifier flag for Ctrl."
  @spec mod_ctrl() :: non_neg_integer()
  def mod_ctrl, do: 0x02

  @doc "Keyboard modifier flag for Alt/Option."
  @spec mod_alt() :: non_neg_integer()
  def mod_alt, do: 0x04
end
