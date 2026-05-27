defmodule Minga.RenderModel.UI.Completion do
  @moduledoc """
  Pre-encoded completion model.

  The completion wire format includes kind bytes, label/detail strings,
  icon metadata, match positions, and cursor screen position. Rather than
  duplicating that encoding in core, the builder pre-encodes the binary
  and stores it here along with a fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
