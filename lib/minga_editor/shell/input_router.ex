defmodule MingaEditor.Shell.InputRouter do
  @moduledoc """
  Behaviour: how a shell routes input.

  Carved out of `MingaEditor.Shell`. This is the natural home for the
  focus-tree mouse routing in #1435 and any future "click-to-focus"
  semantics — those are presentation concerns the shell owns, not
  the editing model.
  """

  @typedoc "Shell-specific state. Each shell defines its own struct."
  @type shell_state :: term()

  @typedoc "Workspace state (the editing context shared by all shells)."
  @type workspace :: MingaEditor.Session.State.t()

  @doc """
  Returns the input handler stack for this shell. Overlay handlers
  (picker, completion, conflict prompt) sit above the surface and
  intercept keys first; surface handlers (dashboard, file tree, agent
  panel, mode dispatch) handle keys when no overlay claims them.
  """
  @callback input_handlers(editor_state :: term()) ::
              %{overlay: [module()], surface: [module()]}

  @doc """
  Handle a shell-specific event (tool prompt, nav flash, git status, etc.).
  """
  @callback handle_event(shell_state(), workspace(), event :: term()) ::
              {shell_state(), workspace()}

  @doc """
  Handle a shell-specific GUI action from the native frontend.
  """
  @callback handle_gui_action(shell_state(), workspace(), action :: term()) ::
              {shell_state(), workspace()}
end
