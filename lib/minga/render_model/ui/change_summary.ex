defmodule Minga.RenderModel.UI.ChangeSummary do
  @moduledoc """
  Pre-encoded change summary model.

  The change summary wire format includes diff stat entries with file paths,
  additions/deletions counts, and selected index. Rather than duplicating
  that encoding in core, the builder pre-encodes the binary and stores it
  here along with a fingerprint for change detection.

  Uses a `:hidden` sentinel fingerprint when no card is zoomed.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer() | :hidden
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
