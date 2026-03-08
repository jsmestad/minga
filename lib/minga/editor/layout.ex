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
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.FileTree

  # ── Constraints ────────────────────────────────────────────────────────────
  # Minimum sizes and collapse priorities for each region.
  # Lower priority number = collapses first when space is tight.

  @editor_min_cols 10
  @editor_min_rows 3
  @file_tree_min_cols 8
  @agent_panel_min_rows 5

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "A screen rectangle: {row, col, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc """
  Layout for a single editor window, with sub-rects for each chrome element.

  - `total` — the full window rect (from WindowTree.layout)
  - `content` — the text area within the window (total minus modeline)
  - `modeline` — one row at the bottom of the window
  """
  @type window_layout :: %{
          total: rect(),
          content: rect(),
          modeline: rect()
        }

  @typedoc "Complete layout for one frame."
  @type t :: %__MODULE__{
          terminal: rect(),
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
  """
  @spec compute(EditorState.t()) :: t()
  def compute(state) do
    vp = state.viewport
    terminal = {0, 0, vp.cols, vp.rows}

    # 1. Minibuffer always takes the last row.
    minibuffer = {vp.rows - 1, 0, vp.cols, 1}
    remaining_height = vp.rows - 1

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

    # 5. Editor area is what's left.
    editor_area = {0, editor_col, editor_width, editor_height}

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
        new_agent_rect = {new_editor_height, editor_col, editor_width, ah}

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
    # Tree occupies the full height minus the minibuffer row.
    tree_height = state.viewport.rows - 1
    # Clamp tree width so tree + separator + minimum editor width fits.
    # Minimum editor width is 3 to support vertical splits (left + separator + right).
    min_editor_w = 3
    max_tree_w = max(total_cols - 1 - min_editor_w, 1)
    clamped_tw = min(tw, max_tree_w)
    tree_rect = {0, 0, clamped_tw, tree_height}
    # Separator at column clamped_tw, editor starts at clamped_tw+1.
    # editor_col + editor_width must not exceed total_cols.
    editor_col = clamped_tw + 1
    editor_width = max(total_cols - editor_col, 1)
    {tree_rect, editor_col, editor_width}
  end

  # ── Agent panel ────────────────────────────────────────────────────────────

  @spec agent_panel_layout(EditorState.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {rect() | nil, non_neg_integer()}
  defp agent_panel_layout(
         %{agent: %{panel: %{visible: true}}} = state,
         remaining_height,
         editor_col,
         editor_width
       ) do
    panel_height = div(state.viewport.rows * 35, 100)
    editor_height = remaining_height - panel_height
    agent_rect = {editor_height, editor_col, editor_width, panel_height}
    {agent_rect, editor_height}
  end

  defp agent_panel_layout(_state, remaining_height, _editor_col, _editor_width) do
    {nil, remaining_height}
  end

  # ── Window layouts ─────────────────────────────────────────────────────────

  @spec single_window_layout(rect()) :: window_layout()
  defp single_window_layout(rect), do: subdivide_window(rect)

  @spec compute_window_layouts(WindowTree.t(), rect()) :: %{Window.id() => window_layout()}
  defp compute_window_layouts(tree, editor_area) do
    layouts = WindowTree.layout(tree, editor_area)
    Map.new(layouts, fn {win_id, rect} -> {win_id, subdivide_window(rect)} end)
  end

  # Subdivides a window rect into content and modeline sub-rects.
  # When the window is too short for both (height < 2), content gets
  # all the space and modeline collapses to zero height (hidden).
  @spec subdivide_window(rect()) :: window_layout()
  defp subdivide_window({row, col, width, height}) when height < 2 do
    %{
      total: {row, col, width, height},
      content: {row, col, width, height},
      modeline: {row + height, col, width, 0}
    }
  end

  defp subdivide_window({row, col, width, height}) do
    content_height = height - 1
    modeline_row = row + content_height

    %{
      total: {row, col, width, height},
      content: {row, col, width, content_height},
      modeline: {modeline_row, col, width, 1}
    }
  end

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
