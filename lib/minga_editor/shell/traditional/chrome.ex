defmodule MingaEditor.Shell.Traditional.Chrome do
  @moduledoc """
  Chrome building for the Traditional shell.

  Dispatches to `Chrome.TUI` or `Chrome.GUI` based on the frontend's semantic
  capability. Every live frontend (macOS GUI and the Go TUI) advertises
  `semantic_ui` and takes `Chrome.GUI`; only the legacy Zig cell-grid frontend
  (no `semantic_ui`, surviving behind `MINGA_FRONTEND=zig` until #2223) takes
  `Chrome.TUI`. Both return the same `%Chrome{}` struct. The Traditional shell's
  chrome includes: tab bar, modeline/status bar, file tree sidebar, agent panel,
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

  Dispatches to `Chrome.GUI.build/4` for semantic frontends (macOS GUI, Go TUI)
  and `Chrome.TUI.build/4` for the legacy Zig cell-grid frontend.
  """
  @spec build_chrome(
          EditorState.t() | MingaEditor.RenderPipeline.Input.t(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build_chrome(state, layout, scrolls, cursor_info) do
    if MingaEditor.Frontend.semantic_ui?(state.capabilities) do
      MingaEditor.Shell.Traditional.Chrome.GUI.build(state, layout, scrolls, cursor_info)
    else
      MingaEditor.Shell.Traditional.Chrome.TUI.build(state, layout, scrolls, cursor_info)
    end
  end

  @doc "Returns Traditional-shell chrome state that is not part of the generic render-pipeline fingerprint."
  @spec chrome_fingerprint(EditorState.t() | MingaEditor.RenderPipeline.Input.t()) :: term()
  def chrome_fingerprint(state) do
    if MingaEditor.Frontend.semantic_ui?(state.capabilities) do
      nil
    else
      state.shell_state |> Map.get(:git_status_tui_state)
    end
  end
end
