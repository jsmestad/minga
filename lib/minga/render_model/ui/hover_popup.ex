defmodule Minga.RenderModel.UI.HoverPopup do
  @moduledoc """
  Pre-encoded hover popup model.

  The hover popup wire format includes markdown content lines with typed
  segments (plain, bold, italic, code, headers, blockquotes, etc.), anchor
  position, focus state, scroll offset, and an optional action sidecar
  command. The builder pre-encodes the binary and stores it here along with
  a fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
