defmodule Minga.Editor.Commands.UI.TUI do
  @moduledoc "TUI variant of UI commands. Panel commands are no-ops."

  @behaviour Minga.Editor.Commands.UI.Frontend

  alias Minga.Editor.State, as: EditorState

  @impl true
  @spec toggle_bottom_panel(EditorState.t()) :: EditorState.t()
  def toggle_bottom_panel(state), do: state

  @impl true
  @spec bottom_panel_next_tab(EditorState.t()) :: EditorState.t()
  def bottom_panel_next_tab(state), do: state

  @impl true
  @spec bottom_panel_prev_tab(EditorState.t()) :: EditorState.t()
  def bottom_panel_prev_tab(state), do: state
end
