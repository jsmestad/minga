defmodule Minga.RenderModel.UI.Minibuffer do
  @moduledoc """
  Pre-encoded minibuffer model.

  The minibuffer wire format includes mode, prompt, input, cursor position,
  context, and completion candidates with match positions. Rather than
  duplicating that encoding in core, the builder pre-encodes the binary
  and stores it here along with a fingerprint for change detection.

  Uses a `:hidden` sentinel fingerprint when the minibuffer is not visible.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: term()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
