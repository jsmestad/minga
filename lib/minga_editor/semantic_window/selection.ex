defmodule MingaEditor.SemanticWindow.Selection do
  @moduledoc """
  Visual selection overlay in display coordinates.

  Sent as coordinate ranges so the GUI can render selection as Metal
  quads behind text, avoiding line re-rasterization when the selection
  changes.
  """

  @enforce_keys [:type]
  defstruct type: :none,
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 0

  @type selection_type :: :char | :line | :block

  @type t :: %__MODULE__{
          type: selection_type(),
          start_row: non_neg_integer(),
          start_col: non_neg_integer(),
          end_row: non_neg_integer(),
          end_col: non_neg_integer()
        }

  @max_u16 65_535

  @type visual_selection ::
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()}

  @doc "Builds a selection from the render context's visual_selection."
  @spec from_visual_selection(visual_selection(), non_neg_integer()) :: t() | nil
  def from_visual_selection(selection, viewport_top) do
    from_visual_selection(selection, viewport_top, @max_u16, 0, @max_u16)
  end

  @doc "Builds a selection clipped to the visible viewport."
  @spec from_visual_selection(
          visual_selection(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: t() | nil
  def from_visual_selection(nil, _viewport_top, _visible_rows, _viewport_left, _visible_cols),
    do: nil

  def from_visual_selection(
        {:char, {sl, sc}, {el, ec}},
        viewport_top,
        visible_rows,
        viewport_left,
        visible_cols
      ) do
    case visible_line_range(sl, el, viewport_top, visible_rows) do
      nil ->
        nil

      {start_line, end_line} ->
        %__MODULE__{
          type: :char,
          start_row: start_line - viewport_top,
          start_col: char_start_col(start_line, sl, sc, viewport_left),
          end_row: end_line - viewport_top,
          end_col: char_end_col(end_line, el, ec, viewport_left, visible_cols)
        }
    end
  end

  def from_visual_selection(
        {:line, start_line, end_line},
        viewport_top,
        visible_rows,
        _viewport_left,
        _visible_cols
      ) do
    case visible_line_range(start_line, end_line, viewport_top, visible_rows) do
      nil ->
        nil

      {visible_start_line, visible_end_line} ->
        %__MODULE__{
          type: :line,
          start_row: visible_start_line - viewport_top,
          start_col: 0,
          end_row: visible_end_line - viewport_top,
          end_col: 0
        }
    end
  end

  @spec visible_line_range(non_neg_integer(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp visible_line_range(start_line, end_line, viewport_top, visible_rows) do
    viewport_bottom = viewport_top + visible_rows - 1

    case {end_line < viewport_top, start_line > viewport_bottom} do
      {true, _} -> nil
      {_, true} -> nil
      _ -> {max(start_line, viewport_top), min(end_line, viewport_bottom)}
    end
  end

  @spec char_start_col(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp char_start_col(visible_start_line, selection_start_line, start_col, viewport_left)
       when visible_start_line == selection_start_line do
    clamp_u16(max(start_col, viewport_left))
  end

  defp char_start_col(_visible_start_line, _selection_start_line, _start_col, viewport_left) do
    clamp_u16(viewport_left)
  end

  @spec char_end_col(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: non_neg_integer()
  defp char_end_col(visible_end_line, selection_end_line, end_col, viewport_left, visible_cols)
       when visible_end_line == selection_end_line do
    clamp_u16(min(end_col, viewport_left + visible_cols))
  end

  defp char_end_col(_visible_end_line, _selection_end_line, _end_col, viewport_left, visible_cols) do
    clamp_u16(viewport_left + visible_cols)
  end

  @spec clamp_u16(non_neg_integer()) :: non_neg_integer()
  defp clamp_u16(value), do: min(value, @max_u16)
end
