defmodule Minga.RenderModel.UI.Board do
  @moduledoc """
  Pre-encoded board model.

  The board wire format involves complex card encoding (status bytes, Float16
  sparklines, validation) and depends on editor-layer types (BoardPayload,
  BoardCardPayload). Rather than duplicating that encoding in core, the
  builder pre-encodes the binary and stores it here along with the
  fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer() | :dismissed
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
