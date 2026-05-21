defmodule MingaEditor.Shell.Traditional.Layout.TUI do
  @moduledoc """
  TUI layout computation.

  Computes screen rectangles for the Zig/libvaxis terminal frontend where
  everything is rendered in the cell grid: tab bar, file tree, editor area,
  agent panel, modeline, and minibuffer.
  """

  alias Minga.Project.FileTree
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Session.ChromeState

  # Default row where editor content starts (below the tab bar).
  @default_content_start 1
  @workspace_content_start 2
  @workspace_row_min_height 7

  # Minimum sizes and collapse priorities.
  @editor_min_cols 10
  @editor_min_rows 3
  @file_tree_min_cols 8
  @git_status_min_cols 20
  @git_status_max_cols 40
  @agent_panel_min_rows 5

  @doc """
  Computes TUI layout: optional workspace row, tab bar, file tree left, agent panel bottom, editor area in the middle, status bar at rows - 2, minibuffer at the last row.
  """
  @spec compute(EditorState.t() | map()) :: Layout.t()
  def compute(state) do
    vp = state.terminal_viewport
    terminal = {0, 0, vp.cols, vp.rows}
    content_start = content_start(state)

    # The tab_bar region covers every top-chrome row.
    # Mouse focus and regions come from BEAM layout, not Zig semantic inference.
    tab_bar_row = 0
    tab_bar_height = content_start

    # Minibuffer always takes the last row. Status bar takes the row above it,
    # but only when there's enough room (status_bar row must be above content_start).
    # At tiny terminals (< 4 rows), omit the status bar rather than overlap the editor.
    minibuffer = {vp.rows - 1, 0, vp.cols, 1}

    {status_bar, remaining_height} =
      if vp.rows - 2 > content_start do
        # Normal case: reserve 2 rows at the bottom (status bar + minibuffer).
        {{vp.rows - 2, 0, vp.cols, 1}, max(vp.rows - 2 - content_start, 1)}
      else
        # Degenerate terminal: too small for a separate status bar row.
        {nil, max(vp.rows - 1 - content_start, 1)}
      end

    # File tree takes a left column if open.
    {file_tree_rect, editor_col, editor_width} = file_tree_layout(state, vp.cols, content_start)

    # Agent panel takes a percentage of remaining height if visible.
    {agent_rect, editor_height} =
      agent_panel_layout(state, remaining_height, editor_col, editor_width, content_start)

    # Constraint satisfaction: collapse regions that don't fit.
    {file_tree_rect, agent_rect, editor_col, editor_width, editor_height} =
      apply_constraints(
        vp,
        file_tree_rect,
        agent_rect,
        editor_col,
        editor_width,
        editor_height,
        remaining_height,
        content_start
      )

    # Editor area.
    editor_area = {content_start, editor_col, editor_width, editor_height}

    # Window layouts within the editor area.
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
      tab_bar: {tab_bar_row, 0, vp.cols, tab_bar_height},
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
          MingaEditor.Viewport.t(),
          Layout.rect() | nil,
          Layout.rect() | nil,
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {Layout.rect() | nil, Layout.rect() | nil, non_neg_integer(), pos_integer(),
           non_neg_integer()}
  defp apply_constraints(
         vp,
         file_tree_rect,
         agent_rect,
         editor_col,
         editor_width,
         editor_height,
         remaining_height,
         content_start
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
        new_agent_rect = {content_start + new_editor_height, editor_col, editor_width, ah}

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

  @spec file_tree_layout(EditorState.t(), pos_integer(), non_neg_integer()) ::
          {Layout.rect() | nil, non_neg_integer(), pos_integer()}
  defp file_tree_layout(
         %{workspace: %{file_tree: %{tree: %FileTree{width: tw}}}} = state,
         total_cols,
         content_start
       ) do
    sidebar_layout(state, total_cols, tw, content_start)
  end

  defp file_tree_layout(
         %{shell_state: %{git_status_panel: %{} = _panel}} = state,
         total_cols,
         content_start
       ) do
    sidebar_layout(state, total_cols, git_status_width(total_cols), content_start)
  end

  defp file_tree_layout(_state, total_cols, _content_start) do
    {nil, 0, total_cols}
  end

  @spec sidebar_layout(EditorState.t(), pos_integer(), pos_integer(), non_neg_integer()) ::
          {Layout.rect(), non_neg_integer(), pos_integer()}
  defp sidebar_layout(state, total_cols, requested_width, content_start) do
    # Same logic as compute/1: reserve 2 rows at the bottom when possible, else 1.
    bottom_reserve = if state.terminal_viewport.rows - 2 > content_start, do: 2, else: 1
    tree_height = state.terminal_viewport.rows - content_start - bottom_reserve
    min_editor_w = 3
    max_tree_w = max(total_cols - 1 - min_editor_w, 1)
    clamped_tw = min(requested_width, max_tree_w)
    tree_rect = {content_start, 0, clamped_tw, tree_height}
    editor_col = clamped_tw + 1
    editor_width = max(total_cols - editor_col, 1)
    {tree_rect, editor_col, editor_width}
  end

  @spec git_status_width(pos_integer()) :: pos_integer()
  defp git_status_width(total_cols) do
    total_cols
    |> div(4)
    |> max(@git_status_min_cols)
    |> min(@git_status_max_cols)
  end

  # ── Agent panel ────────────────────────────────────────────────────────────

  @spec agent_panel_layout(
          EditorState.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: {Layout.rect() | nil, non_neg_integer()}
  defp agent_panel_layout(state, remaining_height, editor_col, editor_width, content_start) do
    panel = AgentAccess.panel(state)

    if panel.visible do
      panel_height = div(state.terminal_viewport.rows * 35, 100)
      editor_height = remaining_height - panel_height
      agent_row = content_start + editor_height
      agent_rect = {agent_row, editor_col, editor_width, panel_height}
      {agent_rect, editor_height}
    else
      {nil, remaining_height}
    end
  end

  # ── Workspace top chrome ───────────────────────────────────────────────────

  @spec content_start(EditorState.t() | map()) :: pos_integer()
  defp content_start(state) do
    chrome_state = ChromeState.from_editor_state(state)

    if state.terminal_viewport.rows >= @workspace_row_min_height and
         workspace_context_relevant?(chrome_state) do
      @workspace_content_start
    else
      @default_content_start
    end
  end

  @spec workspace_context_relevant?(ChromeState.t()) :: boolean()
  defp workspace_context_relevant?(%ChromeState{} = chrome_state) do
    length(chrome_state.workspaces) > 1 or chrome_state.draft_count > 0 or
      chrome_state.conflict_count > 0 or chrome_state.attention_count > 0 or
      chrome_state.background_count > 0
  end
end
