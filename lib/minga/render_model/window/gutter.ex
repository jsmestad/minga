defmodule Minga.RenderModel.Window.Gutter do
  @moduledoc """
  Pre-resolved gutter state for one window.
  """

  alias Minga.RenderModel.Window.GutterEntry

  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @enforce_keys [
    :window_id,
    :content_row,
    :content_col,
    :content_height,
    :is_active,
    :content_width,
    :cursor_line,
    :line_number_style,
    :line_number_width,
    :sign_col_width,
    :entries
  ]
  defstruct window_id: 0,
            content_row: 0,
            content_col: 0,
            content_height: 0,
            is_active: false,
            content_width: 0,
            cursor_line: 0,
            line_number_style: :none,
            line_number_width: 0,
            sign_col_width: 0,
            entries: []

  @type t :: %__MODULE__{
          window_id: non_neg_integer(),
          content_row: non_neg_integer(),
          content_col: non_neg_integer(),
          content_height: non_neg_integer(),
          is_active: boolean(),
          content_width: non_neg_integer(),
          cursor_line: non_neg_integer(),
          line_number_style: line_number_style(),
          line_number_width: non_neg_integer(),
          sign_col_width: non_neg_integer(),
          entries: [GutterEntry.t()]
        }
end
