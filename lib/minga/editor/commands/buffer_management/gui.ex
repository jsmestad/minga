defmodule Minga.Editor.Commands.BufferManagement.GUI do
  @moduledoc "GUI variant of buffer management commands. Uses the bottom panel."

  @behaviour Minga.Editor.Commands.BufferManagement.Frontend

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.State, as: EditorState

  @impl true
  @spec view_messages(EditorState.t()) :: EditorState.t()
  def view_messages(state) do
    new_panel = BottomPanel.show(state.bottom_panel, :messages)
    %{state | bottom_panel: new_panel}
  end

  @impl true
  @spec view_warnings(EditorState.t()) :: EditorState.t()
  def view_warnings(state) do
    new_panel = BottomPanel.show(state.bottom_panel, :messages, :warnings)
    %{state | bottom_panel: new_panel}
  end
end
