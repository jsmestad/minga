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

  @typedoc "The tree structure."
  @type t :: {:leaf, Window.id()} | {:split, direction(), t(), t()}

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
    {:ok, {:split, direction, {:leaf, id}, {:leaf, new_id}}}
  end

  defp do_split({:leaf, _other}, _target, _dir, _new_id), do: :not_found

  defp do_split({:split, dir, left, right}, target, split_dir, new_id) do
    case do_split(left, target, split_dir, new_id) do
      {:ok, new_left} ->
        {:ok, {:split, dir, new_left, right}}

      :not_found ->
        case do_split(right, target, split_dir, new_id) do
          {:ok, new_right} -> {:ok, {:split, dir, left, new_right}}
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

  def close({:split, _dir, _left, _right} = tree, target) do
    case do_close(tree, target) do
      {:ok, _} = result -> result
      :not_found -> :error
    end
  end

  defp do_close({:leaf, _}, _target), do: :not_found

  defp do_close({:split, _dir, {:leaf, id}, right}, id), do: {:ok, right}
  defp do_close({:split, _dir, left, {:leaf, id}}, id), do: {:ok, left}

  defp do_close({:split, dir, left, right}, target) do
    case do_close(left, target) do
      {:ok, new_left} ->
        {:ok, {:split, dir, new_left, right}}

      :not_found ->
        case do_close(right, target) do
          {:ok, new_right} -> {:ok, {:split, dir, left, new_right}}
          :not_found -> :not_found
        end
    end
  end

  # ── Querying ──────────────────────────────────────────────────────────────

  @doc "Returns all window ids in the tree, left-to-right / top-to-bottom order."
  @spec leaves(t()) :: [Window.id()]
  def leaves({:leaf, id}), do: [id]
  def leaves({:split, _dir, left, right}), do: leaves(left) ++ leaves(right)

  @doc "Returns the number of leaves (windows) in the tree."
  @spec count(t()) :: pos_integer()
  def count({:leaf, _}), do: 1
  def count({:split, _dir, left, right}), do: count(left) + count(right)

  @doc "Returns true if the given window id exists in the tree."
  @spec member?(t(), Window.id()) :: boolean()
  def member?({:leaf, id}, id), do: true
  def member?({:leaf, _}, _target), do: false

  def member?({:split, _dir, left, right}, target),
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

  def layout({:split, :vertical, left, right}, {row, col, width, height}) do
    # Reserve 1 column for the vertical separator
    left_width = div(width - 1, 2)
    right_width = width - left_width - 1
    separator_col = col + left_width

    left_layouts = layout(left, {row, col, left_width, height})
    right_layouts = layout(right, {row, separator_col + 1, right_width, height})

    left_layouts ++ right_layouts
  end

  def layout({:split, :horizontal, top, bottom}, {row, col, width, height}) do
    top_height = div(height, 2)
    bottom_height = height - top_height

    top_layouts = layout(top, {row, col, width, top_height})
    bottom_layouts = layout(bottom, {row + top_height, col, width, bottom_height})

    top_layouts ++ bottom_layouts
  end

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
end
