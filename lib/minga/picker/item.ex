defmodule Minga.Picker.Item do
  @moduledoc """
  A single candidate in a picker list.

  Every picker source returns a list of `%Item{}` structs. The struct
  carries both display data (label, description, icon color) and
  identity (id) for selection callbacks.

  ## Required fields

  - `:id` — unique identifier (file path, buffer index, command atom, etc.)
  - `:label` — display text shown in the picker, used for fuzzy matching

  ## Optional fields

  - `:description` — secondary text, rendered right-aligned and dimmed
  - `:icon_color` — 24-bit RGB color for the first grapheme (the icon) of the label
  - `:annotation` — right-aligned metadata (keybinding, status indicator),
    styled distinctly from the description
  """

  @enforce_keys [:id, :label]
  defstruct [
    :id,
    :label,
    description: "",
    icon_color: nil,
    annotation: nil
  ]

  @type t :: %__MODULE__{
          id: term(),
          label: String.t(),
          description: String.t(),
          icon_color: non_neg_integer() | nil,
          annotation: String.t() | nil
        }
end
