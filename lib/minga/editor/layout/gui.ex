defmodule Minga.Editor.Layout.GUI do
  @moduledoc """
  GUI layout computation.

  Computes screen rectangles for the Metal/SwiftUI frontend. The Metal
  viewport is pure editor area. SwiftUI handles tab bar, file tree, breadcrumb,
  and status bar outside the Metal view. The BEAM doesn't reserve rows or
  columns for chrome that SwiftUI renders natively.
  """

  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState

  @doc """
  Computes GUI layout: Metal viewport is editor area plus one minibuffer row.
  No tab bar, no file tree columns, no agent panel.
  """
  @spec compute(EditorState.t()) :: Layout.t()
  def compute(state) do
    vp = state.viewport
    terminal = {0, 0, vp.cols, vp.rows}

    # Minibuffer takes the last row (stays in Metal for command-line input).
    minibuffer = {vp.rows - 1, 0, vp.cols, 1}
    editor_height = max(vp.rows - 1, 1)

    # Editor area is the full viewport minus the minibuffer row.
    editor_area = {0, 0, vp.cols, editor_height}

    # All windows are no-modeline; the global SwiftUI status bar handles status display.
    {window_layouts, horizontal_separators} =
      if EditorState.split?(state) do
        Layout.compute_window_layouts_with_separators(
          state.windows.tree,
          editor_area,
          state.windows.map
        )
      else
        {%{state.windows.active => Layout.subdivide_window(editor_area)}, []}
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
end
