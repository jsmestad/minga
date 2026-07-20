defmodule MingaEditor.Renderer.Gutter do
  @moduledoc """
  Geometry helpers for the editor gutter.

  The gutter reserves separate columns for signs, fold controls, and line numbers so cursor math, mouse hit testing, and semantic window models agree on the same terminal-cell geometry. Semantic gutter entries are built by `MingaEditor.RenderModel.Window.Builder` and rendered by the frontends.
  """

  @sign_col_width 2
  @fold_col_width 1

  @doc """
  Returns the total gutter width including sign column, fold column, and line numbers.

  The sign column is always reserved to keep layout stable regardless of whether diagnostics or git markers are active. The fold column is separate so fold indicators never overwrite signs or annotations.
  """
  @spec total_width(non_neg_integer()) :: non_neg_integer()
  def total_width(line_number_w) do
    @sign_col_width + @fold_col_width + line_number_w
  end

  @doc "Returns the width of the sign column."
  @spec sign_column_width() :: non_neg_integer()
  def sign_column_width, do: @sign_col_width

  @doc "Returns the width of the fold indicator column."
  @spec fold_column_width() :: non_neg_integer()
  def fold_column_width, do: @fold_col_width

  @doc "Returns the gutter-relative column where fold indicators are drawn."
  @spec fold_column_offset() :: non_neg_integer()
  def fold_column_offset, do: @sign_col_width
end
