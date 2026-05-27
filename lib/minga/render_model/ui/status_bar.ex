defmodule Minga.RenderModel.UI.StatusBar do
  @moduledoc """
  Pre-encoded status bar model.

  The status bar wire format is complex (section-based encoding with many
  helpers) and tightly coupled to editor-layer types (ChromeState, Modeline,
  Devicon). Rather than duplicating all encoding logic in core, the builder
  pre-encodes the binary and stores it here. The encoder passes it through.

  This still provides value: the builder is the single callsite that
  orchestrates StatusBarData, ChromeState, and ProtocolGUI encoding.
  """

  @type t :: %__MODULE__{
          encoded: binary()
        }

  @enforce_keys [:encoded]
  defstruct [:encoded]
end
