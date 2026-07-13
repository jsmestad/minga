defmodule MingaEditor.Input.InlineEdit do
  @moduledoc """
  Input handler for the active inline edit overlay.

  This is the edit variant adapter over the shared
  `MingaEditor.Input.InlineOverlay` plumbing: it supplies the store
  accessor/setter and the edit-specific key table (Esc/n reject, y/Enter
  accept, j/k scroll), and delegates the active lookup, submit, and prompt
  editing to the framework. Accept and reject route through
  `MingaEditor.Commands.InlineEdit`.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaAgent.EphemeralSession
  alias MingaEditor.Commands.InlineEdit, as: InlineEditCommand
  alias MingaEditor.Input.InlineOverlay, as: Overlay
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.InlineEdit

  @type state :: MingaEditor.Input.Handler.handler_state()

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, _modifiers) do
    case Overlay.active(state, spec()) do
      %InlineEdit{} = edit -> {:handled, handle_inline_key(state, edit, codepoint)}
      nil -> {:passthrough, state}
    end
  end

  @impl true
  @spec handle_mouse(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _cc), do: {:passthrough, state}

  @spec handle_inline_key(state(), InlineEdit.t(), non_neg_integer()) :: state()
  defp handle_inline_key(state, edit, 27), do: InlineEditCommand.reject(state, edit)
  defp handle_inline_key(state, edit, ?n), do: InlineEditCommand.reject(state, edit)

  defp handle_inline_key(state, %InlineEdit{status: :proposed} = edit, 13),
    do: InlineEditCommand.accept(state, edit)

  defp handle_inline_key(state, %InlineEdit{status: :proposed} = edit, ?y),
    do: InlineEditCommand.accept(state, edit)

  defp handle_inline_key(state, %InlineEdit{status: status} = edit, ?j)
       when status in [:proposed, :error],
       do: Overlay.update(state, InlineEdit.scroll(edit, 1), spec())

  defp handle_inline_key(state, %InlineEdit{status: status} = edit, ?k)
       when status in [:proposed, :error],
       do: Overlay.update(state, InlineEdit.scroll(edit, -1), spec())

  defp handle_inline_key(state, %InlineEdit{status: :input} = edit, 13),
    do: Overlay.submit(state, edit, "Type a rewrite instruction first", spec())

  defp handle_inline_key(state, %InlineEdit{status: :input} = edit, 127),
    do: Overlay.backspace(state, edit, spec())

  defp handle_inline_key(state, %InlineEdit{status: :input} = edit, 8),
    do: Overlay.backspace(state, edit, spec())

  defp handle_inline_key(state, %InlineEdit{status: :input} = edit, codepoint)
       when codepoint >= 32,
       do: Overlay.append_printable(state, edit, codepoint, 0, spec())

  defp handle_inline_key(state, _edit, _codepoint), do: state

  @spec spec() :: Overlay.spec()
  defp spec do
    %{
      store: &AgentAccess.inline_edits/1,
      replace: &AgentAccess.replace_inline_edit/2,
      cancel: &AgentAccess.cancel_inline_edit/2,
      state_module: InlineEdit,
      session_starter: &EphemeralSession.rewrite/3,
      fail_prefix: "Failed to start inline edit: "
    }
  end
end
