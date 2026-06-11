defmodule MingaEditor.Shell.Traditional.Chrome.Helpers do
  @moduledoc """
  Helper for Traditional shell chrome geometry.

  Collects vertical split-separator positions from the window tree. The GUI
  adapter renders these as native Metal quads (0x84 opcode); the
  `SplitSeparatorsBuilder` consumes `collect_vertical_separators/2`.

  The cell-grid painters this module used to carry (tab bar, workspace row,
  which-key popup, separator `│` draws, horizontal separator bars) were removed
  in #2311 — the semantic frontends render those surfaces natively and nothing
  consumed the cell draws.
  """

  alias MingaEditor.WindowTree

  @typep separator_span :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Collects vertical separator positions from the window tree.

  Returns a list of `{col, start_row, end_row}` tuples for each vertical split
  border. The GUI adapter renders native Metal quads (0x84 opcode) from these.
  """
  @spec collect_vertical_separators(WindowTree.t(), WindowTree.rect()) :: [separator_span()]
  def collect_vertical_separators(tree, rect), do: collect_separators(tree, rect)

  @spec collect_separators(WindowTree.t(), WindowTree.rect()) :: [separator_span()]
  defp collect_separators({:leaf, _}, _rect), do: []

  # Degenerate dimensions: nothing to render.
  defp collect_separators(_tree, {_row, _col, width, height})
       when width <= 1 or height <= 0,
       do: []

  defp collect_separators(
         {:split, :vertical, left, right, size},
         {row, col, width, height}
       ) do
    usable = width - 1
    left_width = WindowTree.clamp_size(size, usable)
    right_width = max(usable - left_width, 1)
    separator_col = col + left_width

    [{separator_col, row, row + height - 1}] ++
      collect_separators(left, {row, col, left_width, height}) ++
      collect_separators(right, {row, separator_col + 1, right_width, height})
  end

  defp collect_separators(
         {:split, :horizontal, top, bottom, size},
         {row, col, width, height}
       ) do
    top_height = WindowTree.clamp_size(size, height)
    bottom_height = max(height - top_height, 1)

    collect_separators(top, {row, col, width, top_height}) ++
      collect_separators(bottom, {row + top_height, col, width, bottom_height})
  end
end
