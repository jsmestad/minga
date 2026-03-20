defmodule Minga.Editor.Commands.UI.Frontend do
  @moduledoc """
  Behaviour for GUI/TUI variant dispatch of UI commands.

  Commands that interact with GUI chrome (bottom panel, native pickers)
  implement this behaviour in both `UI.GUI` and `UI.TUI` submodules.
  The parent `UI` module dispatches based on `Capabilities.gui?`.
  """

  alias Minga.Editor.State, as: EditorState

  @callback toggle_bottom_panel(EditorState.t()) :: EditorState.t()
  @callback bottom_panel_next_tab(EditorState.t()) :: EditorState.t()
  @callback bottom_panel_prev_tab(EditorState.t()) :: EditorState.t()
end
