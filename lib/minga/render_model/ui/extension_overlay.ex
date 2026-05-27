defmodule Minga.RenderModel.UI.ExtensionOverlay do
  @moduledoc """
  Pre-encoded extension overlay model.

  Extension overlays are positioned within buffer windows and use a complex
  per-entry wire format (extension name, overlay ID, window position, shape,
  color, opacity, content). The builder pre-encodes the binary and stores it
  here along with a fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
