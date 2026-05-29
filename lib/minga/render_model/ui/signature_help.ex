defmodule Minga.RenderModel.UI.SignatureHelp do
  @moduledoc """
  Semantic signature help model for GUI adapters.
  """

  alias Minga.RenderModel.UI.SignatureHelp.Signature

  @type t :: %__MODULE__{
          visible?: boolean(),
          anchor_row: non_neg_integer(),
          anchor_col: non_neg_integer(),
          active_signature: non_neg_integer(),
          active_parameter: non_neg_integer(),
          signatures: [Signature.t()]
        }

  defstruct visible?: false,
            anchor_row: 0,
            anchor_col: 0,
            active_signature: 0,
            active_parameter: 0,
            signatures: []
end
