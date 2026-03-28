defmodule Minga.Shell.Traditional.Chrome do
  @moduledoc """
  Chrome building for the Traditional shell.

  Dispatches to `Chrome.TUI` or `Chrome.GUI` based on frontend capabilities.
  Both return the same `%Chrome{}` struct. The Traditional shell's chrome
  includes: tab bar, modeline/status bar, file tree sidebar, agent panel,
  which-key popup, completion menu, signature help, and hover popups.
  """

  alias Minga.Editor.DisplayList.Cursor
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window

  @doc """
  Builds all non-content UI draws for the Traditional shell.

  Dispatches to `Chrome.TUI.build/4` or `Chrome.GUI.build/4` based on
  frontend capabilities.
  """
  @spec build_chrome(
          EditorState.t(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build_chrome(state, layout, scrolls, cursor_info) do
    if Minga.Frontend.gui?(state.capabilities) do
      Minga.Shell.Traditional.Chrome.GUI.build(state, layout, scrolls, cursor_info)
    else
      Minga.Shell.Traditional.Chrome.TUI.build(state, layout, scrolls, cursor_info)
    end
  end
end
