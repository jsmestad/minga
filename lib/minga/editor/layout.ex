defmodule Minga.Editor.Layout do
  @moduledoc """
  Single source of truth for all screen rectangles.

  `Layout.compute/1` takes editor state and produces a struct of named
  rectangles for every UI element. The renderer never computes its own
  coordinates; it receives pre-computed rectangles and draws into them.

  ## Rectangle format

  All rectangles are `{row, col, width, height}` tuples matching the
  existing `WindowTree.rect()` type. The origin is the top-left corner
  of the allocated area.

  ## Regions vs Overlays

  **Regions** are non-overlapping areas that tile the screen: file tree,
  editor area, agent panel, modeline, minibuffer. They participate in
  the non-overlap invariant.

  **Overlays** float over regions: picker, which-key popup, completion
  menu. They have positioning rects but don't participate in the tiling
  constraint.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.FileTree
  alias Minga.Port.Capabilities

  # ── Constraints ────────────────────────────────────────────────────────────
  # Minimum sizes and collapse priorities for each region.
  # Lower priority number = collapses first when space is tight.

  @editor_min_cols 10
  @editor_min_rows 3
  @file_tree_min_cols 8
  @agent_panel_min_rows 5

  # Row where editor content starts (below the tab bar).
  @content_start 1

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "A screen rectangle: {row, col, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc """
  Layout for a single editor window, with sub-rects for each chrome element.

  - `total` — the full window rect (from WindowTree.layout)
  - `content` — the text area within the window (total minus modeline)
  - `modeline` — one row at the bottom of the window
  - `sidebar` — optional info panel (agent chat dashboard)
  """
  @type window_layout :: %{
          total: rect(),
          content: rect(),
          modeline: rect(),
          sidebar: rect() | nil
        }

  @typedoc "Complete layout for one frame."
  @type t :: %__MODULE__{
          terminal: rect(),
          tab_bar: rect() | nil,
          file_tree: rect() | nil,
          editor_area: rect(),
          window_layouts: %{Window.id() => window_layout()},
          agent_panel: rect() | nil,
          minibuffer: rect()
        }

  @enforce_keys [:terminal, :editor_area, :minibuffer]
  defstruct [
    :terminal,
    :editor_area,
    :minibuffer,
    tab_bar: nil,
    file_tree: nil,
    window_layouts: %{},
    agent_panel: nil
  ]

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Returns the cached layout from state, or computes it fresh.

  Prefer this over `compute/1` when you have a state that might already
  have a cached layout. The cache is invalidated on resize, file tree
  toggle, and agent panel toggle.
  """
  @spec get(EditorState.t()) :: t()
  def get(%{layout: %__MODULE__{} = cached}), do: cached
  def get(state), do: compute(state)

  @doc """
  Computes the layout and stores it in state for reuse within the same frame.

  Call this once at the start of a render cycle or event handler, then
  read `state.layout` downstream.
  """
  @spec put(EditorState.t()) :: EditorState.t()
  def put(state), do: %{state | layout: compute(state)}

  @doc """
  Invalidates the cached layout. Call when layout-affecting state changes
  (viewport resize, file tree toggle, agent panel toggle, window split/close).
  """
  @spec invalidate(EditorState.t()) :: EditorState.t()
  def invalidate(state), do: %{state | layout: nil}

  @doc """
  Computes the complete layout for the current frame.

  This is a pure function: given the same state, it always produces the
  same rectangles. No side effects, no GenServer calls.

  In GUI mode (`Capabilities.gui?`), the Metal viewport IS the editor
  area. SwiftUI handles tab bar, file tree sidebar, breadcrumb, and
  status bar outside the Metal view. The BEAM doesn't reserve rows or
  columns for chrome that SwiftUI renders natively.
  """
  @spec compute(EditorState.t()) :: t()
  def compute(state) do
    if Capabilities.gui?(state.capabilities) do
      compute_gui(state)
    else
      compute_tui(state)
    end
  end

  # GUI layout: Metal viewport is pure editor area.
  # No tab bar row, no file tree columns. Minibuffer stays as the bottom
  # row (: command input needs the same font/key handling as the editor).
  # Per-window modeline stays (part of vim split UX inside the Metal view).
  @spec compute_gui(EditorState.t()) :: t()
  defp compute_gui(state) do
    vp = state.viewport
    terminal = {0, 0, vp.cols, vp.rows}

    # Minibuffer takes the last row (stays in Metal for command-line input).
    minibuffer = {vp.rows - 1, 0, vp.cols, 1}
    editor_height = max(vp.rows - 1, 1)

    # Editor area is the full viewport minus the minibuffer row.
    # No tab bar row, no file tree columns, no agent panel.
    editor_area = {0, 0, vp.cols, editor_height}

    # Window layouts within the editor area.
    # In single-window GUI mode, skip the modeline row (SwiftUI status bar
    # handles it). In splits, keep modeline per window.
    window_layouts =
      if EditorState.split?(state) do
        compute_window_layouts(state.windows.tree, editor_area)
      else
        %{state.windows.active => single_window_layout_no_modeline(editor_area)}
      end

    %__MODULE__{
      terminal: terminal,
      tab_bar: nil,
      file_tree: nil,
      editor_area: editor_area,
      window_layouts: window_layouts,
      agent_panel: nil,
      minibuffer: minibuffer
    }
  end

  # TUI layout: existing behavior (Metal/Zig renders everything).
  @spec compute_tui(EditorState.t()) :: t()
  defp compute_tui(state) do
    vp = state.viewport
    terminal = {0, 0, vp.cols, vp.rows}

    # 0. Tab bar takes row 0.
    tab_bar_row = 0

    # 1. Minibuffer always takes the last row.
    minibuffer = {vp.rows - 1, 0, vp.cols, 1}
    remaining_height = max(vp.rows - 1 - @content_start, 1)

    # 2. File tree takes a left column if open (collapse if not enough space).
    {file_tree_rect, editor_col, editor_width} = file_tree_layout(state, vp.cols)

    # 3. Agent panel takes a percentage of remaining height if visible.
    {agent_rect, editor_height} =
      agent_panel_layout(state, remaining_height, editor_col, editor_width)

    # 4. Constraint satisfaction: collapse regions that don't fit.
    #    Priority order (collapse first → last): agent panel, file tree, editor (never).
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

    # 5. Editor area is what's left (starts at @content_start to leave room for tab bar).
    editor_area = {@content_start, editor_col, editor_width, editor_height}

    # 6. Window layouts within the editor area.
    window_layouts =
      if EditorState.split?(state) do
        compute_window_layouts(state.windows.tree, editor_area)
      else
        # Single window occupies the entire editor area.
        %{state.windows.active => single_window_layout(editor_area)}
      end

    %__MODULE__{
      terminal: terminal,
      tab_bar: {tab_bar_row, 0, vp.cols, 1},
      file_tree: file_tree_rect,
      editor_area: editor_area,
      window_layouts: window_layouts,
      agent_panel: agent_rect,
      minibuffer: minibuffer
    }
  end

  # ── Constraint satisfaction ─────────────────────────────────────────────────

  # Collapses regions that violate minimum size constraints.
  # Priority order: agent panel collapses first, file tree second, editor never.
  @spec apply_constraints(
          EditorState.t(),
          Minga.Editor.Viewport.t(),
          rect() | nil,
          rect() | nil,
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {rect() | nil, rect() | nil, non_neg_integer(), pos_integer(), non_neg_integer()}
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

    # Also collapse agent panel if the panel itself is too short to be useful
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

    # Step 3: Collapse file tree if the tree itself is narrower than minimum
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

    {file_tree_rect, agent_rect, editor_col, editor_width, editor_height}
  end

  # ── File tree ──────────────────────────────────────────────────────────────

  @spec file_tree_layout(EditorState.t(), pos_integer()) ::
          {rect() | nil, non_neg_integer(), pos_integer()}
  defp file_tree_layout(%{file_tree: %{tree: nil}}, total_cols) do
    {nil, 0, total_cols}
  end

  defp file_tree_layout(%{file_tree: %{tree: %FileTree{width: tw}}} = state, total_cols) do
    # Tree occupies the full height minus the minibuffer row and tab bar row.
    tree_height = state.viewport.rows - @content_start - 1
    # Clamp tree width so tree + separator + minimum editor width fits.
    # Minimum editor width is 3 to support vertical splits (left + separator + right).
    min_editor_w = 3
    max_tree_w = max(total_cols - 1 - min_editor_w, 1)
    clamped_tw = min(tw, max_tree_w)
    tree_rect = {@content_start, 0, clamped_tw, tree_height}
    # Separator at column clamped_tw, editor starts at clamped_tw+1.
    # editor_col + editor_width must not exceed total_cols.
    editor_col = clamped_tw + 1
    editor_width = max(total_cols - editor_col, 1)
    {tree_rect, editor_col, editor_width}
  end

  # ── Agent panel ────────────────────────────────────────────────────────────

  @spec agent_panel_layout(EditorState.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {rect() | nil, non_neg_integer()}
  defp agent_panel_layout(state, remaining_height, editor_col, editor_width) do
    panel = AgentAccess.panel(state)

    if panel.visible do
      panel_height = div(state.viewport.rows * 35, 100)
      editor_height = remaining_height - panel_height
      agent_row = @content_start + editor_height
      agent_rect = {agent_row, editor_col, editor_width, panel_height}
      {agent_rect, editor_height}
    else
      {nil, remaining_height}
    end
  end

  # ── Window layouts ─────────────────────────────────────────────────────────

  @spec single_window_layout(rect()) :: window_layout()
  defp single_window_layout(rect), do: subdivide_window(rect)

  # GUI single-window: content fills the entire rect, no modeline row.
  # Uses subdivide_window's height<2 path to produce a zero-height modeline,
  # then patches the content to fill the full rect.
  # No @spec: modeline height is 0, which doesn't fit rect() type.
  defp single_window_layout_no_modeline({row, col, width, height}) do
    # Start with a normal subdivision that includes modeline
    base = subdivide_window({row, col, width, height})
    # Expand content to fill the modeline row too
    %{base | content: {row, col, width, height}, modeline: {row + height, col, width, 0}}
  end

  @spec compute_window_layouts(WindowTree.t(), rect()) :: %{Window.id() => window_layout()}
  defp compute_window_layouts(tree, editor_area) do
    layouts = WindowTree.layout(tree, editor_area)
    Map.new(layouts, fn {win_id, rect} -> {win_id, subdivide_window(rect)} end)
  end

  # Subdivides a window rect into content and modeline sub-rects.
  # When the window is too short for both (height < 2), content gets
  # all the space and modeline collapses to zero height (hidden).
  # Minimum total window width before a sidebar is carved out.
  @sidebar_threshold 80
  # Preferred sidebar column count (capped at 1/3 of window width).
  @sidebar_preferred_width 28

  @spec subdivide_window(rect()) :: window_layout()
  defp subdivide_window({row, col, width, height}) when height < 2 do
    %{
      total: {row, col, width, height},
      content: {row, col, width, height},
      modeline: {row + height, col, width, 0},
      sidebar: nil
    }
  end

  defp subdivide_window({row, col, width, height}) do
    content_height = height - 1
    modeline_row = row + content_height

    %{
      total: {row, col, width, height},
      content: {row, col, width, content_height},
      modeline: {modeline_row, col, width, 1},
      sidebar: nil
    }
  end

  @doc """
  Splits a window layout's content rect to carve out a sidebar.

  Returns the layout with `content` narrowed and `sidebar` set to
  the right-hand info panel rect. Only applied when the content width
  exceeds `@sidebar_threshold`.
  """
  @spec add_sidebar(window_layout()) :: window_layout()
  def add_sidebar(%{content: {row, col, width, height}} = layout)
      when width > @sidebar_threshold do
    sw = min(@sidebar_preferred_width, div(width, 3))
    chat_w = width - sw - 1
    sidebar_col = col + chat_w + 1

    %{layout | content: {row, col, chat_w, height}, sidebar: {row, sidebar_col, sw, height}}
  end

  def add_sidebar(layout), do: layout

  # ── Queries ────────────────────────────────────────────────────────────────

  @doc "Returns the window layout for the active window, or nil."
  @spec active_window_layout(t(), EditorState.t()) :: window_layout() | nil
  def active_window_layout(%__MODULE__{window_layouts: wl}, state) do
    Map.get(wl, state.windows.active)
  end

  @doc """
  Returns the content width for the active window.

  This is useful for computing gutter width and wrap maps before rendering.
  """
  @spec active_content_width(t(), EditorState.t()) :: pos_integer()
  def active_content_width(layout, state) do
    case active_window_layout(layout, state) do
      %{content: {_r, _c, w, _h}} -> w
      nil -> layout.editor_area |> elem(2)
    end
  end

  @doc """
  Returns the content height (visible rows) for the active window.
  """
  @spec active_content_height(t(), EditorState.t()) :: pos_integer()
  def active_content_height(layout, state) do
    case active_window_layout(layout, state) do
      %{content: {_r, _c, _w, h}} -> h
      nil -> layout.editor_area |> elem(3)
    end
  end
end
