defmodule MingaEditor.Agent.MarkdownHighlight do
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

  alias Minga.Parser.Manager, as: ParserManager
  alias MingaAgent.Markdown
  alias Minga.RenderModel.UI.AgentChat.MarkdownBlock
  alias MingaEditor.UI.Highlight

  @typedoc "A single styled text run: {text, fg_rgb, bg_rgb, flags} or {text, fg_rgb, bg_rgb, flags, url}."
  @type styled_run ::
          {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()}

  @typedoc "A line of styled runs."
  @type styled_line :: [styled_run()]

  @typedoc "All styled lines for a message."
  @type styled_lines :: [styled_line()]

  # Flag bits for the protocol encoding
  @flag_bold 0x01
  @flag_italic 0x02
  @flag_underline 0x04
  @flag_link 0x08
  @flag_code 0x10
  @snippet_highlight_timeout_ms 50

  @type highlighter_result ::
          {:ok, [String.t()], [Minga.Language.Highlight.Span.t()]}
          | :unsupported
          | :timeout
          | :unavailable
          | {:error, term()}
          | nil

  @type highlighter :: (String.t(), String.t(), keyword() -> highlighter_result())

  @typep render_context :: %{
           text: String.t(),
           highlight: Highlight.t() | nil,
           theme_syntax: map(),
           message_id: non_neg_integer(),
           buffer_byte_offset: non_neg_integer(),
           highlighter: highlighter()
         }

  @typep code_context :: %{
           highlight: Highlight.t() | nil,
           theme_syntax: map(),
           text: String.t(),
           buffer_byte_offset: non_neg_integer(),
           highlighter: highlighter()
         }

  @doc """
  Converts assistant message text to semantic markdown blocks for GUI code-card rendering.

  Inline code remains a styled-run flag inside paragraph/list/heading runs. Fenced code becomes an explicit `MarkdownBlock` code block; frontends should render cards from this block kind, not from `0x10`.
  """
  @spec render_blocks(
          String.t(),
          Highlight.t() | nil,
          map(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: [MarkdownBlock.t()]
  def render_blocks(
        text,
        highlight,
        theme_syntax,
        message_id,
        buffer_byte_offset \\ 0,
        opts \\ []
      )
      when is_binary(text) and is_list(opts) do
    highlighter = Keyword.get(opts, :highlighter, &ParserManager.highlight_source/3)

    context = %{
      text: text,
      highlight: highlight,
      theme_syntax: theme_syntax,
      message_id: message_id,
      buffer_byte_offset: buffer_byte_offset,
      highlighter: highlighter
    }

    text |> Markdown.parse_blocks() |> Enum.with_index() |> render_parsed_blocks(context, 0, [])
  end

  @spec render_parsed_blocks(
          [{Markdown.block(), non_neg_integer()}],
          render_context(),
          non_neg_integer(),
          [MarkdownBlock.t()]
        ) :: [MarkdownBlock.t()]
  defp render_parsed_blocks([], _context, _code_index, acc) do
    Enum.reverse(acc)
  end

  defp render_parsed_blocks([{block, index} | rest], context, code_index, acc) do
    id = block_id(context.message_id, index)

    {rendered, next_code_index} =
      render_block(
        block,
        id,
        context,
        code_index
      )

    render_parsed_blocks(rest, context, next_code_index, [rendered | acc])
  end

  @spec render_block(
          Markdown.block(),
          non_neg_integer(),
          render_context(),
          non_neg_integer()
        ) :: {MarkdownBlock.t(), non_neg_integer()}
  defp render_block(%{kind: :paragraph, lines: lines}, id, context, code_index) do
    theme_syntax = context.theme_syntax

    {MarkdownBlock.paragraph(id, Enum.map(lines, &inline_line_to_runs(&1, theme_syntax))),
     code_index}
  end

  defp render_block(%{kind: :heading, level: level, text: heading}, id, context, code_index) do
    theme_syntax = context.theme_syntax
    line = [{heading, header_fg(theme_syntax), 0, @flag_bold}]
    {MarkdownBlock.heading(id, level, [line]), code_index}
  end

  defp render_block(
         %{kind: :list_item, indent: indent, ordered: ordered?, ordinal: ordinal, text: text},
         id,
         context,
         code_index
       ) do
    theme_syntax = context.theme_syntax
    prefix = if ordered?, do: "#{ordinal}. ", else: "• "
    lines = [inline_line_to_runs(String.duplicate("  ", indent) <> prefix <> text, theme_syntax)]
    {MarkdownBlock.list_item(id, indent, ordered?, ordinal, lines), code_index}
  end

  defp render_block(%{kind: :blockquote, lines: lines}, id, context, code_index) do
    theme_syntax = context.theme_syntax

    rendered =
      Enum.map(lines, fn line ->
        [
          {"│ ", comment_fg(theme_syntax), 0, @flag_italic}
          | inline_line_to_runs(line, theme_syntax)
        ]
      end)

    {MarkdownBlock.blockquote(id, rendered), code_index}
  end

  defp render_block(%{kind: :rule}, id, _context, code_index) do
    {MarkdownBlock.rule(id), code_index}
  end

  defp render_block(%{kind: :spacer, height: height}, id, _context, code_index) do
    {MarkdownBlock.spacer(id, height), code_index}
  end

  defp render_block(
         %{kind: :code_block, language: language, lines: lines, complete?: complete?},
         id,
         context,
         code_index
       ) do
    text = context.text
    target_path = Markdown.infer_target_path(text, code_index)
    label = code_label(language)

    rendered_lines =
      code_lines_to_runs(
        lines,
        complete?,
        %{
          highlight: context.highlight,
          theme_syntax: context.theme_syntax,
          text: text,
          buffer_byte_offset: context.buffer_byte_offset,
          highlighter: context.highlighter
        },
        code_index,
        language
      )

    {MarkdownBlock.code_block(id, language, label, target_path, complete?, rendered_lines),
     code_index + 1}
  end

  @spec inline_line_to_runs(String.t(), map()) :: styled_line()
  defp inline_line_to_runs(line, theme_syntax) do
    line
    |> Markdown.parse_inline()
    |> Enum.map(fn {segment, style} -> style_to_run(segment, style, theme_syntax) end)
  end

  @spec code_lines_to_runs(
          [String.t()],
          boolean(),
          code_context(),
          non_neg_integer(),
          String.t()
        ) :: [styled_line()]
  defp code_lines_to_runs(lines, false, context, _code_index, _language) do
    plain_code_lines_to_runs(lines, context.theme_syntax)
  end

  defp code_lines_to_runs(lines, true, context, code_index, language) do
    theme_syntax = context.theme_syntax

    case code_highlight_source(
           context.highlight,
           lines,
           language,
           theme_syntax,
           context.highlighter
         ) do
      {:full_message, full_highlight} ->
        highlighted_code_lines_to_runs(
          lines,
          full_highlight,
          theme_syntax,
          context.text,
          context.buffer_byte_offset,
          code_index
        )

      {:snippet, snippet_highlight} ->
        highlighted_snippet_lines_to_runs(lines, snippet_highlight, theme_syntax)

      :none ->
        plain_code_lines_to_runs(lines, theme_syntax)
    end
  end

  @spec plain_code_lines_to_runs([String.t()], map()) :: [styled_line()]
  defp plain_code_lines_to_runs(lines, theme_syntax) do
    Enum.map(lines, fn line ->
      [{line, code_fg(theme_syntax), code_bg(theme_syntax), @flag_code}]
    end)
  end

  @spec code_highlight_source(Highlight.t() | nil, [String.t()], String.t(), map(), highlighter()) ::
          {:full_message, Highlight.t()} | {:snippet, Highlight.t()} | :none
  defp code_highlight_source(
         %Highlight{} = highlight,
         _lines,
         _language,
         _theme_syntax,
         _highlighter
       ) do
    if has_spans?(highlight), do: {:full_message, highlight}, else: :none
  end

  defp code_highlight_source(_highlight, lines, language, theme_syntax, highlighter) do
    case snippet_highlight(lines, language, theme_syntax, highlighter) do
      %Highlight{} = snippet -> {:snippet, snippet}
      nil -> :none
    end
  end

  @spec snippet_highlight([String.t()], String.t(), map(), highlighter()) :: Highlight.t() | nil
  defp snippet_highlight(_lines, "", _theme_syntax, _highlighter), do: nil

  defp snippet_highlight(lines, language, theme_syntax, highlighter) do
    source = Enum.join(lines, "\n")

    case highlighter.(language, source, timeout: @snippet_highlight_timeout_ms) do
      {:ok, names, spans} when is_list(names) and is_list(spans) ->
        theme_syntax
        |> Highlight.new()
        |> Highlight.put_names(names)
        |> Highlight.put_spans(1, spans)

      _result ->
        nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
    _kind, _reason -> nil
  end

  @spec highlighted_snippet_lines_to_runs([String.t()], Highlight.t(), map()) :: [styled_line()]
  defp highlighted_snippet_lines_to_runs(lines, highlight, theme_syntax) do
    lines
    |> Enum.reduce({[], 0}, fn line, {acc, byte_offset} ->
      segments = Highlight.styles_for_line(highlight, line, byte_offset)
      next_byte_offset = byte_offset + byte_size(line) + 1
      {[highlighted_segments_to_runs(segments, line, theme_syntax) | acc], next_byte_offset}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec highlighted_segments_to_runs([Highlight.styled_segment()], String.t(), map()) ::
          styled_line()
  defp highlighted_segments_to_runs(segments, original_line, theme_syntax) do
    case segments do
      [{^original_line, %Minga.Core.Face{fg: nil}}] ->
        [{original_line, code_fg(theme_syntax), code_bg(theme_syntax), @flag_code}]

      _ ->
        Enum.map(segments, &segment_to_run(&1, code_bg(theme_syntax)))
    end
  end

  @spec highlighted_code_lines_to_runs(
          [String.t()],
          Highlight.t(),
          map(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [styled_line()]
  defp highlighted_code_lines_to_runs(
         lines,
         highlight,
         theme_syntax,
         text,
         buffer_byte_offset,
         code_index
       ) do
    original_lines = String.split(text, "\n")
    line_byte_offsets = compute_line_byte_offsets(original_lines)
    start_idx = code_content_start_line(original_lines, code_index)

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, relative_idx} ->
      line_idx = start_idx + relative_idx
      original_line = Enum.at(original_lines, line_idx, line)
      line_start_byte = buffer_byte_offset + Map.get(line_byte_offsets, line_idx, 0)
      segments = Highlight.styles_for_line(highlight, original_line, line_start_byte)

      highlighted_segments_to_runs(segments, original_line, theme_syntax)
    end)
  end

  @spec code_content_start_line([String.t()], non_neg_integer()) :: non_neg_integer()
  defp code_content_start_line(lines, target_code_index) do
    lines
    |> Enum.with_index()
    |> Enum.reduce_while({false, 0}, fn {line, idx}, {inside_code?, code_index} ->
      if fence_line?(line) do
        code_content_start_line_step(inside_code?, code_index, target_code_index, idx)
      else
        {:cont, {inside_code?, code_index}}
      end
    end)
    |> case do
      {:found, line_idx} -> line_idx
      {_inside_code?, _code_index} -> 0
    end
  end

  @spec code_content_start_line_step(
          boolean(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:halt, {:found, non_neg_integer()}} | {:cont, {boolean(), non_neg_integer()}}
  defp code_content_start_line_step(false, code_index, target_code_index, idx)
       when code_index == target_code_index do
    {:halt, {:found, idx + 1}}
  end

  defp code_content_start_line_step(false, code_index, _target_code_index, _idx) do
    {:cont, {true, code_index}}
  end

  defp code_content_start_line_step(true, code_index, _target_code_index, _idx) do
    {:cont, {false, code_index + 1}}
  end

  @spec code_label(String.t()) :: String.t()
  defp code_label(""), do: "Code"
  defp code_label("elixir"), do: "Elixir"
  defp code_label("ex"), do: "Elixir"
  defp code_label("python"), do: "Python"
  defp code_label("py"), do: "Python"
  defp code_label("swift"), do: "Swift"
  defp code_label("go"), do: "Go"
  defp code_label("rust"), do: "Rust"
  defp code_label("sh"), do: "Shell"
  defp code_label("bash"), do: "Shell"
  defp code_label("zsh"), do: "Shell"
  defp code_label("javascript"), do: "JavaScript"
  defp code_label("js"), do: "JavaScript"
  defp code_label("typescript"), do: "TypeScript"
  defp code_label("ts"), do: "TypeScript"

  defp code_label(language) do
    language
    |> String.split(~r/[\s,]/, parts: 2)
    |> hd()
    |> String.trim()
    |> case do
      "" -> "Code"
      value -> String.capitalize(value)
    end
  end

  @spec block_id(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp block_id(message_id, block_index),
    do: :erlang.phash2({message_id, block_index}, 4_294_967_296)

  @doc """
  Converts assistant message text to styled runs for the GUI.

  Always uses the regex-based Markdown parser for structure (strips
  syntax markers). When tree-sitter highlights are available, overlays
  per-language syntax highlighting onto fenced code block content lines.

  `buffer_byte_offset` is the starting byte offset of this message's text within the full transcript markdown used for highlighting. Required for aligning tree-sitter spans with per-message line content.
  """
  @spec stylize(String.t(), Highlight.t() | nil, map(), non_neg_integer()) :: styled_lines()
  def stylize(text, highlight, theme_syntax, buffer_byte_offset \\ 0)
      when is_binary(text) do
    # Always parse with regex for clean structure rendering
    parsed = Markdown.parse(text)

    base_lines =
      Enum.map(parsed, fn {segments, _line_type} ->
        Enum.map(segments, fn {seg_text, style_atom} ->
          style_to_run(seg_text, style_atom, theme_syntax)
        end)
      end)

    # Overlay tree-sitter highlights on code block content lines. While a
    # streamed fence is still open, keep the block plain monospaced so syntax
    # colors do not churn token-by-token.
    if has_spans?(highlight) and not open_fence?(text) do
      overlay_code_blocks(base_lines, parsed, text, highlight, theme_syntax, buffer_byte_offset)
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
          map(),
          non_neg_integer()
        ) :: [styled_line()]
  defp overlay_code_blocks(
         base_lines,
         parsed,
         original_text,
         highlight,
         theme_syntax,
         buffer_byte_offset
       ) do
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
        theme_syntax,
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
          map(),
          non_neg_integer()
        ) :: styled_line()
  defp overlay_line(
         base_runs,
         :code,
         line_idx,
         original_lines,
         line_byte_offsets,
         highlight,
         theme_syntax,
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
        [{^original_line, %Minga.Core.Face{fg: nil}}] -> base_runs
        _ -> Enum.map(segments, &segment_to_run(&1, code_bg(theme_syntax)))
      end
    end
  end

  defp overlay_line(
         base_runs,
         _line_type,
         _idx,
         _orig,
         _offsets,
         _hl,
         _theme_syntax,
         _byte_offset
       ) do
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

  @spec segment_to_run(Highlight.styled_segment(), non_neg_integer()) :: styled_run()
  defp segment_to_run({text, %Minga.Core.Face{} = face}, default_bg) do
    fg = face.fg || 0
    bg = face.bg || default_bg

    flags =
      if(face.bold, do: @flag_bold, else: 0) +
        if(face.italic, do: @flag_italic, else: 0) +
        if(face.underline, do: @flag_underline, else: 0) +
        @flag_code

    {text, fg, bg, flags}
  end

  # ── Regex-based style mapping ──────────────────────────────────────────────

  @spec style_to_run(String.t(), Markdown.style(), map()) :: styled_run()
  defp style_to_run(text, {:link, url}, theme) do
    {fg, bg, flags} = md_style_to_colors({:link, url}, theme)
    {text, fg, bg, flags, url}
  end

  defp style_to_run(text, style, theme) do
    {fg, bg, flags} = md_style_to_colors(style, theme)
    {text, fg, bg, flags}
  end

  @spec md_style_to_colors(Markdown.style(), map()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp md_style_to_colors(:bold, theme), do: {default_fg(theme), 0, @flag_bold}
  defp md_style_to_colors(:italic, theme), do: {default_fg(theme), 0, @flag_italic}

  defp md_style_to_colors(:bold_italic, theme),
    do: {default_fg(theme), 0, @flag_bold + @flag_italic}

  defp md_style_to_colors(:code, theme), do: {code_fg(theme), code_bg(theme), @flag_code}

  defp md_style_to_colors({:link, _url}, theme),
    do: {link_fg(theme), 0, @flag_underline + @flag_link}

  defp md_style_to_colors(:code_block, theme), do: {code_fg(theme), 0, 0}

  defp md_style_to_colors({:code_content, _lang}, theme),
    do: {code_fg(theme), code_bg(theme), @flag_code}

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

  @spec link_fg(map()) :: non_neg_integer()
  defp link_fg(theme), do: theme_color(theme, "markup.link.label", 0x61AFEF)

  @spec theme_color(map(), String.t(), non_neg_integer()) :: non_neg_integer()
  defp theme_color(theme, name, default) do
    case Map.get(theme, name) do
      style when is_list(style) -> Keyword.get(style, :fg, default)
      _ -> default
    end
  end

  @spec has_spans?(Highlight.t() | nil) :: boolean()
  defp has_spans?(nil), do: false
  defp has_spans?(%Highlight{} = highlight), do: Highlight.has_spans?(highlight)
  defp has_spans?(_), do: false

  @spec fence_line?(String.t()) :: boolean()
  defp fence_line?(line), do: String.starts_with?(String.trim_leading(line), "```")

  @spec open_fence?(String.t()) :: boolean()
  defp open_fence?(text) do
    text
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(String.trim_leading(&1), "```"))
    |> rem(2)
    |> Kernel.==(1)
  end
end
