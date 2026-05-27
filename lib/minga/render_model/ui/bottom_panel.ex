defmodule Minga.RenderModel.UI.BottomPanel do
  @moduledoc """
  Pre-encoded bottom panel model.

  The bottom panel wire format includes tab definitions, active tab index,
  height percent, filter state, and message entries with timestamps. Rather
  than duplicating that encoding in core, the builder pre-encodes the binary
  and stores it here along with a fingerprint for change detection.

  The bottom panel has a side effect: encoding may advance the message_store
  cursor. The builder captures this by returning both the model and the
  updated message_store, which the orchestrator must apply back to ctx.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
