defmodule Minga.Editor.WindowTree do
  @moduledoc """
  A binary tree representing the spatial layout of editor windows.

  Each leaf is a window id. Each branch is a horizontal or vertical split
  containing two subtrees. The tree is used to compute screen regions for
  each window and to navigate between them directionally.

  ## Structure

      {:leaf, window_id}
      {:split, :vertical, left_tree, right_tree}
      {:split, :horizontal, top_tree, bottom_tree}

  Vertical splits produce side-by-side panes. Horizontal splits produce
  stacked panes.
  """

  alias Minga.Editor.Window

  @typedoc "Split direction."
  @type direction :: :vertical | :horizontal

  @typedoc "A screen rectangle: {row, col, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @typedoc """
  The tree structure.

  Split nodes carry a `size` — the number of columns (vertical) or rows
  (horizontal) allocated to the first child. The second child gets the
  remainder minus any separator. A size of 0 means "split evenly" and is
  resolved during layout.
  """
  @type t :: {:leaf, Window.id()} | {:split, direction(), t(), t(), non_neg_integer()}

  @typedoc "Navigation direction for focus movement."
  @type nav_direction :: :left | :right | :up | :down

  # ── Construction ──────────────────────────────────────────────────────────

  @doc "Creates a tree with a single window."
  @spec new(Window.id()) :: t()
  def new(id) when is_integer(id) and id > 0 do
    {:leaf, id}
  end

  @doc """
  Splits the leaf containing `window_id` in the given direction.

  The existing window stays in the first position (left/top) and
  the new window takes the second position (right/bottom).

  Returns `{:ok, new_tree}` or `:error` if `window_id` is not found.
  """
  @spec split(t(), Window.id(), direction(), Window.id()) :: {:ok, t()} | :error
  def split(tree, target_id, direction, new_id)
      when direction in [:vertical, :horizontal] and
             is_integer(target_id) and is_integer(new_id) do
    case do_split(tree, target_id, direction, new_id) do
      {:ok, _} = result -> result
      :not_found -> :error
    end
  end

  defp do_split({:leaf, id}, id, direction, new_id) do
    {:ok, {:split, direction, {:leaf, id}, {:leaf, new_id}, 0}}
  end

  defp do_split({:leaf, _other}, _target, _dir, _new_id), do: :not_found

  defp do_split({:split, dir, left, right, ratio}, target, split_dir, new_id) do
    case do_split(left, target, split_dir, new_id) do
      {:ok, new_left} ->
        {:ok, {:split, dir, new_left, right, ratio}}

      :not_found ->
        case do_split(right, target, split_dir, new_id) do
          {:ok, new_right} -> {:ok, {:split, dir, left, new_right, ratio}}
          :not_found -> :not_found
        end
    end
  end

  # ── Removal ───────────────────────────────────────────────────────────────

  @doc """
  Removes the leaf containing `window_id` from the tree.

  The sibling subtree takes the removed node's place. Returns `:error` if
  the tree is a single leaf (cannot close the last window) or if the id
  is not found.
  """
  @spec close(t(), Window.id()) :: {:ok, t()} | :error
  def close({:leaf, _id}, _target), do: :error

  def close({:split, _dir, _left, _right, _ratio} = tree, target) do
    case do_close(tree, target) do
      {:ok, _} = result -> result
      :not_found -> :error
    end
  end

  defp do_close({:leaf, _}, _target), do: :not_found

  defp do_close({:split, _dir, {:leaf, id}, right, _ratio}, id), do: {:ok, right}
  defp do_close({:split, _dir, left, {:leaf, id}, _ratio}, id), do: {:ok, left}

  defp do_close({:split, dir, left, right, ratio}, target) do
    case do_close(left, target) do
      {:ok, new_left} ->
        {:ok, {:split, dir, new_left, right, ratio}}

      :not_found ->
        case do_close(right, target) do
          {:ok, new_right} -> {:ok, {:split, dir, left, new_right, ratio}}
          :not_found -> :not_found
        end
    end
  end

  # ── Querying ──────────────────────────────────────────────────────────────

  @doc "Returns all window ids in the tree, left-to-right / top-to-bottom order."
  @spec leaves(t()) :: [Window.id()]
  def leaves({:leaf, id}), do: [id]
  def leaves({:split, _dir, left, right, _ratio}), do: leaves(left) ++ leaves(right)

  @doc "Returns the number of leaves (windows) in the tree."
  @spec count(t()) :: pos_integer()
  def count({:leaf, _}), do: 1
  def count({:split, _dir, left, right, _ratio}), do: count(left) + count(right)

  @doc "Returns true if the given window id exists in the tree."
  @spec member?(t(), Window.id()) :: boolean()
  def member?({:leaf, id}, id), do: true
  def member?({:leaf, _}, _target), do: false

  def member?({:split, _dir, left, right, _ratio}, target),
    do: member?(left, target) or member?(right, target)

  # ── Layout ────────────────────────────────────────────────────────────────

  @doc """
  Computes the screen rectangle for each leaf window.

  Given the total available rect `{row, col, width, height}`, recursively
  splits the space according to the tree structure. Vertical splits divide
  width (with 1 column reserved for the separator). Horizontal splits
  divide height.

  Returns a list of `{window_id, {row, col, width, height}}`.
  """
  @spec layout(t(), rect()) :: [{Window.id(), rect()}]
  def layout(tree, rect)

  def layout({:leaf, id}, rect), do: [{id, rect}]

  def layout({:split, :vertical, left, right, size}, {row, col, width, height}) do
    # Reserve 1 column for the vertical separator
    usable = width - 1
    left_width = clamp_size(size, usable)
    right_width = max(usable - left_width, 1)
    separator_col = col + left_width

    left_layouts = layout(left, {row, col, left_width, height})
    right_layouts = layout(right, {row, separator_col + 1, right_width, height})

    left_layouts ++ right_layouts
  end

  def layout({:split, :horizontal, top, bottom, size}, {row, col, width, height}) do
    top_height = clamp_size(size, height)
    bottom_height = max(height - top_height, 1)

    top_layouts = layout(top, {row, col, width, top_height})
    bottom_layouts = layout(bottom, {row + top_height, col, width, bottom_height})

    top_layouts ++ bottom_layouts
  end

  @doc """
  Resolves a split size: 0 means "half", otherwise clamp to [1, total-1].

  Used by layout and renderer to consistently compute child dimensions.
  """
  @spec clamp_size(non_neg_integer(), pos_integer()) :: pos_integer()
  def clamp_size(0, total), do: div(total, 2)
  def clamp_size(size, total), do: max(min(size, total - 1), 1)

  # ── Navigation ────────────────────────────────────────────────────────────

  @doc """
  Finds the neighbor window id when moving from `from_id` in the given direction.

  Uses the layout to determine spatial adjacency. Returns `{:ok, neighbor_id}`
  or `:error` if there is no neighbor in that direction.
  """
  @spec focus_neighbor(t(), Window.id(), nav_direction(), rect()) :: {:ok, Window.id()} | :error
  def focus_neighbor(tree, from_id, direction, screen_rect) do
    layouts = layout(tree, screen_rect)

    case find_layout(layouts, from_id) do
      nil ->
        :error

      {_id, from_rect} ->
        candidates = neighbor_candidates(layouts, from_id, from_rect, direction)

        case candidates do
          [] -> :error
          _ -> {:ok, best_candidate(candidates, from_rect, direction)}
        end
    end
  end

  defp find_layout(layouts, id) do
    Enum.find(layouts, fn {wid, _rect} -> wid == id end)
  end

  defp neighbor_candidates(layouts, from_id, {fr, fc, fw, fh}, direction) do
    from_center_row = fr + div(fh, 2)
    from_center_col = fc + div(fw, 2)

    layouts
    |> Enum.reject(fn {id, _} -> id == from_id end)
    |> Enum.filter(fn {_id, {r, c, w, h}} ->
      case direction do
        :left -> c + w <= fc
        :right -> c >= fc + fw
        :up -> r + h <= fr
        :down -> r >= fr + fh
      end
    end)
    |> Enum.map(fn {id, {r, c, w, h} = rect} ->
      center_row = r + div(h, 2)
      center_col = c + div(w, 2)

      distance =
        abs(center_row - from_center_row) + abs(center_col - from_center_col)

      {id, rect, distance}
    end)
  end

  defp best_candidate(candidates, _from_rect, _direction) do
    {id, _rect, _dist} = Enum.min_by(candidates, fn {_id, _rect, dist} -> dist end)
    id
  end

  # ── Hit testing ────────────────────────────────────────────────────────────

  @doc """
  Finds which window contains the given screen coordinate.

  Returns `{:ok, window_id, {row, col, width, height}}` or `:error` if the
  coordinate is outside any window rect (e.g. on a separator).
  """
  @spec window_at(t(), rect(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Window.id(), rect()} | :error
  def window_at(tree, screen_rect, row, col) do
    layouts = layout(tree, screen_rect)

    case Enum.find(layouts, fn {_id, {r, c, w, h}} ->
           row >= r and row < r + h and col >= c and col < c + w
         end) do
      {id, rect} -> {:ok, id, rect}
      nil -> :error
    end
  end

  # ── Separator hit testing ──────────────────────────────────────────────────

  @doc """
  Tests whether a screen coordinate is on a separator.

  Returns `{:ok, :vertical | :horizontal, separator_position}` or `:error`.
  For vertical splits, `separator_position` is the column; for horizontal,
  it's the row. The position is used to identify which split node to resize.
  """
  @spec separator_at(t(), rect(), non_neg_integer(), non_neg_integer()) ::
          {:ok, {direction(), non_neg_integer()}} | :error
  def separator_at(tree, screen_rect, row, col) do
    case find_separator(tree, screen_rect, row, col) do
      nil -> :error
      result -> {:ok, result}
    end
  end

  @spec find_separator(t(), rect(), non_neg_integer(), non_neg_integer()) ::
          {direction(), non_neg_integer()} | nil
  defp find_separator({:leaf, _}, _rect, _row, _col), do: nil

  defp find_separator(
         {:split, :vertical, left, right, size},
         {rect_row, rect_col, width, height},
         row,
         col
       ) do
    usable = width - 1
    left_width = clamp_size(size, usable)
    sep_col = rect_col + left_width

    if col == sep_col and row >= rect_row and row < rect_row + height do
      {:vertical, sep_col}
    else
      find_separator(left, {rect_row, rect_col, left_width, height}, row, col) ||
        find_separator(
          right,
          {rect_row, sep_col + 1, max(usable - left_width, 1), height},
          row,
          col
        )
    end
  end

  defp find_separator(
         {:split, :horizontal, top, bottom, size},
         {rect_row, rect_col, width, height},
         row,
         col
       ) do
    top_height = clamp_size(size, height)
    bottom_height = max(height - top_height, 1)

    # The top pane's modeline row is the drag handle for horizontal resize.
    modeline_row = rect_row + top_height - 1

    if row == modeline_row and col >= rect_col and col < rect_col + width do
      {:horizontal, modeline_row}
    else
      find_separator(top, {rect_row, rect_col, width, top_height}, row, col) ||
        find_separator(
          bottom,
          {rect_row + top_height, rect_col, width, bottom_height},
          row,
          col
        )
    end
  end

  # ── Resize ─────────────────────────────────────────────────────────────────

  @doc """
  Resizes the split that owns the separator at `separator_pos` to place
  that separator at `new_pos`. Only resizes vertical splits (by column)
  for now.

  Returns `{:ok, new_tree}` or `:error` if no matching split is found.
  """
  @spec resize_at(t(), rect(), direction(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | :error
  def resize_at(tree, screen_rect, direction, separator_pos, new_pos) do
    case do_resize(tree, screen_rect, direction, separator_pos, new_pos) do
      {:ok, _} = result -> result
      :not_found -> :error
    end
  end

  @spec do_resize(t(), rect(), direction(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | :not_found
  defp do_resize({:leaf, _}, _rect, _dir, _sep, _new), do: :not_found

  defp do_resize(
         {:split, :vertical, left, right, size},
         {rect_row, rect_col, width, height},
         :vertical,
         separator_pos,
         new_pos
       ) do
    usable = width - 1
    left_width = clamp_size(size, usable)
    sep_col = rect_col + left_width

    if sep_col == separator_pos do
      # This is the split to resize — new_pos is the desired separator column
      new_left_width = max(min(new_pos - rect_col, usable - 1), 1)
      {:ok, {:split, :vertical, left, right, new_left_width}}
    else
      left_rect = {rect_row, rect_col, left_width, height}
      right_rect = {rect_row, sep_col + 1, max(usable - left_width, 1), height}

      node = {:split, :vertical, left, right, size}

      recurse_resize_children(node, left_rect, right_rect, :vertical, separator_pos, new_pos)
    end
  end

  defp do_resize(
         {:split, :horizontal, left, right, size},
         {rect_row, rect_col, width, height},
         :horizontal,
         separator_pos,
         new_pos
       ) do
    top_height = clamp_size(size, height)
    modeline_row = rect_row + top_height - 1

    if modeline_row == separator_pos do
      # This is the split to resize — new_pos is the desired modeline row.
      # The top pane height = (new_pos - rect_row + 1) to keep modeline at new_pos.
      new_top_height = max(min(new_pos - rect_row + 1, height - 1), 1)
      {:ok, {:split, :horizontal, left, right, new_top_height}}
    else
      bottom_height = max(height - top_height, 1)
      top_rect = {rect_row, rect_col, width, top_height}
      bottom_rect = {rect_row + top_height, rect_col, width, bottom_height}
      node = {:split, :horizontal, left, right, size}

      recurse_resize_children(node, top_rect, bottom_rect, :horizontal, separator_pos, new_pos)
    end
  end

  defp do_resize(
         {:split, :vertical, left, right, size},
         {rect_row, rect_col, width, height},
         :horizontal,
         separator_pos,
         new_pos
       ) do
    usable = width - 1
    left_width = clamp_size(size, usable)
    left_rect = {rect_row, rect_col, left_width, height}
    right_rect = {rect_row, rect_col + left_width + 1, max(usable - left_width, 1), height}
    node = {:split, :vertical, left, right, size}

    recurse_resize_children(node, left_rect, right_rect, :horizontal, separator_pos, new_pos)
  end

  defp do_resize(
         {:split, :horizontal, left, right, size},
         {rect_row, rect_col, width, height},
         :vertical,
         separator_pos,
         new_pos
       ) do
    top_height = clamp_size(size, height)
    bottom_height = max(height - top_height, 1)
    top_rect = {rect_row, rect_col, width, top_height}
    bottom_rect = {rect_row + top_height, rect_col, width, bottom_height}
    node = {:split, :horizontal, left, right, size}

    recurse_resize_children(node, top_rect, bottom_rect, :vertical, separator_pos, new_pos)
  end

  # Recurse into both children of a split looking for the separator to resize.
  @spec recurse_resize_children(
          t(),
          rect(),
          rect(),
          direction(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, t()} | :not_found
  defp recurse_resize_children(
         {:split, dir, left, right, size},
         left_rect,
         right_rect,
         search_dir,
         sep_pos,
         new_pos
       ) do
    case do_resize(left, left_rect, search_dir, sep_pos, new_pos) do
      {:ok, new_left} ->
        {:ok, {:split, dir, new_left, right, size}}

      :not_found ->
        case do_resize(right, right_rect, search_dir, sep_pos, new_pos) do
          {:ok, new_right} -> {:ok, {:split, dir, left, new_right, size}}
          :not_found -> :not_found
        end
    end
  end
end
