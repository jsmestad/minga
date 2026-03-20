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

  - `:description` — secondary text, rendered below the label (file pickers)
    or right-aligned and dimmed (command pickers)
  - `:icon_color` — 24-bit RGB color for the first grapheme (the icon) of the label
  - `:annotation` — right-aligned metadata (keybinding, status indicator),
    styled distinctly from the description (e.g., "SPC f s" for commands)
  - `:match_positions` — 0-based character indices of matched characters in the
    label, computed during fuzzy filtering for rendering highlights
  - `:two_line` — when true, renders description on a second line below the label
    instead of inline. Used by file/buffer pickers for path display.
  """

  @enforce_keys [:id, :label]
  defstruct [
    :id,
    :label,
    description: "",
    icon_color: nil,
    annotation: nil,
    match_positions: [],
    two_line: false
  ]

  @type t :: %__MODULE__{
          id: term(),
          label: String.t(),
          description: String.t(),
          icon_color: non_neg_integer() | nil,
          annotation: String.t() | nil,
          match_positions: [non_neg_integer()],
          two_line: boolean()
        }
end
