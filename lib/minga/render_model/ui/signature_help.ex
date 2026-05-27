defmodule Minga.RenderModel.UI.SignatureHelp do
  @moduledoc """
  Pre-encoded signature help model.

  The signature help wire format includes anchor position, active signature
  and parameter indices, and nested signature/parameter label+doc encoding.
  Rather than duplicating that encoding in core, the builder pre-encodes
  the binary and stores it here along with a fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
