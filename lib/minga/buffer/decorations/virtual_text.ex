defmodule Minga.Buffer.Decorations.VirtualText do
  @moduledoc """
  A virtual text decoration: display-only text injected at a buffer position.

  Virtual text is rendered on screen but does not exist in the buffer content.
  The cursor skips over it. Yank ignores it. It occupies screen columns (for
  inline/EOL) or screen rows (for above/below) and the viewport accounts for
  its dimensions, but buffer operations are unaware of it.

  ## Placement modes

  - `:inline` - text appears at the anchor column, pushing subsequent buffer
    content to the right on the same line
  - `:eol` - text appears after the last character of the anchor line,
    separated by at least one space
  - `:above` - entire styled lines injected above the anchor line
  - `:below` - entire styled lines injected below the anchor line
  """

  alias Minga.Buffer.IntervalTree
  alias Minga.Buffer.Unicode

  @enforce_keys [:id, :anchor, :segments, :placement]
  defstruct id: nil,
            anchor: {0, 0},
            segments: [],
            placement: :eol,
            priority: 0,
            group: nil

  @typedoc """
  A styled text segment: the text string and its style properties.
  """
  @type segment :: {text :: String.t(), style :: keyword()}

  @typedoc """
  Placement mode for virtual text.

  - `:inline` - at the anchor column, displacing buffer content rightward
  - `:eol` - after the last character of the anchor line
  - `:above` - full lines injected above the anchor line
  - `:below` - full lines injected below the anchor line
  """
  @type placement :: :inline | :eol | :above | :below

  @type t :: %__MODULE__{
          id: reference(),
          anchor: IntervalTree.position(),
          segments: [segment()],
          placement: placement(),
          priority: integer(),
          group: term() | nil
        }

  @doc "Returns the total display width of the virtual text segments."
  @spec display_width(t()) :: non_neg_integer()
  def display_width(%__MODULE__{segments: segments}) do
    segments_display_width(segments)
  end

  @doc "Returns the total display width of a list of styled segments."
  @spec segments_display_width([segment()]) :: non_neg_integer()
  def segments_display_width(segments) do
    Enum.reduce(segments, 0, fn {text, _style}, acc ->
      acc + Unicode.display_width(text)
    end)
  end
end
