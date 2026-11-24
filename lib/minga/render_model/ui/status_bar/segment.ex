defmodule Minga.RenderModel.UI.StatusBar.Segment do
  @moduledoc """
  One modeline segment: what it says, how it is drawn, what a click does, and when it gives way to a narrow window.

  The BEAM decides the segments, their order and their drop ranks. A frontend measures its own width (ADR-0001) and applies the ranks in ascending order until the modeline fits: every segment at the lowest remaining rank is removed together, except a segment with a `compact` form, which collapses to its state mark and `compact` text instead. A segment with `drop: 0` never drops.

  Built-in segment ids, left to right: `:mode`, `:needs_you`, `:filename`, `:change`, `:git`, `:minga`, `:errors`, `:warnings`, `:problem`, then `:filetype` and `:position` in the right cluster. Optional built-in segments and user or extension segments keep the name they were configured with.

  `state` names a design-token state (`Minga.Design.Tokens`); frontends draw its mark (shape on macOS, glyph in the TUI) before the text. `key` is the key that does what a click does, for tooltips and accessibility hints, and `label` says what the segment means in words ("1 task needs you").
  """

  alias Minga.Design.Tokens

  @typedoc "A text style option, as custom modeline segments declare them."
  @type style :: keyword()

  @type t :: %__MODULE__{
          id: atom(),
          text: String.t(),
          fg: non_neg_integer(),
          bg: non_neg_integer(),
          style: style(),
          target: atom() | nil,
          drop: non_neg_integer(),
          compact: String.t() | nil,
          state: Tokens.state_id() | nil,
          key: String.t(),
          label: String.t()
        }

  @enforce_keys [:id, :text, :fg, :bg]
  defstruct [
    :id,
    :text,
    :fg,
    :bg,
    style: [],
    target: nil,
    drop: 0,
    compact: nil,
    state: nil,
    key: "",
    label: ""
  ]
end
