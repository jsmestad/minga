defmodule MingaEditor.Shell.Traditional.Layout.TUI do
  @moduledoc """
  TUI layout computation.

  Computes screen rectangles for the Zig/libvaxis terminal frontend where
  everything is rendered in the cell grid: tab bar, file tree, editor area,
  agent panel, modeline, and minibuffer.
  """

  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias Minga.Project.FileTree

  # Row where editor content starts (below the tab bar).
  @content_start 1

  # Minimum sizes and collapse priorities.
  @editor_min_cols 10
  @editor_min_rows 3
  @file_tree_min_cols 8
  @agent_panel_min_rows 5

  @doc """
  Computes TUI layout: tab bar at row 0, file tree left, agent panel bottom,
  editor area in the middle, status bar at rows - 2, minibuffer at the last row.
  """
  @spec compute(EditorState.t() | map()) :: Layout.t()
  def compute(state) do
    vp = state.workspace.viewport
    terminal = {0, 0, vp.cols, vp.rows}

    # 0. Tab bar takes row 0.
    tab_bar_row = 0

    # 1. Minibuffer always takes the last row. Status bar takes the row above it,
    # but only when there's enough room (status_bar row must be above content_start).
    # At tiny terminals (< 4 rows), omit the status bar rather than overlap the editor.
    minibuffer = {vp.rows - 1, 0, vp.cols, 1}

    {status_bar, remaining_height} =
      if vp.rows - 2 > @content_start do
        # Normal case: reserve 2 rows at the bottom (status bar + minibuffer).
        {{vp.rows - 2, 0, vp.cols, 1}, max(vp.rows - 2 - @content_start, 1)}
      else
        # Degenerate terminal: too small for a separate status bar row.
        {nil, max(vp.rows - 1 - @content_start, 1)}
      end

    # 2. File tree takes a left column if open.
    {file_tree_rect, editor_col, editor_width} = file_tree_layout(state, vp.cols)

    # 3. Agent panel takes a percentage of remaining height if visible.
    {agent_rect, editor_height} =
      agent_panel_layout(state, remaining_height, editor_col, editor_width)

    # 4. Constraint satisfaction: collapse regions that don't fit.
    {file_tree_rect, agent_rect, editor_col, editor_width, editor_height} =
      apply_constraints(
        state,
        vp,
        file_tree_rect,
        agent_rect,
        editor_col,
        editor_width,
        editor_height,
        remaining_height
      )

    # 5. Editor area.
    editor_area = {@content_start, editor_col, editor_width, editor_height}

    # 6. Window layouts within the editor area.
    {window_layouts, horizontal_separators} =
      if MingaEditor.State.Windows.split?(state.workspace.windows) do
        Layout.compute_window_layouts_with_separators(
          state.workspace.windows.tree,
          editor_area,
          state.workspace.windows.map
        )
      else
        {%{state.workspace.windows.active => Layout.subdivide_window(editor_area)}, []}
      end

    %Layout{
      terminal: terminal,
      tab_bar: {tab_bar_row, 0, vp.cols, 1},
      file_tree: file_tree_rect,
      editor_area: editor_area,
      window_layouts: window_layouts,
      horizontal_separators: horizontal_separators,
      agent_panel: agent_rect,
      status_bar: status_bar,
      minibuffer: minibuffer
    }
  end

  # ── Constraint satisfaction ─────────────────────────────────────────────────

  @spec apply_constraints(
          EditorState.t(),
          MingaEditor.Viewport.t(),
          Layout.rect() | nil,
          Layout.rect() | nil,
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {Layout.rect() | nil, Layout.rect() | nil, non_neg_integer(), pos_integer(),
           non_neg_integer()}
  defp apply_constraints(
         _state,
         vp,
         file_tree_rect,
         agent_rect,
         editor_col,
         editor_width,
         editor_height,
         remaining_height
       ) do
    # Step 1: Collapse agent panel if editor height is too small
    {agent_rect, editor_height} =
      if agent_rect != nil and editor_height < @editor_min_rows do
        {nil, remaining_height}
      else
        {agent_rect, editor_height}
      end

    {agent_rect, editor_height} =
      if agent_rect != nil and elem(agent_rect, 3) < @agent_panel_min_rows do
        {nil, remaining_height}
      else
        {agent_rect, editor_height}
      end

    # Step 2: Collapse file tree if editor width is too small
    {file_tree_rect, editor_col, editor_width} =
      if file_tree_rect != nil and editor_width < @editor_min_cols do
        {nil, 0, vp.cols}
      else
        {file_tree_rect, editor_col, editor_width}
      end

    # Step 3: Collapse file tree if narrower than minimum
    {file_tree_rect, editor_col, editor_width} =
      if file_tree_rect != nil and elem(file_tree_rect, 2) < @file_tree_min_cols do
        {nil, 0, vp.cols}
      else
        {file_tree_rect, editor_col, editor_width}
      end

    # Step 4: If we collapsed the file tree, recompute agent panel with full width
    {agent_rect, editor_height} =
      if agent_rect != nil do
        {_ar, _ac, _aw, ah} = agent_rect
        new_editor_height = remaining_height - ah
        new_agent_rect = {@content_start + new_editor_height, editor_col, editor_width, ah}

        if new_editor_height < @editor_min_rows do
          {nil, remaining_height}
        else
          {new_agent_rect, new_editor_height}
        end
      else
        {agent_rect, editor_height}
      end

    # Final clamp: ensure editor area never has zero dimensions.
    # When the terminal is too small for all regions (even after collapsing
    # panels), clamp to minimums so Window.resize and the render pipeline
    # don't receive impossible values.
    editor_width = max(editor_width, 1)
    editor_height = max(editor_height, 1)

    {file_tree_rect, agent_rect, editor_col, editor_width, editor_height}
  end

  # ── File tree ──────────────────────────────────────────────────────────────

  @spec file_tree_layout(EditorState.t(), pos_integer()) ::
          {Layout.rect() | nil, non_neg_integer(), pos_integer()}
  defp file_tree_layout(%{workspace: %{file_tree: %{tree: nil}}}, total_cols) do
    {nil, 0, total_cols}
  end

  defp file_tree_layout(
         %{workspace: %{file_tree: %{tree: %FileTree{width: tw}}}} = state,
         total_cols
       ) do
    # Same logic as compute/1: reserve 2 rows at the bottom when possible, else 1.
    bottom_reserve = if state.workspace.viewport.rows - 2 > @content_start, do: 2, else: 1
    tree_height = state.workspace.viewport.rows - @content_start - bottom_reserve
    min_editor_w = 3
    max_tree_w = max(total_cols - 1 - min_editor_w, 1)
    clamped_tw = min(tw, max_tree_w)
    tree_rect = {@content_start, 0, clamped_tw, tree_height}
    editor_col = clamped_tw + 1
    editor_width = max(total_cols - editor_col, 1)
    {tree_rect, editor_col, editor_width}
  end

  # ── Agent panel ────────────────────────────────────────────────────────────

  @spec agent_panel_layout(EditorState.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {Layout.rect() | nil, non_neg_integer()}
  defp agent_panel_layout(state, remaining_height, editor_col, editor_width) do
    panel = AgentAccess.panel(state)

    if panel.visible do
      panel_height = div(state.workspace.viewport.rows * 35, 100)
      editor_height = remaining_height - panel_height
      agent_row = @content_start + editor_height
      agent_rect = {agent_row, editor_col, editor_width, panel_height}
      {agent_rect, editor_height}
    else
      {nil, remaining_height}
    end
  end
end
