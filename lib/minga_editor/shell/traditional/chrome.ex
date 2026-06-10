defmodule MingaEditor.Shell.Traditional.Chrome do
  @moduledoc """
  Chrome building for the Traditional shell.

  Builds the semantic chrome via `Chrome.GUI`. Every live frontend (macOS GUI
  and the Go TUI) advertises `semantic_ui`, and the legacy Zig cell-grid
  frontend has been retired (#2223), so the semantic builder is the only path.
  The Traditional shell's chrome includes: tab bar, modeline/status bar, file
  tree sidebar, agent panel, which-key popup, completion menu, signature help,
  and hover popups.
  """

  alias MingaEditor.DisplayList.Cursor
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window

  @doc """
  Builds all non-content UI draws for the Traditional shell via `Chrome.GUI.build/4`.
  """
  @spec build_chrome(
          EditorState.t() | MingaEditor.RenderPipeline.Input.t(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build_chrome(state, layout, scrolls, cursor_info) do
    MingaEditor.Shell.Traditional.Chrome.GUI.build(state, layout, scrolls, cursor_info)
  end

  @doc "Returns Traditional-shell chrome state that is not part of the generic render-pipeline fingerprint."
  @spec chrome_fingerprint(EditorState.t() | MingaEditor.RenderPipeline.Input.t()) :: term()
  def chrome_fingerprint(_state), do: nil
end
