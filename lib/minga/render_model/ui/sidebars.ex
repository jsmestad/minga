defmodule Minga.RenderModel.UI.Sidebars do
  @moduledoc """
  Pre-encoded sidebars model.

  The sidebars wire format uses a 32-bit payload length envelope and
  encodes sidebar metadata (id, display_name, semantic_kind, icon, order,
  flags, preferred_width, badge_count) with string16 helpers. The builder
  also resolves the active sidebar through a priority chain (registered
  active, preferred, focused, visible fallback). Rather than duplicating
  that encoding in core, the builder pre-encodes the binary and stores
  it here along with a fingerprint for change detection.
  """

  @type t :: %__MODULE__{
          encoded: binary() | nil,
          fingerprint: integer() | nil
        }

  defstruct encoded: nil, fingerprint: nil
end
