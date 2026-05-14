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

  # Horizontal rule
  defp parse_lines([line | rest], acc, nil) when line in ["---", "***", "___"] do
    parse_lines(rest, [{[{"─────────────────────", :rule}], :rule} | acc], nil)
  end

  # Also match longer horizontal rules
  defp parse_lines([line | rest], acc, nil) do
    parsed = parse_non_code_line(line, String.trim(line))
    parse_lines(rest, [parsed | acc], nil)
  end

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
    |> do_parse_inline([])
    |> Enum.reverse()
    |> merge_adjacent()
  end

  @spec do_parse_inline(String.t(), [segment()]) :: [segment()]

  defp do_parse_inline("", acc), do: acc

  # Inline code: `...`
  defp do_parse_inline("`" <> rest, acc) do
    case String.split(rest, "`", parts: 2) do
      [code, remaining] ->
        do_parse_inline(remaining, [{code, :code} | acc])

      [_no_close] ->
        do_parse_inline(rest, [{"`", :plain} | acc])
    end
  end

  # Link: [text](url)
  defp do_parse_inline("[" <> rest, acc) do
    case Regex.run(~r/^([^\]]+)\]\(([^)]+)\)(.*)$/s, rest) do
      [_, label, url, remaining] ->
        parse_link(label, url, remaining, acc)

      nil ->
        do_parse_inline(rest, [{"[", :plain} | acc])
    end
  end

  # Bold: **...**
  defp do_parse_inline("**" <> rest, acc) do
    case String.split(rest, "**", parts: 2) do
      [bold_text, remaining] ->
        do_parse_inline(remaining, [{bold_text, :bold} | acc])

      [_no_close] ->
        do_parse_inline(rest, [{"**", :plain} | acc])
    end
  end

  # Bold: __...__
  defp do_parse_inline("__" <> rest, acc) do
    case String.split(rest, "__", parts: 2) do
      [bold_text, remaining] ->
        do_parse_inline(remaining, [{bold_text, :bold} | acc])

      [_no_close] ->
        do_parse_inline(rest, [{"__", :plain} | acc])
    end
  end

  # Italic: *...*  (but not ** which is bold)
  defp do_parse_inline("*" <> rest, acc) do
    case String.split(rest, "*", parts: 2) do
      [italic_text, remaining] when italic_text != "" ->
        do_parse_inline(remaining, [{italic_text, :italic} | acc])

      _ ->
        do_parse_inline(rest, [{"*", :plain} | acc])
    end
  end

  # Italic: _..._ (but not __ which is bold)
  defp do_parse_inline("_" <> rest, acc) do
    case String.split(rest, "_", parts: 2) do
      [italic_text, remaining] when italic_text != "" ->
        do_parse_inline(remaining, [{italic_text, :italic} | acc])

      _ ->
        do_parse_inline(rest, [{"_", :plain} | acc])
    end
  end

  # Regular character: consume up to next special character
  defp do_parse_inline(text, acc) do
    case Regex.run(~r/^([^`*_\[]+)(.*)$/s, text) do
      [_, plain, rest] ->
        do_parse_inline(rest, [{plain, :plain} | acc])

      nil ->
        # Single special char that didn't match a pattern
        {char, rest} = String.split_at(text, 1)
        do_parse_inline(rest, [{char, :plain} | acc])
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec blockquote_segment(segment()) :: segment()
  defp blockquote_segment({text, {:link, _url} = style}), do: {text, style}
  defp blockquote_segment({text, _style}), do: {text, :blockquote}

  @spec parse_link(String.t(), String.t(), String.t(), [segment()]) :: [segment()]
  defp parse_link(label, url, remaining, acc) do
    style = if safe_url?(url), do: {:link, url}, else: :plain
    do_parse_inline(remaining, [{label, style} | acc])
  end

  @spec safe_url?(String.t()) :: boolean()
  defp safe_url?(url) do
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
    |> length()
  end
end
