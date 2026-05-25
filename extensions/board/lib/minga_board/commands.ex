defmodule MingaBoard.Commands do
  @moduledoc "Board shell commands."

  alias MingaEditor.State, as: EditorState

  @doc "Toggles between the Board shell and the Traditional fallback shell."
  @spec toggle(EditorState.t()) :: EditorState.t()
  def toggle(state) do
    if EditorState.active_shell_id(state) == :board do
      EditorState.switch_shell(state, :traditional)
    else
      EditorState.switch_shell(state, :board)
    end
  end
end
