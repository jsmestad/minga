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
  alias Minga.Port.Capabilities

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
      __MODULE__.GUI.compute(state)
    else
      __MODULE__.TUI.compute(state)
    end
  end

  # ── Shared helpers (used by Layout.TUI and Layout.GUI) ─────────────────────

  @doc false
  @spec compute_window_layouts(WindowTree.t(), rect()) :: %{Window.id() => window_layout()}
  def compute_window_layouts(tree, editor_area) do
    layouts = WindowTree.layout(tree, editor_area)
    Map.new(layouts, fn {win_id, rect} -> {win_id, subdivide_window(rect)} end)
  end

  @doc false
  @spec subdivide_window(rect()) :: window_layout()
  def subdivide_window({row, col, width, height}) when height < 2 do
    %{
      total: {row, col, width, height},
      content: {row, col, width, height},
      modeline: {row + height, col, width, 0},
      sidebar: nil
    }
  end

  def subdivide_window({row, col, width, height}) do
    content_height = height - 1
    modeline_row = row + content_height

    %{
      total: {row, col, width, height},
      content: {row, col, width, content_height},
      modeline: {modeline_row, col, width, 1},
      sidebar: nil
    }
  end

  @doc false
  @spec single_window_layout_no_modeline(rect()) :: map()
  def single_window_layout_no_modeline({row, col, width, height}) do
    base = subdivide_window({row, col, width, height})
    %{base | content: {row, col, width, height}, modeline: {row + height, col, width, 0}}
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
