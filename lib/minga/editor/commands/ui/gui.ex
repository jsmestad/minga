defmodule Minga.Editor.Commands.UI.GUI do
  @moduledoc "GUI variant of UI commands. Uses the bottom panel."

  @behaviour Minga.Editor.Commands.UI.Frontend

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.State, as: EditorState

  @impl true
  @spec toggle_bottom_panel(EditorState.t()) :: EditorState.t()
  def toggle_bottom_panel(state) do
    EditorState.set_bottom_panel(state, BottomPanel.toggle(EditorState.bottom_panel(state)))
  end

  @impl true
  @spec bottom_panel_next_tab(EditorState.t()) :: EditorState.t()
  def bottom_panel_next_tab(state) do
    EditorState.set_bottom_panel(state, BottomPanel.next_tab(EditorState.bottom_panel(state)))
  end

  @impl true
  @spec bottom_panel_prev_tab(EditorState.t()) :: EditorState.t()
  def bottom_panel_prev_tab(state) do
    EditorState.set_bottom_panel(state, BottomPanel.prev_tab(EditorState.bottom_panel(state)))
  end
end
