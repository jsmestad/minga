defmodule Minga.RenderModel.UI.HoverPopup do
  @moduledoc """
  Semantic hover popup model for GUI adapters.
  """

  alias Minga.RenderModel.UI.HoverPopup.Line

  @type t :: %__MODULE__{
          visible?: boolean(),
          anchor_row: non_neg_integer(),
          anchor_col: non_neg_integer(),
          focused?: boolean(),
          scroll_offset: non_neg_integer(),
          content_lines: [Line.t()],
          open_action_name: String.t() | nil
        }

  defstruct visible?: false,
            anchor_row: 0,
            anchor_col: 0,
            focused?: false,
            scroll_offset: 0,
            content_lines: [],
            open_action_name: nil
end
