defmodule Minga.RenderModel.Window.GutterEntry do
  @moduledoc """
  One visible gutter row for a window.
  """

  @type display_type ::
          :normal | :fold_start | :fold_continuation | :wrap_continuation | :fold_open
  @type sign_type ::
          :none
          | :git_added
          | :git_modified
          | :git_deleted
          | :diag_error
          | :diag_warning
          | :diag_info
          | :diag_hint
          | :annotation

  @enforce_keys [:buf_line, :display_type, :sign_type]
  defstruct buf_line: 0,
            display_type: :normal,
            sign_type: :none,
            fold_end_line: 0xFFFF_FFFF,
            sign_fg: nil,
            sign_text: nil

  @type t :: %__MODULE__{
          buf_line: non_neg_integer(),
          display_type: display_type(),
          sign_type: sign_type(),
          fold_end_line: non_neg_integer(),
          sign_fg: non_neg_integer() | nil,
          sign_text: String.t() | nil
        }
end
