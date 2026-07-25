defmodule MingaEditor.Layout.GUI do
  @moduledoc """
  GUI layout computation.

  Computes screen rectangles for the Metal/SwiftUI frontend. The Metal
  viewport is pure editor area. SwiftUI handles tab bar, file tree, breadcrumb,
  and status bar outside the Metal view. The BEAM doesn't reserve rows or
  columns for chrome that SwiftUI renders natively.
  """

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.RenderPipeline.Input, as: RenderInput

  @doc """
  Computes GUI layout: no tab bar, no file tree columns, no agent panel.

  Row accounting for the minibuffer depends on what the frontend's reported
  rows already exclude:

  * Native GUI (`Capabilities.gui?/1`): the Metal viewport measures the content
    area only. The status bar and minibuffer are native SwiftUI chrome rendered
    outside the Metal surface, so the reported rows already exclude them.
    Reserving a grid row here would double-book the minibuffer and drop a content
    row (#2693), so the editor fills the full viewport and the minibuffer rect is
    anchored just below the content grid for server-side cursor/focus routing.
  * Terminal frontends (`:tui`, the default): the reported rows are the full
    terminal grid, so the minibuffer genuinely consumes the last row and must be
    reserved.
  """
  @spec compute(EditorState.t() | RenderInput.t()) :: Layout.t()
  def compute(state) do
    vp = terminal_viewport(state)
    terminal = {0, 0, vp.cols, vp.rows}

    native_gui? = Capabilities.gui?(capabilities(state))

    {editor_height, minibuffer} =
      if native_gui? do
        # Native minibuffer chrome lives outside the content grid; the reported
        # rows already exclude it, so the editor claims the whole viewport and
        # the minibuffer rect sits on the row directly below the content.
        {vp.rows, {vp.rows, 0, vp.cols, 1}}
      else
        # Terminal grid: the minibuffer occupies the last real row.
        {max(vp.rows - 1, 1), {vp.rows - 1, 0, vp.cols, 1}}
      end

    editor_area = {0, 0, vp.cols, editor_height}

    # All windows are no-modeline; the global SwiftUI status bar handles status display.
    windows = windows(state)

    {window_layouts, horizontal_separators} =
      if MingaEditor.State.Windows.split?(windows) do
        Layout.compute_window_layouts_with_separators(windows.tree, editor_area, windows.map)
      else
        {%{windows.active => Layout.subdivide_window(editor_area)}, []}
      end

    %Layout{
      terminal: terminal,
      tab_bar: nil,
      file_tree: nil,
      editor_area: editor_area,
      window_layouts: window_layouts,
      horizontal_separators: horizontal_separators,
      agent_panel: nil,
      status_bar: nil,
      minibuffer: minibuffer
    }
  end

  @spec terminal_viewport(EditorState.t() | RenderInput.t()) :: MingaEditor.Viewport.t()
  defp terminal_viewport(%EditorState{frontend: %{terminal_viewport: viewport}}), do: viewport

  defp terminal_viewport(%RenderInput{intent: %{frame: %{terminal_viewport: viewport}}}),
    do: viewport

  @spec capabilities(EditorState.t() | RenderInput.t()) :: Capabilities.t()
  defp capabilities(%EditorState{frontend: %{capabilities: %Capabilities{} = caps}}), do: caps

  defp capabilities(%RenderInput{intent: %{frame: %{capabilities: %Capabilities{} = caps}}}),
    do: caps

  defp windows(%EditorState{workspace: %{windows: windows}}), do: windows
  defp windows(%RenderInput{windows: windows}), do: windows
end
