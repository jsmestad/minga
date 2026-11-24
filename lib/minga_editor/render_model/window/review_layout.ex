defmodule MingaEditor.RenderModel.Window.ReviewLayout do
  @moduledoc """
  Wrapping, theme, and syntax inputs for resident read-only review rows.

  Diff status is presented by a gutter sign in the status color and a background tint across the whole row, so syntax foreground colors survive on added and removed lines. Lines without a ready syntax result keep the flat status foreground.
  """

  import Bitwise

  alias Minga.Core.Face
  alias Minga.Core.WidthOracle
  alias Minga.RenderModel.Window.Span
  alias MingaEditor.Agent.DiffReview.DisplayLine
  alias MingaEditor.Agent.ReviewHighlights
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.Theme

  # Share of the status color mixed into the editor background, in percent.
  @line_tint 18
  @header_tint 12

  @enforce_keys [:text_width, :pane_width, :oracle, :theme, :tab_width, :syntax]
  defstruct @enforce_keys

  @typedoc "Ready syntax results for each side of the review, or `nil` while that side renders flat."
  @type syntax :: %{ReviewHighlights.side() => ReviewHighlights.ready() | nil}

  @type t :: %__MODULE__{
          text_width: pos_integer(),
          pane_width: pos_integer(),
          oracle: WidthOracle.t(),
          theme: Theme.t(),
          tab_width: pos_integer(),
          syntax: syntax()
        }

  @no_syntax %{old: nil, new: nil}

  @doc "Captures pane capacity with a stable one-column presentation margin, without deriving rows from pixels."
  @spec new(pos_integer(), WidthOracle.t(), Theme.t(), pos_integer(), syntax()) :: t()
  def new(pane_width, oracle, %Theme{} = theme, tab_width, syntax \\ @no_syntax)
      when is_integer(pane_width) and pane_width > 0 and is_integer(tab_width) and tab_width > 0 and
             is_map(syntax) do
    %__MODULE__{
      text_width: max(pane_width - 1, 1),
      pane_width: pane_width,
      oracle: oracle,
      theme: theme,
      tab_width: tab_width,
      syntax: Map.merge(@no_syntax, syntax)
    }
  end

  @doc "Identifies layout compatibility independently of color changes."
  @spec identity_key(t()) :: tuple()
  def identity_key(%__MODULE__{} = layout) do
    {layout.text_width, WidthOracle.fingerprint(layout.oracle), layout.tab_width}
  end

  @doc "Identifies the exact resolved colors and syntax results used by review rows."
  @spec style_key(t()) :: tuple()
  def style_key(%__MODULE__{theme: theme, syntax: syntax}) do
    {theme.editor.fg, theme.editor.bg, theme.git.added_fg, theme.git.deleted_fg,
     theme.git.modified_fg, theme.syntax, syntax_key(syntax.old), syntax_key(syntax.new)}
  end

  @doc "Builds the syntax highlight for one side, or returns `nil` while that side renders flat."
  @spec highlight(t(), ReviewHighlights.side()) :: Highlight.t() | nil
  def highlight(%__MODULE__{syntax: syntax, theme: theme}, side) do
    case Map.fetch!(syntax, side) do
      nil ->
        nil

      {_key, names, spans} ->
        theme
        |> Highlight.from_theme()
        |> Highlight.put_names(names)
        |> Highlight.put_spans(1, ReviewHighlights.unpack_spans(spans))
    end
  end

  @doc """
  Styles one diff line as the gutter sign followed by its code.

  `segments` are the syntax-styled pieces of the line text, or `nil` for the flat status color. Every face carries the line's background tint.
  """
  @spec styled_line(t(), DisplayLine.kind(), String.t(), [Highlight.styled_segment()] | nil) ::
          [Highlight.styled_segment()]
  def styled_line(%__MODULE__{theme: theme}, kind, text, segments) do
    bg = background(theme, kind)
    sign = {prefix(kind), %Face{name: "agent.review.sign", fg: status_fg(theme, kind), bg: bg}}
    [sign | code_segments(theme, kind, text, segments, bg)]
  end

  @doc "Extends a tinted row's background from `start_col` to the pane edge. Untinted rows get no span."
  @spec fill(t(), DisplayLine.kind(), non_neg_integer()) :: [Span.t()]
  def fill(%__MODULE__{theme: theme, pane_width: width}, kind, start_col) do
    case background(theme, kind) do
      nil -> []
      _bg when start_col >= width -> []
      bg -> [Span.from_face(%Face{name: "agent.review.fill", bg: bg}, start_col, width)]
    end
  end

  @spec code_segments(
          Theme.t(),
          DisplayLine.kind(),
          String.t(),
          [Highlight.styled_segment()] | nil,
          Theme.color() | nil
        ) :: [Highlight.styled_segment()]
  defp code_segments(theme, kind, text, nil, bg) do
    [
      {text,
       %Face{name: "agent.review", fg: status_fg(theme, kind), bg: bg, bold: kind == :hunk_header}}
    ]
  end

  defp code_segments(theme, _kind, _text, segments, bg) do
    Enum.map(segments, fn {part, face} ->
      {part, %{face | fg: face.fg || theme.editor.fg, bg: bg}}
    end)
  end

  @spec prefix(DisplayLine.kind()) :: String.t()
  defp prefix(:context), do: "  "
  defp prefix(:added), do: "+ "
  defp prefix(:removed), do: "- "
  defp prefix(:hunk_header), do: ""

  @spec status_fg(Theme.t(), DisplayLine.kind()) :: Theme.color()
  defp status_fg(theme, :context), do: theme.editor.fg
  defp status_fg(theme, :added), do: theme.git.added_fg
  defp status_fg(theme, :removed), do: theme.git.deleted_fg
  defp status_fg(theme, :hunk_header), do: theme.git.modified_fg

  @spec background(Theme.t(), DisplayLine.kind()) :: Theme.color() | nil
  defp background(_theme, :context), do: nil
  defp background(theme, :added), do: tint(theme.editor.bg, theme.git.added_fg, @line_tint)
  defp background(theme, :removed), do: tint(theme.editor.bg, theme.git.deleted_fg, @line_tint)

  defp background(theme, :hunk_header),
    do: tint(theme.editor.bg, theme.git.modified_fg, @header_tint)

  # Mixing toward the status color keeps the tint subtle on dark and light backgrounds alike.
  @spec tint(Theme.color(), Theme.color(), 0..100) :: Theme.color()
  defp tint(bg, color, percent) do
    red = mix(channel(bg, 16), channel(color, 16), percent)
    green = mix(channel(bg, 8), channel(color, 8), percent)
    blue = mix(channel(bg, 0), channel(color, 0), percent)
    bor(bor(bsl(red, 16), bsl(green, 8)), blue)
  end

  @spec channel(Theme.color(), 0 | 8 | 16) :: 0..255
  defp channel(color, shift), do: band(bsr(color, shift), 0xFF)

  @spec mix(0..255, 0..255, 0..100) :: 0..255
  defp mix(base, color, percent), do: div(base * (100 - percent) + color * percent + 50, 100)

  @spec syntax_key(ReviewHighlights.ready() | nil) :: ReviewHighlights.key() | nil
  defp syntax_key(nil), do: nil
  defp syntax_key({key, _names, _spans}), do: key
end
