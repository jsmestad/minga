defmodule Minga.Editor.HoverPopup do
  @moduledoc """
  State and rendering for LSP hover tooltips.

  Parses LSP hover markdown content into styled display list draws and
  renders them in a cursor-anchored floating window. Supports scrolling
  for long content (j/k when focused) and the LazyVim pattern of
  pressing K once to show, K again to focus into the hover for scrolling.

  ## Lifecycle

  1. LSP hover response arrives with markdown content
  2. `new/3` creates the popup state with parsed content
  3. The render pipeline renders it as an overlay via `render/3`
  4. Any keypress (except K/j/k when focused) dismisses the popup
  """

  alias MingaAgent.Markdown
  alias Minga.Editor.DisplayList
  alias Minga.Editor.FloatingWindow
  alias Minga.Editor.MarkdownStyles

  @enforce_keys [:content_lines, :anchor_row, :anchor_col]
  defstruct content_lines: [],
            anchor_row: 0,
            anchor_col: 0,
            scroll_offset: 0,
            focused: false

  @typedoc "A hover popup state."
  @type t :: %__MODULE__{
          content_lines: [Markdown.parsed_line()],
          anchor_row: non_neg_integer(),
          anchor_col: non_neg_integer(),
          scroll_offset: non_neg_integer(),
          focused: boolean()
        }

  @max_width 60
  @max_height 20
  @min_width 30

  @doc """
  Creates a new hover popup from LSP hover content.

  Parses the markdown content and anchors the popup at the given
  cursor position.
  """
  @spec new(String.t(), non_neg_integer(), non_neg_integer()) :: t()
  def new(markdown_text, cursor_row, cursor_col) do
    content_lines = Markdown.parse(markdown_text)

    %__MODULE__{
      content_lines: content_lines,
      anchor_row: cursor_row,
      anchor_col: cursor_col
    }
  end

  @doc "Focus into the hover popup for scrolling."
  @spec focus(t()) :: t()
  def focus(%__MODULE__{} = popup), do: %{popup | focused: true}

  @doc "Scroll content down (later lines visible)."
  @spec scroll_down(t()) :: t()
  def scroll_down(%__MODULE__{} = popup) do
    max_offset = max(length(popup.content_lines) - 3, 0)
    %{popup | scroll_offset: min(popup.scroll_offset + 3, max_offset)}
  end

  @doc "Scroll content up."
  @spec scroll_up(t()) :: t()
  def scroll_up(%__MODULE__{} = popup) do
    %{popup | scroll_offset: max(popup.scroll_offset - 3, 0)}
  end

  @doc """
  Renders the hover popup as a list of display list draws.

  Returns an empty list if the content is empty. The draws are
  absolute screen coordinates ready for an Overlay.
  """
  @spec render(t(), {pos_integer(), pos_integer()}, map()) :: [DisplayList.draw()]
  def render(%__MODULE__{content_lines: []}, _viewport, _theme), do: []

  def render(%__MODULE__{} = popup, viewport, theme) do
    {vp_rows, vp_cols} = viewport
    popup_theme = Map.get(theme, :popup, default_popup_theme())

    # Compute content draws with styling
    {content_draws, content_width, content_height} =
      build_content_draws(popup.content_lines, popup.scroll_offset, vp_cols, theme)

    # Size the window to fit content, clamped to limits
    width = content_width |> max(@min_width) |> min(@max_width) |> min(vp_cols - 2)
    height = content_height |> min(@max_height) |> min(vp_rows - 4)

    # Add 2 for border
    total_width = width + 2
    total_height = height + 2

    # Scrollbar indicator in footer
    total_lines = length(popup.content_lines)

    footer =
      if total_lines > height do
        visible_end = min(popup.scroll_offset + height, total_lines)
        "#{popup.scroll_offset + 1}-#{visible_end}/#{total_lines}"
      else
        nil
      end

    # Focus indicator in border
    border_style = if popup.focused, do: :single, else: :rounded

    spec = %FloatingWindow.Spec{
      content: content_draws,
      width: {:cols, total_width},
      height: {:rows, total_height},
      position: {:anchor, popup.anchor_row, popup.anchor_col, :above},
      border: border_style,
      footer: footer,
      theme: popup_theme,
      viewport: viewport
    }

    FloatingWindow.render(spec)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @spec build_content_draws(
          [Markdown.parsed_line()],
          non_neg_integer(),
          pos_integer(),
          map()
        ) :: {[DisplayList.draw()], non_neg_integer(), non_neg_integer()}
  defp build_content_draws(lines, scroll_offset, max_width, theme) do
    # Take lines from scroll_offset, limit to a reasonable max
    visible_lines = Enum.drop(lines, scroll_offset)

    {draws, max_col, row} =
      Enum.reduce(visible_lines, {[], 0, 0}, fn {segments, line_type}, {acc, max_w, row} ->
        line_draws = render_line_segments(segments, line_type, row, max_width, theme)

        line_width =
          segments
          |> Enum.map(fn {text, _style} -> String.length(text) end)
          |> Enum.sum()

        {line_draws ++ acc, max(max_w, line_width), row + 1}
      end)

    {Enum.reverse(draws), max_col, row}
  end

  @spec render_line_segments(
          [Markdown.segment()],
          Markdown.line_type(),
          non_neg_integer(),
          pos_integer(),
          map()
        ) :: [DisplayList.draw()]
  defp render_line_segments(segments, _line_type, row, max_width, theme) do
    syntax = Map.get(theme, :syntax, %{})
    editor = Map.get(theme, :editor, %{})
    base_fg = Map.get(editor, :fg, 0xBBC2CF)

    {draws, _col} =
      Enum.reduce(segments, {[], 0}, fn {text, style}, {acc, col} ->
        text_len = String.length(text)

        if col >= max_width - 2 do
          {acc, col}
        else
          clipped = String.slice(text, 0, max(max_width - 2 - col, 0))
          draw_style = MarkdownStyles.to_draw_opts(style, syntax, base_fg)
          draw = DisplayList.draw(row, col, clipped, draw_style)
          {[draw | acc], col + text_len}
        end
      end)

    Enum.reverse(draws)
  end

  @spec default_popup_theme() :: map()
  defp default_popup_theme do
    %{bg: 0x21242B, border_fg: 0x5B6268, title_fg: 0xBBC2CF}
  end
end
