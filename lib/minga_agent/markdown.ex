defmodule MingaAgent.Markdown do
  @moduledoc """
  Simple markdown parser for agent chat rendering.

  Parses a subset of markdown into styled line segments suitable for
  terminal rendering. This is intentionally not a full CommonMark parser;
  it handles the patterns that LLM output commonly uses.

  ## Supported syntax

  - `**bold**` and `__bold__`
  - `*italic*` and `_italic_`
  - `` `inline code` ``
  - `[link text](https://example.com)`
  - Fenced code blocks (``` with optional language tag)
  - Indented code blocks (4 spaces, outside list continuations)
  - `# Headers` (levels 1-3)
  - `- list items` and `* list items`
  - `> blockquotes`
  - Horizontal rules (`---`, `***`, `___`)

  ## Output format

  Returns a list of `{line_segments, line_type}` tuples where each
  `line_segments` is a list of `{text, style}` pairs and `line_type`
  indicates the block context.
  """

  @typedoc "Style attributes for a text segment."
  @type style ::
          :plain
          | :bold
          | :italic
          | :bold_italic
          | :code
          | {:link, String.t()}
          | :code_block
          | {:code_content, String.t()}
          | {:syntax, Minga.Core.Face.t()}
          | :header1
          | :header2
          | :header3
          | :blockquote
          | :list_bullet
          | :rule

  @typedoc "A styled text segment."
  @type segment :: {String.t(), style()}

  @typedoc "Line type indicating block context."
  @type line_type ::
          :text
          | :code
          | {:code_header, String.t()}
          | :header
          | :blockquote
          | :list_item
          | :rule
          | :empty

  @typedoc "A parsed line with its segments and type."
  @type parsed_line :: {[segment()], line_type()}

  @typedoc "Extracted code block with language and content."
  @type code_block :: %{language: String.t(), content: String.t()}

  @typep prose_block ::
           %{
             kind: :paragraph,
             lines: [String.t()]
           }
           | %{
               kind: :heading,
               level: 1..3,
               text: String.t()
             }
           | %{
               kind: :list_item,
               indent: non_neg_integer(),
               ordered: boolean(),
               ordinal: non_neg_integer(),
               text: String.t()
             }
           | %{
               kind: :blockquote,
               lines: [String.t()]
             }
           | %{kind: :rule}
           | %{kind: :spacer, height: pos_integer()}

  @typedoc "Semantic markdown block used by agent chat renderers before styling."
  @type block ::
          prose_block()
          | %{
              kind: :code_block,
              language: String.t(),
              lines: [String.t()],
              complete?: boolean(),
              target_path: String.t() | nil
            }

  @typep pending_block :: prose_block() | {:code_block, String.t(), [String.t()], boolean()}
  @typep block_mode :: {:prose, [String.t()], boolean()} | {:fence, String.t(), [String.t()]}

  @doc """
  Parses markdown into semantic blocks without decorative rendering glyphs.

  This parser intentionally keeps the same small markdown surface as `parse/1`,
  but returns structure that frontends can render directly. Fenced code blocks
  preserve blank lines and indentation, and an unclosed fence is returned as an
  incomplete code block for streaming output.

  Code block target paths use `infer_target_path/2` semantics, with ordinals
  counting both fenced and indented blocks.
  """
  @spec parse_blocks(String.t()) :: [block()]
  def parse_blocks(text) when is_binary(text) do
    lines = String.split(text, "\n")
    {blocks, code_count} = parse_block_lines(lines, [], {:prose, [], false}, 0)
    paths = infer_target_paths(lines, code_count, true, nil, [])
    reverse_blocks_with_paths(blocks, paths, [])
  end

  @spec parse_block_lines([String.t()], [pending_block()], block_mode(), non_neg_integer()) ::
          {[pending_block()], non_neg_integer()}
  defp parse_block_lines([], acc, {:prose, paragraph, _continuation?}, code_count) do
    {finish_paragraph(acc, paragraph), code_count}
  end

  defp parse_block_lines([], acc, {:fence, language, lines}, code_count) do
    {prepend_code_block(acc, language, lines, false), code_count + 1}
  end

  defp parse_block_lines([line | rest], acc, {:fence, language, lines}, code_count) do
    if fence_line?(line) do
      blocks = prepend_code_block(acc, language, lines, true)
      parse_block_lines(rest, blocks, {:prose, [], false}, code_count + 1)
    else
      parse_block_lines(rest, acc, {:fence, language, [line | lines]}, code_count)
    end
  end

  defp parse_block_lines([line | rest], acc, {:prose, paragraph, continuation?}, code_count) do
    case block_line_kind(line, String.trim(line), continuation?) do
      {:code_fence, language} ->
        blocks = finish_paragraph(acc, paragraph)
        parse_block_lines(rest, blocks, {:fence, language, []}, code_count)

      :spacer ->
        blocks = acc |> finish_paragraph(paragraph) |> prepend_spacer()
        parse_block_lines(rest, blocks, {:prose, [], false}, code_count)

      {:indented_code, code_line} ->
        {code_lines, rest} = collect_indented_code_lines(rest, [code_line])
        blocks = acc |> finish_paragraph(paragraph) |> prepend_code_block("", code_lines, true)
        parse_block_lines(rest, blocks, {:prose, [], false}, code_count + 1)

      :paragraph ->
        continuation? = continuation? and indent_width(line) >= 2
        parse_block_lines(rest, acc, {:prose, [line | paragraph], continuation?}, code_count)

      %{kind: kind} = block ->
        blocks = [block | finish_paragraph(acc, paragraph)]
        parse_block_lines(rest, blocks, {:prose, [], kind == :list_item}, code_count)
    end
  end

  @spec finish_paragraph([pending_block()], [String.t()]) :: [pending_block()]
  defp finish_paragraph(acc, []), do: acc

  defp finish_paragraph(acc, paragraph),
    do: [%{kind: :paragraph, lines: Enum.reverse(paragraph)} | acc]

  @spec prepend_code_block([pending_block()], String.t(), [String.t()], boolean()) ::
          [pending_block()]
  defp prepend_code_block(acc, language, lines, complete?),
    do: [{:code_block, language, Enum.reverse(lines), complete?} | acc]

  @spec reverse_blocks_with_paths([pending_block()], [String.t() | nil], [block()]) :: [block()]
  # Once every code path is assigned, the remaining blocks are already prose maps.
  defp reverse_blocks_with_paths(blocks, [], acc), do: Enum.reverse(blocks, acc)

  defp reverse_blocks_with_paths(
         [{:code_block, language, lines, complete?} | rest],
         [path | paths],
         acc
       ) do
    block = %{
      kind: :code_block,
      language: language,
      lines: lines,
      complete?: complete?,
      target_path: path
    }

    reverse_blocks_with_paths(rest, paths, [block | acc])
  end

  defp reverse_blocks_with_paths([block | rest], paths, acc) when is_map(block),
    do: reverse_blocks_with_paths(rest, paths, [block | acc])

  @spec prepend_spacer([pending_block()]) :: [pending_block()]
  defp prepend_spacer([%{kind: :spacer, height: height} = spacer | rest]),
    do: [%{spacer | height: min(height + 1, 255)} | rest]

  defp prepend_spacer(acc), do: [%{kind: :spacer, height: 1} | acc]

  @spec block_line_kind(String.t(), String.t(), boolean()) ::
          :paragraph
          | :spacer
          | {:indented_code, String.t()}
          | {:code_fence, String.t()}
          | prose_block()
  defp block_line_kind(_line, "", _continuation?), do: :spacer

  defp block_line_kind(line, trimmed, continuation?) do
    if not continuation? and indented_block_line?(line, trimmed) do
      {:indented_code, String.slice(line, 4..-1//1)}
    else
      classify_block_line(fence_line?(line), line, trimmed)
    end
  end

  @spec collect_indented_code_lines([String.t()], [String.t()]) :: {[String.t()], [String.t()]}
  defp collect_indented_code_lines([], lines), do: {lines, []}

  defp collect_indented_code_lines([line | rest] = remaining, lines) do
    case String.trim(line) do
      "" -> collect_after_blank_run(rest, remaining, 1, lines)
      trimmed -> collect_indented_line(remaining, trimmed, lines)
    end
  end

  @spec collect_indented_line([String.t()], String.t(), [String.t()]) ::
          {[String.t()], [String.t()]}
  defp collect_indented_line([line | rest] = remaining, trimmed, lines) do
    if indented_block_line?(line, trimmed) do
      collect_indented_code_lines(rest, [String.slice(line, 4..-1//1) | lines])
    else
      {lines, remaining}
    end
  end

  # Keep the original suffix until a nonblank line determines who owns the blank run.
  @spec collect_after_blank_run([String.t()], [String.t()], pos_integer(), [String.t()]) ::
          {[String.t()], [String.t()]}
  defp collect_after_blank_run([], original, _count, lines), do: {lines, original}

  defp collect_after_blank_run([line | rest], original, count, lines) do
    case String.trim(line) do
      "" ->
        collect_after_blank_run(rest, original, count + 1, lines)

      trimmed ->
        if indented_block_line?(line, trimmed) do
          lines = prepend_blank_run(original, count, lines)
          collect_indented_code_lines(rest, [String.slice(line, 4..-1//1) | lines])
        else
          {lines, original}
        end
    end
  end

  @spec prepend_blank_run([String.t()], non_neg_integer(), [String.t()]) :: [String.t()]
  defp prepend_blank_run(_source, 0, lines), do: lines

  defp prepend_blank_run([line | rest], count, lines),
    do: prepend_blank_run(rest, count - 1, [line | lines])

  @spec indented_block_line?(String.t(), String.t()) :: boolean()
  defp indented_block_line?(line, trimmed) do
    indent_width(line) >= 4 and not markdown_list_line?(trimmed)
  end

  @spec classify_block_line(boolean(), String.t(), String.t()) ::
          :paragraph | {:code_fence, String.t()} | prose_block()
  defp classify_block_line(true, line, _trimmed), do: {:code_fence, fence_language(line)}

  defp classify_block_line(false, _line, trimmed) when trimmed in ["---", "***", "___"],
    do: %{kind: :rule}

  defp classify_block_line(false, line, trimmed) do
    classify_non_fence_line(String.match?(trimmed, ~r/^[-*_]{3,}$/), line, trimmed)
  end

  @spec classify_non_fence_line(boolean(), String.t(), String.t()) :: :paragraph | prose_block()
  defp classify_non_fence_line(true, _line, _trimmed), do: %{kind: :rule}

  defp classify_non_fence_line(false, _line, "###" <> text),
    do: %{kind: :heading, level: 3, text: String.trim(text)}

  defp classify_non_fence_line(false, _line, "##" <> text),
    do: %{kind: :heading, level: 2, text: String.trim(text)}

  defp classify_non_fence_line(false, _line, "#" <> text),
    do: %{kind: :heading, level: 1, text: String.trim(text)}

  defp classify_non_fence_line(false, _line, ">" <> text),
    do: %{kind: :blockquote, lines: [String.trim_leading(text)]}

  defp classify_non_fence_line(false, line, "- " <> text), do: list_block(line, text, false, 0)
  defp classify_non_fence_line(false, line, "* " <> text), do: list_block(line, text, false, 0)

  defp classify_non_fence_line(false, line, trimmed) do
    case Regex.run(~r/^(\d+)\.\s+(.*)$/, trimmed) do
      [_, ordinal, text] -> list_block(line, text, true, String.to_integer(ordinal))
      _ -> :paragraph
    end
  end

  @spec list_block(String.t(), String.t(), boolean(), non_neg_integer()) :: prose_block()
  defp list_block(line, text, ordered?, ordinal) do
    %{
      kind: :list_item,
      indent: div(indent_width(line), 2),
      ordered: ordered?,
      ordinal: ordinal,
      text: text
    }
  end

  @spec fence_line?(String.t()) :: boolean()
  defp fence_line?(line), do: String.starts_with?(String.trim_leading(line), "```")

  @spec fence_language(String.t()) :: String.t()
  defp fence_language(line) do
    line
    |> String.trim_leading()
    |> String.replace_prefix("```", "")
    |> String.trim()
  end

  @doc """
  Extracts fenced code blocks from markdown text.

  Returns a list of `%{language: String.t(), content: String.t()}` maps,
  one per fenced code block. The content excludes the fence markers.
  """
  @spec extract_code_blocks(String.t()) :: [code_block()]
  def extract_code_blocks(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> extract_blocks([], nil, [])
    |> Enum.reverse()
  end

  @spec extract_blocks([String.t()], [String.t()], String.t() | nil, [code_block()]) :: [
          code_block()
        ]
  defp extract_blocks([], _current_lines, _lang, acc), do: acc

  defp extract_blocks(["```" <> _ | rest], current_lines, lang, acc) when is_binary(lang) do
    # Closing fence
    content = current_lines |> Enum.reverse() |> Enum.join("\n")
    block = %{language: lang, content: content}
    extract_blocks(rest, [], nil, [block | acc])
  end

  defp extract_blocks(["```" <> lang | rest], _current_lines, nil, acc) do
    # Opening fence
    extract_blocks(rest, [], String.trim(lang), acc)
  end

  defp extract_blocks([line | rest], current_lines, lang, acc) when is_binary(lang) do
    # Inside code block
    extract_blocks(rest, [line | current_lines], lang, acc)
  end

  defp extract_blocks([_line | rest], current_lines, nil, acc) do
    # Outside code block
    extract_blocks(rest, current_lines, nil, acc)
  end

  @doc """
  Infers the target file path for a code block from surrounding markdown text.

  Scans the text before the nth opening fence (0-indexed), or the entire text
  if that fence is absent. Returns the last backtick-wrapped file path, or nil.

  ## Examples

      iex> MingaAgent.Markdown.infer_target_path("Update `lib/foo.ex`:\\n```elixir\\ncode\\n```", 0)
      "lib/foo.ex"

      iex> MingaAgent.Markdown.infer_target_path("No file mentioned\\n```elixir\\ncode\\n```", 0)
      nil
  """
  @spec infer_target_path(String.t(), non_neg_integer()) :: String.t() | nil
  def infer_target_path(text, code_block_index) when is_binary(text) do
    lines = String.split(text, "\n")
    text_before = text_before_nth_code_block(lines, code_block_index)
    extract_last_file_path(text_before)
  end

  @spec text_before_nth_code_block([String.t()], non_neg_integer()) :: String.t()
  defp text_before_nth_code_block(lines, target_index) do
    target_fence = target_index * 2

    {before_lines, _} =
      Enum.reduce_while(lines, {[], 0}, fn line, {acc, fence_count} ->
        accumulate_before_fence(fence_line?(line), line, acc, fence_count, target_fence)
      end)

    before_lines |> Enum.reverse() |> Enum.join("\n")
  end

  @spec accumulate_before_fence(
          boolean(),
          String.t(),
          [String.t()],
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:cont | :halt, {[String.t()], non_neg_integer()}}
  defp accumulate_before_fence(true, _line, acc, fence_count, target_fence)
       when fence_count == target_fence,
       do: {:halt, {acc, fence_count}}

  defp accumulate_before_fence(true, line, acc, fence_count, _target_fence),
    do: {:cont, {[line | acc], fence_count + 1}}

  defp accumulate_before_fence(false, line, acc, fence_count, _target_fence),
    do: {:cont, {[line | acc], fence_count}}

  @file_path_pattern ~r/`([a-zA-Z0-9_\-\.\/]+\.[a-zA-Z0-9]+)`/

  # A path match cannot cross a newline, so scanning each line preserves the
  # prefix regex's non-overlapping matches. Count raw fence lines, independent
  # of how the semantic parser classifies them, and keep paths in reverse order
  # to align with the pending blocks.
  @spec infer_target_paths(
          [String.t()],
          non_neg_integer(),
          boolean(),
          String.t() | nil,
          [String.t() | nil]
        ) :: [String.t() | nil]
  defp infer_target_paths(_lines, 0, _opening?, _last_path, paths), do: paths

  defp infer_target_paths([], remaining, _opening?, last_path, paths) do
    Enum.reduce(1..remaining, paths, fn _, acc -> [last_path | acc] end)
  end

  defp infer_target_paths([line | rest], remaining, opening?, last_path, paths) do
    case fence_line?(line) do
      true when opening? and remaining == 1 ->
        [last_path | paths]

      true when opening? ->
        next_path = extract_last_file_path(line) || last_path
        infer_target_paths(rest, remaining - 1, false, next_path, [last_path | paths])

      true ->
        next_path = extract_last_file_path(line) || last_path
        infer_target_paths(rest, remaining, true, next_path, paths)

      false ->
        next_path = extract_last_file_path(line) || last_path
        infer_target_paths(rest, remaining, opening?, next_path, paths)
    end
  end

  @spec extract_last_file_path(String.t()) :: String.t() | nil
  defp extract_last_file_path(text) do
    case Regex.scan(@file_path_pattern, text) do
      [] -> nil
      matches -> matches |> Enum.at(-1) |> Enum.at(1)
    end
  end

  @doc """
  Parses markdown text into styled line segments.

  Returns a list of `{segments, line_type}` tuples, one per output line.
  """
  @spec parse(String.t()) :: [parsed_line()]
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> parse_lines([], nil)
    |> Enum.reverse()
  end

  # ── Line-level parsing ─────────────────────────────────────────────────────

  @spec parse_lines([String.t()], [parsed_line()], String.t() | nil) :: [parsed_line()]

  # End of input
  defp parse_lines([], acc, nil), do: acc

  # End of input inside a code block (unclosed)
  defp parse_lines([], acc, _lang), do: acc

  # Opening a fenced code block
  defp parse_lines(["```" <> lang | rest], acc, nil) do
    lang = String.trim(lang)
    label = if lang == "", do: "code", else: lang
    header = {[{"┌─ #{label} ", :code_block}, {"─", :code_block}], {:code_header, lang}}
    parse_lines(rest, [header | acc], lang)
  end

  # Closing a fenced code block
  defp parse_lines(["```" <> _ | rest], acc, _lang) do
    footer = {[{"└", :code_block}, {"─", :code_block}], :code}
    parse_lines(rest, [footer | acc], nil)
  end

  # Inside a code block
  defp parse_lines([line | rest], acc, lang) when is_binary(lang) do
    parsed = {[{line, {:code_content, lang}}], :code}
    parse_lines(rest, [parsed | acc], lang)
  end

  # Empty line
  defp parse_lines(["" | rest], acc, nil) do
    parse_lines(rest, [{[{"", :plain}], :empty} | acc], nil)
  end

  defp parse_lines([line | rest], acc, nil) do
    parsed = parse_indented_or_non_code_line(indented_code_line?(line, acc), line)
    parse_lines(rest, [parsed | acc], nil)
  end

  @spec parse_indented_or_non_code_line(boolean(), String.t()) :: parsed_line()
  defp parse_indented_or_non_code_line(true, line) do
    {[{String.slice(line, 4..-1//1), {:code_content, ""}}], :code}
  end

  defp parse_indented_or_non_code_line(false, line) do
    parse_non_code_line(line, String.trim(line))
  end

  @spec indented_code_line?(String.t(), [parsed_line()]) :: boolean()
  defp indented_code_line?(line, acc) do
    trimmed = String.trim(line)

    trimmed != "" and indent_width(line) >= 4 and not markdown_list_line?(trimmed) and
      not in_list_continuation?(acc)
  end

  @spec markdown_list_line?(String.t()) :: boolean()
  defp markdown_list_line?("- " <> _), do: true
  defp markdown_list_line?("* " <> _), do: true
  defp markdown_list_line?(trimmed), do: Regex.match?(~r/^\d+\.\s/, trimmed)

  @spec in_list_continuation?([parsed_line()]) :: boolean()
  defp in_list_continuation?([{_segments, :list_item} | _rest]), do: true
  defp in_list_continuation?([{_segments, :empty} | _rest]), do: false

  defp in_list_continuation?([{[{text, _style} | _rest_segments], :text} | rest]) do
    indent_width(text) >= 2 and in_list_continuation?(rest)
  end

  defp in_list_continuation?(_acc), do: false

  @spec parse_non_code_line(String.t(), String.t()) :: parsed_line()
  defp parse_non_code_line(_line, "###" <> _ = trimmed), do: parse_header_line(trimmed, :header3)
  defp parse_non_code_line(_line, "##" <> _ = trimmed), do: parse_header_line(trimmed, :header2)
  defp parse_non_code_line(_line, "#" <> _ = trimmed), do: parse_header_line(trimmed, :header1)

  defp parse_non_code_line(_line, ">" <> _ = trimmed) do
    text = trimmed |> String.replace_prefix(">", "") |> String.trim_leading()
    segments = parse_inline("│ " <> text)
    styles = Enum.map(segments, &blockquote_segment/1)
    {styles, :blockquote}
  end

  defp parse_non_code_line(line, "- " <> text), do: parse_bullet_line(line, text)
  defp parse_non_code_line(line, "* " <> text), do: parse_bullet_line(line, text)

  defp parse_non_code_line(line, trimmed) do
    parse_numbered_line(Regex.match?(~r/^\d+\.\s/, trimmed), line, trimmed)
  end

  @spec parse_header_line(String.t(), :header1 | :header2 | :header3) :: parsed_line()
  defp parse_header_line(trimmed, style) do
    text = trimmed |> String.trim_leading("#") |> String.trim()
    {[{text, style}], :header}
  end

  @spec parse_bullet_line(String.t(), String.t()) :: parsed_line()
  defp parse_bullet_line(line, text) do
    indent_level = div(indent_width(line), 2)
    prefix = String.duplicate("  ", indent_level + 1)
    segments = parse_inline(prefix <> "• " <> text)
    {segments, :list_item}
  end

  @spec parse_numbered_line(boolean(), String.t(), String.t()) :: parsed_line()
  defp parse_numbered_line(true, line, trimmed) do
    # Numbered list: keep the number prefix, parse inline for the rest
    indent_level = div(indent_width(line), 2)
    prefix = String.duplicate("  ", indent_level + 1)
    segments = parse_inline(prefix <> trimmed)
    {segments, :list_item}
  end

  defp parse_numbered_line(false, line, trimmed) do
    parse_extended_rule_line(String.match?(trimmed, ~r/^[-*_]{3,}$/), line)
  end

  @spec parse_extended_rule_line(boolean(), String.t()) :: parsed_line()
  defp parse_extended_rule_line(true, _line), do: {[{"─────────────────────", :rule}], :rule}

  defp parse_extended_rule_line(false, line) do
    segments = parse_inline(line)
    {segments, :text}
  end

  # ── Inline parsing ─────────────────────────────────────────────────────────

  @doc """
  Parses inline markdown formatting within a single line.

  Returns a list of `{text, style}` segments.
  """
  @spec parse_inline(String.t()) :: [segment()]
  def parse_inline(text) when is_binary(text) do
    text
    |> valid_text()
    |> do_parse_inline([], [])
    |> Enum.reverse()
    |> merge_adjacent()
  end

  # Tool output can carry bytes that are not text. The Unicode-aware checks below raise on them.
  @spec valid_text(binary()) :: String.t()
  defp valid_text(text), do: if(String.valid?(text), do: text, else: String.replace_invalid(text))

  # `dead` lists the underscore marks that have no closing mark in the rest of the text, so they are plain from here on.
  @spec do_parse_inline(String.t(), [segment()], [String.t()]) :: [segment()]

  defp do_parse_inline("", acc, _dead), do: acc

  # Inline code: `...`
  defp do_parse_inline("`" <> rest, acc, dead) do
    case String.split(rest, "`", parts: 2) do
      [code, remaining] ->
        do_parse_inline(remaining, [{code, :code} | acc], dead)

      [_no_close] ->
        do_parse_inline(rest, [{"`", :plain} | acc], dead)
    end
  end

  # Link: [text](url)
  defp do_parse_inline("[" <> rest, acc, dead) do
    case Regex.run(~r/^([^\]]+)\]\(([^)]+)\)(.*)$/s, rest) do
      [_, label, url, remaining] ->
        parse_link(label, url, remaining, acc, dead)

      nil ->
        do_parse_inline(rest, [{"[", :plain} | acc], dead)
    end
  end

  # Bold: **...**
  defp do_parse_inline("**" <> rest, acc, dead) do
    case String.split(rest, "**", parts: 2) do
      [bold_text, remaining] ->
        do_parse_inline(remaining, [{bold_text, :bold} | acc], dead)

      [_no_close] ->
        do_parse_inline(rest, [{"**", :plain} | acc], dead)
    end
  end

  # Bold: __...__
  defp do_parse_inline("__" <> rest, acc, dead),
    do: parse_underscore_span(rest, "__", :bold, acc, dead)

  # Italic: *...*  (but not ** which is bold)
  defp do_parse_inline("*" <> rest, acc, dead) do
    case String.split(rest, "*", parts: 2) do
      [italic_text, remaining] when italic_text != "" ->
        do_parse_inline(remaining, [{italic_text, :italic} | acc], dead)

      _ ->
        do_parse_inline(rest, [{"*", :plain} | acc], dead)
    end
  end

  # Italic: _..._ (but not __ which is bold)
  defp do_parse_inline("_" <> rest, acc, dead),
    do: parse_underscore_span(rest, "_", :italic, acc, dead)

  # Regular character: consume up to next special character
  defp do_parse_inline(text, acc, dead) do
    case Regex.run(~r/^([^`*_\[]+)(.*)$/s, text) do
      [_, plain, rest] ->
        do_parse_inline(rest, [{plain, :plain} | acc], dead)

      nil ->
        # Single special char that didn't match a pattern
        {char, rest} = String.split_at(text, 1)
        do_parse_inline(rest, [{char, :plain} | acc], dead)
    end
  end

  # An underscore inside a word is part of the word, as in CommonMark: `usage_limit_reached`
  # is one name, not "usage", an italic "limit" and "reached". Underscores open a
  # span only at the start of a word and close it only at the end of one.
  @spec parse_underscore_span(String.t(), String.t(), :bold | :italic, [segment()], [String.t()]) ::
          [segment()]
  defp parse_underscore_span(rest, mark, style, acc, dead) do
    if mark in dead or word_before?(acc) do
      do_parse_inline(rest, [{mark, :plain} | acc], dead)
    else
      case underscore_span(rest, mark) do
        {inner, remaining} ->
          do_parse_inline(remaining, [{inner, style} | acc], dead)

        # A closing mark for any later opening mark would have closed this one too.
        # So the rest of the text is searched once, not once for each opening mark.
        nil ->
          do_parse_inline(rest, [{mark, :plain} | acc], [mark | dead])
      end
    end
  end

  @spec underscore_span(String.t(), String.t()) :: {String.t(), String.t()} | nil
  defp underscore_span(rest, "__") do
    case Regex.run(~r/^(.+?)__(?![\p{L}\p{N}])(.*)$/su, rest) do
      [_, inner, remaining] -> {inner, remaining}
      nil -> nil
    end
  end

  defp underscore_span(rest, "_") do
    case Regex.run(~r/^(.+?)_(?![\p{L}\p{N}_])(.*)$/su, rest) do
      [_, inner, remaining] -> {inner, remaining}
      nil -> nil
    end
  end

  # Whether the text parsed so far ends in a letter or a digit.
  @spec word_before?([segment()]) :: boolean()
  defp word_before?([{text, :plain} | _earlier]), do: String.match?(text, ~r/[\p{L}\p{N}]$/u)
  defp word_before?(_acc), do: false

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec blockquote_segment(segment()) :: segment()
  defp blockquote_segment({text, {:link, _url} = style}), do: {text, style}
  defp blockquote_segment({text, _style}), do: {text, :blockquote}

  @spec parse_link(String.t(), String.t(), String.t(), [segment()], [String.t()]) :: [segment()]
  defp parse_link(label, url, remaining, acc, dead) do
    style = if safe_url?(url), do: {:link, url}, else: :plain
    do_parse_inline(remaining, [{label, style} | acc], dead)
  end

  @doc "Returns whether Markdown may expose this URI as an actionable link."
  @spec safe_url?(String.t()) :: boolean()
  def safe_url?(url) when is_binary(url) do
    if valid_percent_escapes?(url) do
      case URI.new(url) do
        {:ok, uri} -> safe_uri?(uri.scheme, uri)
        {:error, _part} -> false
      end
    else
      false
    end
  end

  @spec valid_percent_escapes?(String.t()) :: boolean()
  defp valid_percent_escapes?(<<>>), do: true

  defp valid_percent_escapes?(<<"%", first, second, rest::binary>>) do
    hex_digit?(first) and hex_digit?(second) and valid_percent_escapes?(rest)
  end

  defp valid_percent_escapes?(<<"%", _rest::binary>>), do: false
  defp valid_percent_escapes?(<<_char, rest::binary>>), do: valid_percent_escapes?(rest)

  @spec hex_digit?(byte()) :: boolean()
  defp hex_digit?(char) do
    (char >= ?0 and char <= ?9) or (char >= ?a and char <= ?f) or (char >= ?A and char <= ?F)
  end

  @spec safe_uri?(String.t() | nil, URI.t()) :: boolean()
  defp safe_uri?(scheme, %URI{host: host}) when scheme in ["http", "https"] do
    is_binary(host) and host != ""
  end

  defp safe_uri?("mailto", %URI{path: path}) do
    is_binary(path) and path != ""
  end

  defp safe_uri?(_scheme, _uri), do: false

  @spec merge_adjacent([segment()]) :: [segment()]
  defp merge_adjacent([]), do: []

  defp merge_adjacent([{t1, style}, {t2, style} | rest]) do
    merge_adjacent([{t1 <> t2, style} | rest])
  end

  defp merge_adjacent([seg | rest]) do
    [seg | merge_adjacent(rest)]
  end

  @spec indent_width(String.t()) :: non_neg_integer()
  defp indent_width(line) do
    line
    |> String.graphemes()
    |> Enum.take_while(&(&1 == " "))
    |> Enum.count()
  end
end
