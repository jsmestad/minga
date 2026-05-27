defmodule Minga.RenderModel.UI.Picker do
  @moduledoc """
  Pre-encoded picker model.

  The picker wire format is complex (item encoding with match positions,
  preview sub-commands, action menu, mode prefix, load status) and depends
  on editor-layer types (UI.Picker, Picker.Source). Rather than duplicating
  that encoding in core, the builder pre-encodes the binary and stores it
  here along with the fingerprint for change detection.

  Uses a `:closed` sentinel fingerprint when the picker is dismissed.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer() | :closed
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
