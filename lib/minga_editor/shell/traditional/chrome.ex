defmodule MingaEditor.Shell.Traditional.Chrome do
  @moduledoc """
  Chrome building for the Traditional shell.

  Dispatches to `Chrome.TUI` or `Chrome.GUI` based on frontend capabilities.
  Both return the same `%Chrome{}` struct. The Traditional shell's chrome
  includes: tab bar, modeline/status bar, file tree sidebar, agent panel,
  which-key popup, completion menu, signature help, and hover popups.
  """

  alias MingaEditor.DisplayList.Cursor
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  @doc """
  Builds all non-content UI draws for the Traditional shell.

  Dispatches to `Chrome.TUI.build/4` or `Chrome.GUI.build/4` based on
  frontend capabilities.
  """
  @spec build_chrome(
          EditorState.t() | MingaEditor.RenderPipeline.Input.t(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build_chrome(state, layout, scrolls, cursor_info) do
    if MingaEditor.Frontend.gui?(state.capabilities) do
      MingaEditor.Shell.Traditional.Chrome.GUI.build(state, layout, scrolls, cursor_info)
    else
      MingaEditor.Shell.Traditional.Chrome.TUI.build(state, layout, scrolls, cursor_info)
    end
  end
end
