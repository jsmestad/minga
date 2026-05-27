defmodule Minga.RenderModel.UI.AgentChat do
  @moduledoc """
  Pre-encoded agent chat model.

  The agent chat wire format is the largest encoder (~1,100 lines in
  ProtocolGUI) with section-based formatting, styled messages, prompt
  completion, help groups, and various message types. Rather than
  duplicating that encoding in core, the builder pre-encodes the binary
  and stores it here along with a fingerprint for change detection.

  Uses a `:not_visible` sentinel fingerprint when the agent chat panel
  is not active.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer() | :not_visible
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
