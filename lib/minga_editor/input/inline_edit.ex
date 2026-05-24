defmodule MingaEditor.Input.InlineEdit do
  @moduledoc """
  Input handler for the active inline edit overlay.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaAgent.EphemeralSession
  alias MingaEditor.Commands.InlineEdit, as: InlineEditCommand
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineEdit

  @type state :: MingaEditor.Input.Handler.handler_state()

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{buffers: %{active: buffer_pid}}} = state, codepoint, _modifiers)
      when is_pid(buffer_pid) do
    edit = state |> EditorState.inline_edits() |> InlineEdit.active(buffer_pid)

    case edit do
      %InlineEdit{} -> {:handled, handle_inline_key(state, edit, codepoint)}
      nil -> {:passthrough, state}
    end
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

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
       when status in [:proposed, :error], do: update_edit(state, InlineEdit.scroll(edit, 1))

  defp handle_inline_key(state, %InlineEdit{status: status} = edit, ?k)
       when status in [:proposed, :error], do: update_edit(state, InlineEdit.scroll(edit, -1))

  defp handle_inline_key(state, %InlineEdit{status: :input} = edit, 13), do: submit(state, edit)

  defp handle_inline_key(state, %InlineEdit{status: :input} = edit, 127),
    do: update_edit(state, InlineEdit.backspace(edit))

  defp handle_inline_key(state, %InlineEdit{status: :input} = edit, 8),
    do: update_edit(state, InlineEdit.backspace(edit))

  defp handle_inline_key(state, %InlineEdit{status: :input} = edit, codepoint)
       when codepoint >= 32 do
    update_edit(state, InlineEdit.append_input(edit, <<codepoint::utf8>>))
  end

  defp handle_inline_key(state, _edit, _codepoint), do: state

  @spec submit(state(), InlineEdit.t()) :: state()
  defp submit(state, %InlineEdit{prompt: ""}),
    do: EditorState.set_status(state, "Type a rewrite instruction first")

  defp submit(state, %InlineEdit{} = edit) do
    case EphemeralSession.rewrite(InlineEdit.agent_prompt(edit), project_root(state),
           subscriber: self()
         ) do
      {:ok, session_pid} ->
        update_edit(state, InlineEdit.thinking(edit, session_pid))

      {:error, reason} ->
        update_edit(
          state,
          InlineEdit.fail(edit, "Failed to start inline edit: #{inspect(reason)}")
        )
    end
  end

  @spec update_edit(state(), InlineEdit.t()) :: state()
  defp update_edit(state, %InlineEdit{} = edit) do
    state
    |> EditorState.inline_edits()
    |> InlineEdit.put(edit)
    |> then(&EditorState.set_inline_edits(state, &1))
  end

  @spec project_root(state()) :: String.t()
  defp project_root(state) do
    file_tree = EditorState.file_tree_state(state)
    file_tree.project_root || file_tree.original_root || File.cwd!()
  end
end
