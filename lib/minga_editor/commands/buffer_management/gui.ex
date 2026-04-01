defmodule MingaEditor.Commands.BufferManagement.GUI do
  @moduledoc "GUI variant of buffer management commands. Uses the bottom panel."

  @behaviour MingaEditor.Commands.BufferManagement.Frontend

  alias MingaEditor.BottomPanel
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec view_messages(EditorState.t()) :: EditorState.t()
  def view_messages(state) do
    new_panel = BottomPanel.show(EditorState.bottom_panel(state), :messages)
    EditorState.set_bottom_panel(state, new_panel)
  end

  @impl true
  @spec view_warnings(EditorState.t()) :: EditorState.t()
  def view_warnings(state) do
    new_panel = BottomPanel.show(EditorState.bottom_panel(state), :messages, :warnings)
    EditorState.set_bottom_panel(state, new_panel)
  end
end
