defmodule Minga.RenderModel.UI.EmptyState.Item do
  @moduledoc """
  One launchpad row.

  The input-visual class is derivable: a non-nil `jump_key` renders as a
  single keycap chip (press one key), a non-empty `chord` renders as one
  chip per keystroke token (`"SPC f f"`), and an ex-command `detail`
  (`":Tutor"`) renders as accent text with no chip.
  """

  @typedoc "Row behavior kind for focus/activation."
  @type kind :: :resume | :recent_file | :action | :hint

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          label: String.t(),
          detail: String.t(),
          jump_key: String.t() | nil,
          chord: String.t(),
          icon: String.t(),
          icon_color: non_neg_integer()
        }

  @enforce_keys [:id, :kind, :label]
  defstruct id: nil,
            kind: nil,
            label: "",
            detail: "",
            jump_key: nil,
            chord: "",
            icon: "",
            icon_color: 0
end
