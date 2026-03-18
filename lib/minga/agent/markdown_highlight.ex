defmodule Minga.Agent.MarkdownHighlight do
  @moduledoc """
  Converts agent assistant messages to styled text runs for the GUI.

  Uses a hybrid approach:
  - **Regex-based Markdown parser** for structure (headers, bold, italic,
    inline code, lists, blockquotes, rules). This strips syntax markers
    so the GUI shows clean rendered text, not raw `**` or `##`.
  - **Tree-sitter highlights** overlaid on fenced code block content. This
    gives per-language syntax highlighting (Elixir, Python, etc.) inside
    code blocks, which the regex parser can't do.

  The regex path always runs. Tree-sitter is layered on top for code
  blocks only when highlight spans are available.
  """

  alias Minga.Agent.Markdown
  alias Minga.Highlight

  @typedoc "A single styled text run: {text, fg_rgb, bg_rgb, flags}."
  @type styled_run :: {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "A line of styled runs."
  @type styled_line :: [styled_run()]

  @typedoc "All styled lines for a message."
  @type styled_lines :: [styled_line()]

  # Flag bits for the protocol encoding
  @flag_bold 0x01
  @flag_italic 0x02
  @flag_underline 0x04

  @doc """
  Converts assistant message text to styled runs for the GUI.

  Always uses the regex-based Markdown parser for structure (strips
  syntax markers). When tree-sitter highlights are available, overlays
  per-language syntax highlighting onto fenced code block content lines.

  `buffer_byte_offset` is the starting byte offset of this message's
  text within the full `*Agent*` buffer. Required for aligning
  tree-sitter spans (which reference the full buffer) with per-message
  line content.
  """
  @spec stylize(String.t(), Highlight.t() | nil, map(), non_neg_integer()) :: styled_lines()
  def stylize(text, highlight, theme_syntax, buffer_byte_offset \\ 0)
      when is_binary(text) do
    # Always parse with regex for clean structure rendering
    parsed = Markdown.parse(text)

    # Build the base styled lines from the regex parser
    base_lines =
      Enum.map(parsed, fn {segments, _line_type} ->
        Enum.map(segments, fn {seg_text, style_atom} ->
          {fg, bg, flags} = md_style_to_colors(style_atom, theme_syntax)
          {seg_text, fg, bg, flags}
        end)
      end)

    # Overlay tree-sitter highlights on code block content lines
    if has_spans?(highlight) do
      overlay_code_blocks(base_lines, parsed, text, highlight, buffer_byte_offset)
    else
      base_lines
    end
  end

  # ── Tree-sitter overlay for code blocks ────────────────────────────────────

  # Walks the parsed lines. For code content lines (inside fenced blocks),
  # replaces the regex-styled run with tree-sitter highlighted segments
  # using the correct byte offset into the full buffer.
  #
  # Markdown.parse/1 produces exactly one output entry per input line, so
  # the enumeration index IS the original line index. We use this directly
  # for O(1) byte offset lookups instead of content-based search (which
  # would break on duplicate lines like `end`, empty lines, etc.).
  @spec overlay_code_blocks(
          [styled_line()],
          [Markdown.parsed_line()],
          String.t(),
          Highlight.t(),
          non_neg_integer()
        ) :: [styled_line()]
  defp overlay_code_blocks(base_lines, parsed, original_text, highlight, buffer_byte_offset) do
    original_lines = String.split(original_text, "\n")
    line_byte_offsets = compute_line_byte_offsets(original_lines)

    base_lines
    |> Enum.zip(parsed)
    |> Enum.with_index()
    |> Enum.map(fn {{base_runs, {_segments, line_type}}, line_idx} ->
      overlay_line(
        base_runs,
        line_type,
        line_idx,
        original_lines,
        line_byte_offsets,
        highlight,
        buffer_byte_offset
      )
    end)
  end

  # Only overlay code content lines. Everything else keeps the regex
  # parser's output. Fence lines (``` markers) are :code type but contain
  # syntax markers that the regex parser renders as decorative borders;
  # skip those to keep the clean rendering.
  @spec overlay_line(
          styled_line(),
          Markdown.line_type(),
          non_neg_integer(),
          [String.t()],
          %{non_neg_integer() => non_neg_integer()},
          Highlight.t(),
          non_neg_integer()
        ) :: styled_line()
  defp overlay_line(
         base_runs,
         :code,
         line_idx,
         original_lines,
         line_byte_offsets,
         highlight,
         buffer_byte_offset
       ) do
    original_line = Enum.at(original_lines, line_idx, "")

    # Skip fence lines (``` markers): they should keep the regex parser's
    # decorative rendering, not raw markdown syntax.
    if String.starts_with?(String.trim_leading(original_line), "```") do
      base_runs
    else
      line_start_byte = buffer_byte_offset + Map.get(line_byte_offsets, line_idx, 0)
      segments = Highlight.styles_for_line(highlight, original_line, line_start_byte)

      case segments do
        [{^original_line, %Minga.Face{fg: nil}}] -> base_runs
        _ -> Enum.map(segments, &segment_to_run/1)
      end
    end
  end

  defp overlay_line(base_runs, _line_type, _idx, _orig, _offsets, _hl, _byte_offset) do
    base_runs
  end

  @spec compute_line_byte_offsets([String.t()]) :: %{non_neg_integer() => non_neg_integer()}
  defp compute_line_byte_offsets(lines) do
    {map, _offset} =
      Enum.reduce(Enum.with_index(lines), {%{}, 0}, fn {line, idx}, {acc, offset} ->
        {Map.put(acc, idx, offset), offset + byte_size(line) + 1}
      end)

    map
  end

  @spec segment_to_run(Highlight.styled_segment()) :: styled_run()
  defp segment_to_run({text, %Minga.Face{} = face}) do
    fg = face.fg || 0
    bg = face.bg || 0

    flags =
      if(face.bold, do: @flag_bold, else: 0) +
        if(face.italic, do: @flag_italic, else: 0) +
        if face.underline, do: @flag_underline, else: 0

    {text, fg, bg, flags}
  end

  # ── Regex-based style mapping ──────────────────────────────────────────────

  @spec md_style_to_colors(Markdown.style(), map()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp md_style_to_colors(:bold, theme), do: {default_fg(theme), 0, @flag_bold}
  defp md_style_to_colors(:italic, theme), do: {default_fg(theme), 0, @flag_italic}

  defp md_style_to_colors(:bold_italic, theme),
    do: {default_fg(theme), 0, @flag_bold + @flag_italic}

  defp md_style_to_colors(:code, theme), do: {code_fg(theme), code_bg(theme), 0}
  defp md_style_to_colors(:code_block, theme), do: {code_fg(theme), 0, 0}
  defp md_style_to_colors({:code_content, _lang}, theme), do: {code_fg(theme), code_bg(theme), 0}
  defp md_style_to_colors(:header1, theme), do: {header_fg(theme), 0, @flag_bold}
  defp md_style_to_colors(:header2, theme), do: {header_fg(theme), 0, @flag_bold}
  defp md_style_to_colors(:header3, theme), do: {header_fg(theme), 0, @flag_bold}
  defp md_style_to_colors(:blockquote, theme), do: {comment_fg(theme), 0, @flag_italic}
  defp md_style_to_colors(:list_bullet, theme), do: {default_fg(theme), 0, 0}
  defp md_style_to_colors(:rule, theme), do: {comment_fg(theme), 0, 0}
  defp md_style_to_colors(:plain, theme), do: {default_fg(theme), 0, 0}
  defp md_style_to_colors(_other, theme), do: {default_fg(theme), 0, 0}

  # ── Theme color lookups ────────────────────────────────────────────────────

  @spec default_fg(map()) :: non_neg_integer()
  defp default_fg(theme), do: theme_color(theme, "variable", 0xBBC2CF)

  @spec header_fg(map()) :: non_neg_integer()
  defp header_fg(theme), do: theme_color(theme, "keyword", 0x51AFEF)

  @spec code_fg(map()) :: non_neg_integer()
  defp code_fg(theme), do: theme_color(theme, "string", 0x98BE65)

  @spec code_bg(map()) :: non_neg_integer()
  defp code_bg(theme), do: theme_color(theme, "code_bg", 0x21242B)

  @spec comment_fg(map()) :: non_neg_integer()
  defp comment_fg(theme), do: theme_color(theme, "comment", 0x5B6268)

  @spec theme_color(map(), String.t(), non_neg_integer()) :: non_neg_integer()
  defp theme_color(theme, name, default) do
    case Map.get(theme, name) do
      style when is_list(style) -> Keyword.get(style, :fg, default)
      _ -> default
    end
  end

  @spec has_spans?(Highlight.t() | nil) :: boolean()
  defp has_spans?(nil), do: false
  defp has_spans?(%Highlight{spans: spans}) when is_tuple(spans), do: tuple_size(spans) > 0
  defp has_spans?(%Highlight{spans: spans}) when is_list(spans), do: spans != []
  defp has_spans?(_), do: false
end
