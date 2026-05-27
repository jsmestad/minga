defmodule Minga.RenderModel.UI.TabBar do
  @moduledoc """
  Pre-encoded tab bar model.

  The tab bar wire format involves complex flag encoding, dirty-bit detection
  via Buffer.dirty?, icon resolution through Language.detect_filetype, and
  agent status encoding. Rather than duplicating that encoding in core, the
  builder pre-encodes the binary and stores it here along with a fingerprint
  for change detection.

  The builder also handles the board-shell suppression mode (where the tab
  bar is not shown because the board surface takes over).
  """

  @type t :: %__MODULE__{
          encoded: binary() | nil,
          fingerprint: integer() | :suppressed
        }

  defstruct encoded: nil, fingerprint: :suppressed
end
