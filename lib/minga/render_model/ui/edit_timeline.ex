defmodule Minga.RenderModel.UI.EditTimeline do
  @moduledoc """
  Pre-encoded edit timeline model.

  The edit timeline wire format includes visibility, viewing index, and
  wire entries with tool names and timestamp deltas. Rather than duplicating
  that encoding in core, the builder pre-encodes the binary and stores it
  here along with a fingerprint for change detection.

  Uses a `:hidden` sentinel fingerprint when no timeline is visible.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer() | :hidden
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
