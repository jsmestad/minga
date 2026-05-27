defmodule Minga.RenderModel.UI.Workspaces do
  @moduledoc """
  Pre-encoded workspaces model.

  The workspaces wire format involves bounded_entries encoding, workspace
  summary serialization with RGB color decomposition, tab summary encoding,
  and multiple flag/kind encoders. Rather than duplicating that encoding
  in core, the builder pre-encodes the binary and stores it here along
  with a fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary() | nil,
          fingerprint: integer() | :suppressed
        }

  defstruct encoded: nil, fingerprint: :suppressed
end
