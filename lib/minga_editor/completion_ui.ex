defmodule MingaEditor.CompletionUI do
  @moduledoc """
  Geometry for the LSP completion popup.

  The completion menu and its documentation preview render natively on the
  semantic frontends (macOS SwiftUI and the Go TUI) from
  `Minga.RenderModel.UI.Completion`, encoded by the `gui_completion` opcode.
  This module only computes the popup's screen rect (`menu_rect/2`) so the
  `FocusTree` can register the completion surface's hit region from the BEAM's
  own geometry. The cell-grid painter that drew the menu and doc preview was
  removed in #2311.
  """

  alias Minga.Editing.Completion

  @max_rows 10
  @max_width 50
  @min_width 20

  @typedoc "Render context with cursor position and viewport."
  @type render_opts :: %{
          cursor_row: non_neg_integer(),
          cursor_col: non_neg_integer(),
          viewport_rows: non_neg_integer(),
          viewport_cols: non_neg_integer()
        }

  @doc "Returns the screen rect for the visible completion menu, or nil when it is empty."
  @spec menu_rect(Completion.t() | nil, render_opts()) :: MingaEditor.Layout.rect() | nil
  def menu_rect(nil, _opts), do: nil

  def menu_rect(%Completion{} = completion, opts) do
    {visible, _selected_offset} = Completion.visible_items(completion)

    case menu_geometry(visible, opts) do
      nil -> nil
      %{row: row, col: col, width: width, height: height} -> {row, col, width, height}
    end
  end

  @spec menu_geometry([Completion.item()], render_opts()) ::
          %{
            row: non_neg_integer(),
            col: non_neg_integer(),
            width: pos_integer(),
            height: pos_integer(),
            box_row: non_neg_integer(),
            box_col: non_neg_integer(),
            box_width: pos_integer(),
            box_height: pos_integer()
          }
          | nil
  defp menu_geometry([], _opts), do: nil

  defp menu_geometry(items, opts) do
    item_capacity = max(min(@max_rows, opts.viewport_rows - 2), 1)
    item_count = min(Enum.count(items), item_capacity)
    visible_items = Enum.take(items, item_count)
    label_widths = Enum.map(visible_items, fn item -> String.length(item.label) + 4 end)
    desired_width = label_widths |> Enum.max() |> max(@min_width) |> min(@max_width)
    box_width = min(max(desired_width + 2, 3), max(opts.viewport_cols, 1))
    popup_width = max(box_width - 2, 1)
    box_height = min(item_count + 2, max(opts.viewport_rows, 1))
    box_row = menu_box_start_row(opts.cursor_row, opts.viewport_rows, box_height)
    box_col = min(opts.cursor_col, max(0, opts.viewport_cols - box_width))

    %{
      row: box_row + 1,
      col: box_col + 1,
      width: popup_width,
      height: item_count,
      box_row: box_row,
      box_col: box_col,
      box_width: box_width,
      box_height: box_height
    }
  end

  @spec menu_box_start_row(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  defp menu_box_start_row(cursor_row, viewport_rows, box_height) do
    space_below = viewport_rows - cursor_row - 1
    space_above = cursor_row
    choose_menu_box_start_row(cursor_row, box_height, space_below, space_above, viewport_rows)
  end

  @spec choose_menu_box_start_row(
          non_neg_integer(),
          pos_integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp choose_menu_box_start_row(
         cursor_row,
         box_height,
         space_below,
         _space_above,
         _viewport_rows
       )
       when space_below >= box_height do
    cursor_row + 1
  end

  defp choose_menu_box_start_row(
         cursor_row,
         box_height,
         _space_below,
         space_above,
         _viewport_rows
       )
       when space_above >= box_height do
    cursor_row - box_height
  end

  defp choose_menu_box_start_row(
         cursor_row,
         box_height,
         _space_below,
         _space_above,
         viewport_rows
       ) do
    min(cursor_row + 1, max(viewport_rows - box_height, 0))
  end
end
