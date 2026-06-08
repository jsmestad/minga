defmodule MingaBoard.Commands do
  @moduledoc "Board shell commands."

  alias MingaBoard.Shell
  alias MingaEditor.State, as: EditorState

  @doc "Toggles between the Board shell and the Traditional fallback shell."
  @spec toggle(EditorState.t()) :: EditorState.t()
  def toggle(state) do
    if EditorState.active_shell_id(state) == :board do
      state
      |> Shell.hide_gui_board()
      |> EditorState.switch_shell(:traditional)
    else
      EditorState.switch_shell(state, :board)
    end
  end
end
