defmodule Minga.RenderModel.UI.FileTree do
  @moduledoc """
  Semantic file tree model for GUI adapters.

  The adapter derives cache fingerprints and chooses between full tree and selection-only commands from this model.
  """

  alias Minga.RenderModel.UI.FileTree.Row

  @type status :: :hidden | :loading | :empty | :ready | {:error, String.t()}

  @type t :: %__MODULE__{
          root_path: String.t() | nil,
          tree_width: non_neg_integer(),
          status: status(),
          focused?: boolean(),
          selected_id: String.t(),
          rows: [Row.t()]
        }

  defstruct root_path: nil,
            tree_width: 0,
            status: :hidden,
            focused?: false,
            selected_id: "",
            rows: []
end
