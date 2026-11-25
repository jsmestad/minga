defmodule MingaEditor.Layout.GUI do
  @moduledoc """
  Shared layout for semantic frontends.

  Native chrome sits outside the reported content grid, so subtracting it here would count it twice.
  Terminal chrome shares the reported grid.
  The terminal timeline has a fixed lifetime and row budget so background writes cannot displace the composer or footer controls.
  """

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.RenderPipeline.Input, as: RenderInput
  alias MingaEditor.MinibufferData
  alias MingaEditor.Shell.Traditional.Drawers
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.Window.Content

  @timeline_rows 3
  @drawer_share 0.4
  @drawer_min_rows 4
  @editor_min_rows 3

  @doc """
  Computes content, timeline and minibuffer rectangles from the reported row grid.

  Native GUI rows already exclude native chrome, including the timeline.
  Use them unchanged and anchor the virtual minibuffer below the grid for focus routing.
  Terminal rows describe the full screen.
  Reserve one status row, a second row for a visible minibuffer, and a fixed three-row Agent timeline while an Agent body is active.
  File count never changes that reservation.
  """
  @spec compute(EditorState.t() | RenderInput.t()) :: Layout.t()
  def compute(state) do
    vp = terminal_viewport(state)
    terminal = {0, 0, vp.cols, vp.rows}
    windows = windows(state)

    native_gui? = Capabilities.gui?(capabilities(state))

    {editor_height, minibuffer} =
      if native_gui? do
        # Native minibuffer chrome lives outside the content grid; the reported
        # rows already exclude it, so the editor claims the whole viewport and
        # the minibuffer rect sits on the row directly below the content.
        {vp.rows, {vp.rows, 0, vp.cols, 1}}
      else
        # Terminal chrome owns one status row and an additional row for a visible minibuffer.
        footer_rows = if MinibufferData.visible?(state), do: 2, else: 1
        {max(vp.rows - footer_rows, 1), {vp.rows - 1, 0, vp.cols, 1}}
      end

    {editor_height, edit_timeline} =
      reserve_timeline(editor_height, vp.cols, native_gui?, windows)

    {editor_height, tasks_drawer} =
      reserve_drawer(editor_height, vp.cols, native_gui?, drawer_showing?(state))

    editor_area = {0, 0, vp.cols, editor_height}

    # All windows are no-modeline; the global SwiftUI status bar handles status display.
    # Window content is laid out only in the rows left above dedicated chrome.

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
      edit_timeline: edit_timeline,
      tasks_drawer: tasks_drawer,
      minibuffer: minibuffer
    }
  end

  @spec reserve_timeline(non_neg_integer(), pos_integer(), boolean(), map()) ::
          {non_neg_integer(), Layout.rect() | nil}
  defp reserve_timeline(height, _cols, true, _windows), do: {height, nil}

  defp reserve_timeline(height, cols, false, windows) do
    case Map.get(windows.map, windows.active) do
      %{content: content} ->
        if Content.agent_body?(content) do
          rows = min(@timeline_rows, max(height - 1, 0))
          remaining = height - rows
          rect = timeline_rect(remaining, cols, rows)
          {remaining, rect}
        else
          {height, nil}
        end

      _ ->
        {height, nil}
    end
  end

  # A drawer is a real split along the bottom (docs/design/surfaces.md "Drawers"): the terminal gives it 40% of the rows
  # above the footer, at least a header, two rows and a hint border, and never the editor's last three rows.
  # Native drawers sit outside the reported grid.
  @spec reserve_drawer(non_neg_integer(), pos_integer(), boolean(), boolean()) ::
          {non_neg_integer(), Layout.rect() | nil}
  defp reserve_drawer(height, _cols, _native_gui?, false), do: {height, nil}
  defp reserve_drawer(height, _cols, true, true), do: {height, nil}

  defp reserve_drawer(height, cols, false, true) do
    rows =
      (height * @drawer_share)
      |> round()
      |> max(@drawer_min_rows)
      |> min(height - @editor_min_rows)

    if rows > 0,
      do: {height - rows, {height - rows, 0, cols, rows}},
      else: {height, nil}
  end

  @spec drawer_showing?(EditorState.t() | RenderInput.t()) :: boolean()
  defp drawer_showing?(%EditorState{shell_runtime: %{state: %ShellState{} = shell}}),
    do: shell |> ShellState.drawers() |> Drawers.showing?(:tasks)

  defp drawer_showing?(%RenderInput{intent: %{frame: %{shell_state: %ShellState{} = shell}}}),
    do: shell |> ShellState.drawers() |> Drawers.showing?(:tasks)

  defp drawer_showing?(_state), do: false

  @spec timeline_rect(non_neg_integer(), pos_integer(), non_neg_integer()) :: Layout.rect() | nil
  defp timeline_rect(_row, _cols, 0), do: nil
  defp timeline_rect(row, cols, rows), do: {row, 0, cols, rows}

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
