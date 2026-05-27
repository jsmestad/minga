defmodule Minga.RenderModel.UI.Observatory do
  @moduledoc """
  Pre-encoded observatory model.

  The observatory wire format involves complex TreeNode flattening,
  sparkline encoding, and section chunking with many private helpers
  in the protocol layer. Rather than duplicating that encoding in core,
  the builder pre-encodes the binary and stores it here along with the
  visibility state for fingerprinting.
  """

  @type t :: %__MODULE__{
          visible: boolean(),
          encoded: binary(),
          fingerprint: integer() | :hidden
        }

  @enforce_keys [:visible, :encoded, :fingerprint]
  defstruct [:visible, :encoded, :fingerprint]
end
