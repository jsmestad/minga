defmodule MingaEditor.UI.Picker.Item do
  @moduledoc """
  A single candidate in a picker list.

  Every picker source returns a list of `%Item{}` structs. The struct
  carries both display data (label, description, icon color) and
  identity (id) for selection callbacks.

  ## Required fields

  - `:id`: unique identifier (file path, buffer index, command atom, etc.)
  - `:label`: display text shown in the picker, used for fuzzy matching

  ## Optional fields

  - `:description`: secondary text shown beside or below the label. Frontends choose the layout. A row without a status keeps the end of a long description (paths, where the file name matters most). A row with a status keeps the start of its description.
  - `:icon_color`: 24-bit RGB color for the first grapheme (the icon) of the label
  - `:annotation`: right-aligned metadata (keybinding, favorite marker), styled distinctly from the description (e.g., "SPC f s" for commands)
  - `:status`: an `Item.Status` chip (text and tone), such as a model row's readiness and plan usage. Frontends always show it and render its text verbatim. A row with a status shows its description on a second line (macOS) or keeps the chip while the description shortens (terminal).
  - `:search_text`: hidden text included in fuzzy matching but not rendered
  - `:match_positions`: 0-based character indices of matched characters in the
    label, computed during fuzzy filtering for rendering highlights
  - `:active`: when true, marks this item as the current value (e.g. the current model or thinking level). Frontends draw a current-value marker on the row, such as a filled dot.
  - `:meta`: opaque source-private map carried alongside the item. Used by
    sources that defer display enrichment (e.g. `FileSource` stashes the git
    status here so the bounded winners can be enriched without re-reading state).
    Never rendered directly.
  """

  alias MingaEditor.UI.Picker.Item.Status

  @enforce_keys [:id, :label]
  defstruct [
    :id,
    :label,
    description: "",
    icon_color: nil,
    annotation: nil,
    status: nil,
    search_text: "",
    match_positions: [],
    active: false,
    meta: %{}
  ]

  @type t :: %__MODULE__{
          id: term(),
          label: String.t(),
          description: String.t(),
          icon_color: non_neg_integer() | nil,
          annotation: String.t() | nil,
          status: Status.t() | nil,
          search_text: String.t(),
          match_positions: [non_neg_integer()],
          active: boolean(),
          meta: map()
        }
end
