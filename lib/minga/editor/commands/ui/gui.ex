defmodule Minga.Editor.Commands.UI.GUI do
  @moduledoc "GUI variant of UI commands. Uses the bottom panel."

  @behaviour Minga.Editor.Commands.UI.Frontend

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.State, as: EditorState

  @impl true
  @spec toggle_bottom_panel(EditorState.t()) :: EditorState.t()
  def toggle_bottom_panel(state) do
    %{state | bottom_panel: BottomPanel.toggle(state.bottom_panel)}
  end

  @impl true
  @spec bottom_panel_next_tab(EditorState.t()) :: EditorState.t()
  def bottom_panel_next_tab(state) do
    %{state | bottom_panel: BottomPanel.next_tab(state.bottom_panel)}
  end

  @impl true
  @spec bottom_panel_prev_tab(EditorState.t()) :: EditorState.t()
  def bottom_panel_prev_tab(state) do
    %{state | bottom_panel: BottomPanel.prev_tab(state.bottom_panel)}
  end
end
