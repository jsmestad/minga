defmodule Minga.RenderModel.UI.ExtensionPanel do
  @moduledoc """
  Pre-encoded extension panel model.

  Extension panels use a recursive content block wire format (text, styled_text,
  key_value, table, progress_bar, tree, button_group, divider, markdown)
  with per-panel metadata (position, size, visibility). The builder pre-encodes
  the binary and stores it here along with a fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary(),
          fingerprint: integer()
        }

  @enforce_keys [:encoded, :fingerprint]
  defstruct [:encoded, :fingerprint]
end
