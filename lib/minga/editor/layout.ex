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

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree

  # Minimum total window width before a sidebar is carved out.
  @sidebar_threshold 80
  # Preferred sidebar column count (capped at 1/3 of window width).
  @sidebar_preferred_width 28

  # ── Types ──────────────────────────────────────────────────────────────────

  @typedoc "A screen rectangle: {row, col, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc """
  Layout for a single editor window, with sub-rects for each chrome element.

  - `total` — the full window rect (from WindowTree.layout)
  - `content` — the text area within the window (full window; no per-window modeline)
  - `modeline` — always zero-height; kept for backward compatibility. The global status bar
    at `Layout.t().status_bar` replaces per-window modelines.
  - `sidebar` — optional info panel (agent chat dashboard)
  """
  @type window_layout :: %{
          total: rect(),
          content: rect(),
          modeline: {non_neg_integer(), non_neg_integer(), pos_integer(), 0},
          sidebar: rect() | nil
        }

  @typedoc "A horizontal separator between split panes: {row, col, width, filename}."
  @type horizontal_separator :: {non_neg_integer(), non_neg_integer(), pos_integer(), String.t()}

  @typedoc "Complete layout for one frame."
  @type t :: %__MODULE__{
          terminal: rect(),
          tab_bar: rect() | nil,
          file_tree: rect() | nil,
          editor_area: rect(),
          window_layouts: %{Window.id() => window_layout()},
          horizontal_separators: [horizontal_separator()],
          agent_panel: rect() | nil,
          status_bar: rect() | nil,
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
    horizontal_separators: [],
    agent_panel: nil,
    status_bar: nil
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
  def put(%{shell: shell} = state), do: %{state | layout: shell.compute_layout(state)}

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

  In GUI mode (`Minga.Frontend.gui?`), the Metal viewport IS the editor
  area. SwiftUI handles tab bar, file tree sidebar, breadcrumb, and
  status bar outside the Metal view. The BEAM doesn't reserve rows or
  columns for chrome that SwiftUI renders natively.
  """
  @spec compute(EditorState.t()) :: t()
  def compute(state) do
    if Minga.Frontend.gui?(state.capabilities) do
      __MODULE__.GUI.compute(state)
    else
      __MODULE__.TUI.compute(state)
    end
  end

  # ── Shared helpers (used by Layout.TUI and Layout.GUI) ─────────────────────

  @doc """
  Computes window layouts and horizontal separator positions simultaneously.

  Horizontal splits steal 1 row from the top window for a separator bar.
  The separator shows the lower window's buffer filename.

  Returns `{window_layouts_map, horizontal_separators_list}`.
  """
  @spec compute_window_layouts_with_separators(WindowTree.t(), rect(), map()) ::
          {%{Window.id() => window_layout()}, [horizontal_separator()]}
  def compute_window_layouts_with_separators(tree, editor_area, window_map) do
    {layout_pairs, separators} = layout_with_separators(tree, editor_area, window_map)

    window_layouts =
      Map.new(layout_pairs, fn {win_id, rect} -> {win_id, subdivide_window(rect)} end)

    {window_layouts, separators}
  end

  # Recursively computes window rects and separator positions.
  # Horizontal splits steal 1 row from the top child for the separator.
  @spec layout_with_separators(WindowTree.t(), rect(), map()) ::
          {[{Window.id(), rect()}], [horizontal_separator()]}
  defp layout_with_separators({:leaf, id}, rect, _window_map) do
    {[{id, rect}], []}
  end

  defp layout_with_separators(
         {:split, :vertical, left, right, size},
         {row, col, width, height},
         window_map
       ) do
    usable = width - 1
    left_width = WindowTree.clamp_size(size, usable)
    right_width = max(usable - left_width, 1)
    separator_col = col + left_width

    {left_layouts, left_seps} =
      layout_with_separators(left, {row, col, left_width, height}, window_map)

    {right_layouts, right_seps} =
      layout_with_separators(right, {row, separator_col + 1, right_width, height}, window_map)

    {left_layouts ++ right_layouts, left_seps ++ right_seps}
  end

  defp layout_with_separators(
         {:split, :horizontal, top, bottom, size},
         {row, col, width, height},
         window_map
       ) do
    top_height = WindowTree.clamp_size(size, height)
    # Steal 1 row from the top child for the separator. Floor at 0 (not 1) so
    # degenerate tiny terminals don't get a negative or inflated top height.
    adjusted_top_height = max(top_height - 1, 0)
    sep_row = row + adjusted_top_height
    bottom_height = max(height - top_height, 1)

    {top_layouts, top_seps} =
      layout_with_separators(top, {row, col, width, adjusted_top_height}, window_map)

    {bottom_layouts, bottom_seps} =
      layout_with_separators(bottom, {row + top_height, col, width, bottom_height}, window_map)

    # The separator label is the lower window's buffer filename.
    bottom_name = first_window_filename(bottom, window_map)
    separator = {sep_row, col, width, bottom_name}

    {top_layouts ++ bottom_layouts, [separator | top_seps] ++ bottom_seps}
  end

  # Returns the display filename of the first (top-left) leaf in a subtree.
  # Uses BufferServer.display_name/1 which handles named buffers (e.g. *Messages*)
  # and the [RO] suffix in a single round-trip.
  @spec first_window_filename(WindowTree.t(), map()) :: String.t()
  defp first_window_filename({:leaf, id}, window_map) do
    case Map.get(window_map, id) do
      %{buffer: buf} when is_pid(buf) ->
        try do
          BufferServer.display_name(buf)
        catch
          :exit, _ -> "[no file]"
        end

      _ ->
        "[no file]"
    end
  end

  defp first_window_filename({:split, _, left, _right, _size}, window_map) do
    first_window_filename(left, window_map)
  end

  @doc false
  @spec subdivide_window(rect()) :: window_layout()
  def subdivide_window({row, col, width, height}) do
    %{
      total: {row, col, width, height},
      content: {row, col, width, height},
      modeline: {row + height, col, width, 0},
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
    Map.get(wl, state.workspace.windows.active)
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
