defmodule Minga.RenderModel.UI.ExtensionPanel.Content.Table do
  @moduledoc """
  Table content block in a GUI extension panel.
  """

  @type t :: %__MODULE__{
          columns: [String.t()],
          rows: [[String.t()]],
          selected: non_neg_integer()
        }

  @enforce_keys [:columns, :rows, :selected]
  defstruct [:columns, :rows, :selected]
end
