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

    # 2. File tree takes a left column if open.
    {file_tree_rect, editor_col, editor_width} = file_tree_layout(state, vp.cols)

    # 3. Agent panel takes a percentage of remaining height if visible.
    {agent_rect, editor_height} =
      agent_panel_layout(state, remaining_height, editor_col, editor_width)

    # 4. Editor area is what's left.
    editor_area = {0, editor_col, editor_width, editor_height}

    # 5. Window layouts within the editor area.
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

  # ── File tree ──────────────────────────────────────────────────────────────

  @spec file_tree_layout(EditorState.t(), pos_integer()) ::
          {rect() | nil, non_neg_integer(), pos_integer()}
  defp file_tree_layout(%{file_tree: %{tree: nil}}, total_cols) do
    {nil, 0, total_cols}
  end

  defp file_tree_layout(%{file_tree: %{tree: %FileTree{width: tw}}} = state, total_cols) do
    # Tree occupies the full height minus the minibuffer row.
    tree_height = state.viewport.rows - 1
    tree_rect = {0, 0, tw, tree_height}
    # Separator at column tw, editor starts at tw+1
    editor_col = tw + 1
    editor_width = max(total_cols - editor_col, 1)
    {tree_rect, editor_col, editor_width}
  end

  # ── Agent panel ────────────────────────────────────────────────────────────

  @spec agent_panel_layout(EditorState.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {rect() | nil, non_neg_integer()}
  defp agent_panel_layout(%{agent: %{panel: %{visible: true}}} = state, remaining_height, editor_col, editor_width) do
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
  defp single_window_layout({row, col, width, height}) do
    # In single-window mode, modeline is the second-to-last row of the
    # editor area (last row before minibuffer). Content gets the rest.
    content_height = max(height - 1, 1)
    modeline_row = row + content_height

    %{
      total: {row, col, width, height},
      content: {row, col, width, content_height},
      modeline: {modeline_row, col, width, 1}
    }
  end

  @spec compute_window_layouts(WindowTree.t(), rect()) :: %{Window.id() => window_layout()}
  defp compute_window_layouts(tree, editor_area) do
    layouts = WindowTree.layout(tree, editor_area)

    Map.new(layouts, fn {win_id, {row, col, width, height}} ->
      content_height = max(height - 1, 1)
      modeline_row = row + content_height

      {win_id, %{
        total: {row, col, width, height},
        content: {row, col, width, content_height},
        modeline: {modeline_row, col, width, 1}
      }}
    end)
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
