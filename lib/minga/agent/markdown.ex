defmodule Minga.Agent.Markdown do
  @moduledoc """
  Simple markdown parser for agent chat rendering.

  Parses a subset of markdown into styled line segments suitable for
  terminal rendering. This is intentionally not a full CommonMark parser;
  it handles the patterns that LLM output commonly uses.

  ## Supported syntax

  - `**bold**` and `__bold__`
  - `*italic*` and `_italic_`
  - `` `inline code` ``
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
          | :code_block
          | :header1
          | :header2
          | :header3
          | :blockquote
          | :list_bullet
          | :rule

  @typedoc "A styled text segment."
  @type segment :: {String.t(), style()}

  @typedoc "Line type indicating block context."
  @type line_type :: :text | :code | :header | :blockquote | :list_item | :rule | :empty

  @typedoc "A parsed line with its segments and type."
  @type parsed_line :: {[segment()], line_type()}

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
    header = {[{"┌─ #{label} ", :code_block}, {"─", :code_block}], :code}
    parse_lines(rest, [header | acc], lang)
  end

  # Closing a fenced code block
  defp parse_lines(["```" <> _ | rest], acc, _lang) do
    footer = {[{"└", :code_block}, {"─", :code_block}], :code}
    parse_lines(rest, [footer | acc], nil)
  end

  # Inside a code block
  defp parse_lines([line | rest], acc, lang) when is_binary(lang) do
    parsed = {[{"│ " <> line, :code_block}], :code}
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
    trimmed = String.trim(line)

    cond do
      match?("###" <> _, trimmed) ->
        text = trimmed |> String.trim_leading("#") |> String.trim()
        parse_lines(rest, [{[{text, :header3}], :header} | acc], nil)

      match?("##" <> _, trimmed) ->
        text = trimmed |> String.trim_leading("#") |> String.trim()
        parse_lines(rest, [{[{text, :header2}], :header} | acc], nil)

      match?("#" <> _, trimmed) ->
        text = trimmed |> String.trim_leading("#") |> String.trim()
        parse_lines(rest, [{[{text, :header1}], :header} | acc], nil)

      match?(">" <> _, trimmed) ->
        text = String.trim_leading(trimmed, "> ")
        segments = parse_inline("│ " <> text)
        styles = Enum.map(segments, fn {t, _s} -> {t, :blockquote} end)
        parse_lines(rest, [{styles, :blockquote} | acc], nil)

      match?("- " <> _, trimmed) or match?("* " <> _, trimmed) ->
        text = String.slice(trimmed, 2..-1//1)
        segments = parse_inline("  • " <> text)
        parse_lines(rest, [{segments, :list_item} | acc], nil)

      Regex.match?(~r/^\d+\.\s/, trimmed) ->
        # Numbered list: keep the number prefix, parse inline for the rest
        segments = parse_inline("  " <> trimmed)
        parse_lines(rest, [{segments, :list_item} | acc], nil)

      String.match?(trimmed, ~r/^[-*_]{3,}$/) ->
        parse_lines(rest, [{[{"─────────────────────", :rule}], :rule} | acc], nil)

      true ->
        segments = parse_inline(line)
        parse_lines(rest, [{segments, :text} | acc], nil)
    end
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
    case Regex.run(~r/^([^`*_]+)(.*)$/s, text) do
      [_, plain, rest] ->
        do_parse_inline(rest, [{plain, :plain} | acc])

      nil ->
        # Single special char that didn't match a pattern
        {char, rest} = String.split_at(text, 1)
        do_parse_inline(rest, [{char, :plain} | acc])
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec merge_adjacent([segment()]) :: [segment()]
  defp merge_adjacent([]), do: []

  defp merge_adjacent([{t1, style}, {t2, style} | rest]) do
    merge_adjacent([{t1 <> t2, style} | rest])
  end

  defp merge_adjacent([seg | rest]) do
    [seg | merge_adjacent(rest)]
  end
end
