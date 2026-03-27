defmodule Minga.Core.Decorations.LineAnnotation do
  @moduledoc """
  A line annotation decoration: structured metadata attached to a buffer line.

  Annotations display visual metadata alongside buffer content without
  modifying the text. They come in three kinds:

  - `:inline_pill` - colored pill badge (rounded rect background + text)
    rendered after line content. Used for tags, labels, status indicators.
  - `:inline_text` - styled text (no background pill) rendered after line
    content. Used for git blame, inline hints, dimmed annotations.
  - `:gutter_icon` - icon or symbol rendered in the gutter sign column.
    Used for bookmarks, breakpoints, markers.

  Each frontend renders annotations according to its capabilities:
  - **GUI (Swift/Metal):** pills as CoreText bitmaps with rounded rect
    backgrounds; inline text as styled runs; gutter icons natively.
  - **TUI (Zig/libvaxis):** pills as space-padded text with terminal
    background color; inline text as dimmed text; gutter icons as
    characters in the sign column.

  ## Examples

      %LineAnnotation{
        id: make_ref(),
        line: 5,
        text: "work",
        kind: :inline_pill,
        fg: 0xFFFFFF,
        bg: 0x6366F1,
        group: :org_tags,
        priority: 0
      }
  """

  @enforce_keys [:id, :line, :text, :kind]
  defstruct id: nil,
            line: 0,
            text: "",
            kind: :inline_pill,
            fg: 0xFFFFFF,
            bg: 0x6366F1,
            group: nil,
            priority: 0

  @typedoc "The visual kind of annotation."
  @type kind :: :inline_pill | :inline_text | :gutter_icon

  @type t :: %__MODULE__{
          id: reference(),
          line: non_neg_integer(),
          text: String.t(),
          kind: kind(),
          fg: non_neg_integer(),
          bg: non_neg_integer(),
          group: term() | nil,
          priority: integer()
        }
end
