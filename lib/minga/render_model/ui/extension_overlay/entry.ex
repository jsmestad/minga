defmodule Minga.RenderModel.UI.ExtensionOverlay.Entry do
  @moduledoc """
  One extension-owned overlay positioned in a GUI window.
  """

  @type shape :: :cursor | :cursor_with_label | :label | :indicator

  @type t :: %__MODULE__{
          extension: String.t(),
          overlay_id: String.t(),
          window_id: non_neg_integer(),
          row: non_neg_integer(),
          col: non_neg_integer(),
          shape: shape(),
          fg: non_neg_integer(),
          opacity: non_neg_integer(),
          content: String.t()
        }

  @enforce_keys [:extension, :overlay_id, :window_id, :row, :col, :shape, :fg, :opacity, :content]
  defstruct [:extension, :overlay_id, :window_id, :row, :col, :shape, :fg, :opacity, :content]
end
