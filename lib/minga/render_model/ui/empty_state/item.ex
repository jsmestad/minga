defmodule Minga.RenderModel.UI.EmptyState.Item do
  @moduledoc """
  One row of the project home.

  `jump_key` is the single key that opens the row (`"1"` to `"9"` for recent files and projects), drawn as a number column. `chord` is the leader sequence an action row runs (`"SPC SPC"`), drawn in the accent key column. `detail` is the muted second part of the row (a directory, a path, a state word) and `meta` the trailing muted text (an age). A task row carries its design-token `state` (`Minga.Design.Tokens`), whose mark and colour frontends draw before the label.
  """

  alias Minga.Design.Tokens

  @typedoc "Row kind, for focus and activation."
  @type kind :: :recent_file | :project | :task | :action

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          label: String.t(),
          detail: String.t(),
          meta: String.t(),
          jump_key: String.t() | nil,
          chord: String.t(),
          icon: String.t(),
          icon_color: non_neg_integer(),
          state: Tokens.state_id() | nil
        }

  @enforce_keys [:id, :kind, :label]
  defstruct id: nil,
            kind: nil,
            label: "",
            detail: "",
            meta: "",
            jump_key: nil,
            chord: "",
            icon: "",
            icon_color: 0,
            state: nil
end
