defmodule MingaEditor.Extension.Picker.Item do
  @moduledoc """
  A picker row supplied by an extension. Item ids are source-private and must
  be unique across the pages of a picker. Frontends never receive these ids.

  The optional icon is prefixed to the display label and uses `icon_color`
  (24-bit RGB). `search_text` adds hidden text to fuzzy matching.

  `two_line` is accepted for compatibility and has no effect. Frontends choose the row layout.
  """

  @enforce_keys [:id, :label]
  defstruct [
    :id,
    :label,
    :icon,
    :icon_color,
    :annotation,
    description: "",
    search_text: "",
    two_line: false
  ]

  @type t :: %__MODULE__{
          id: term(),
          label: String.t(),
          description: String.t(),
          annotation: String.t() | nil,
          search_text: String.t(),
          icon: String.t() | nil,
          icon_color: 0..0xFFFFFF | nil,
          two_line: boolean()
        }
end
