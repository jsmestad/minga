defmodule Minga.RenderModel.UI.ExtensionPanel.Content.Table do
  @moduledoc """
  Table content block in a GUI extension panel.
  """

  @typedoc "Selected row index, or nil when the table has no selection."
  @type selected :: non_neg_integer() | nil

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [[String.t()]],
          selected: selected()
        }

  @enforce_keys [:columns, :rows, :selected]
  defstruct [:columns, :rows, :selected]
end
