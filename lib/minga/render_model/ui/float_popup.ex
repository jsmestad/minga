defmodule Minga.RenderModel.UI.FloatPopup do
  @moduledoc """
  Pre-encoded float popup model.

  The float popup has two sources: observatory inspection data and float-display
  popup windows. The wire format includes visibility, dimensions, title, and
  line content. The builder pre-encodes the binary and stores it here along
  with a fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
