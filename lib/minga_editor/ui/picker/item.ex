defmodule MingaEditor.UI.Picker.Item do
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
  - `:search_text` — hidden text included in fuzzy matching but not rendered
  - `:match_positions` — 0-based character indices of matched characters in the
    label, computed during fuzzy filtering for rendering highlights
  - `:two_line` — when true, renders description on a second line below the label
    instead of inline. Used by file/buffer pickers for path display.
  - `:description_overflow` — which end of the description a frontend keeps when
    the description does not fit. `:keep_end` (the default) suits paths, where the
    file name at the end matters most. `:keep_start` suits status text that leads
    with the important facts, such as a model row's readiness and plan usage.
  - `:active` — when true, marks this item as the currently active selection
    (e.g. the current thinking level). The centered picker renderer draws a
    `●` indicator for active items and blank padding for inactive siblings.
  - `:meta` — opaque source-private map carried alongside the item. Used by
    sources that defer display enrichment (e.g. `FileSource` stashes the git
    status here so the bounded winners can be enriched without re-reading state).
    Never rendered directly.
  """

  @enforce_keys [:id, :label]
  defstruct [
    :id,
    :label,
    description: "",
    icon_color: nil,
    annotation: nil,
    search_text: "",
    match_positions: [],
    two_line: false,
    description_overflow: :keep_end,
    active: false,
    meta: %{}
  ]

  @typedoc "Which end of the description survives when a frontend must shorten it."
  @type description_overflow :: :keep_end | :keep_start

  @type t :: %__MODULE__{
          id: term(),
          label: String.t(),
          description: String.t(),
          icon_color: non_neg_integer() | nil,
          annotation: String.t() | nil,
          search_text: String.t(),
          match_positions: [non_neg_integer()],
          two_line: boolean(),
          description_overflow: description_overflow(),
          active: boolean(),
          meta: map()
        }
end
