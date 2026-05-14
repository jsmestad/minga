defmodule MingaEditor.HoverPopup.SyntaxHighlight do
  @moduledoc """
  Adds tree-sitter syntax highlighting to fenced code blocks in hover markdown.

  Hover popups still use the regular markdown parser for structure. This module only replaces code block content lines when the parser can return language-aware highlight spans within a short timeout. Unsupported languages, parser crashes, and timeouts leave the original `:code_content` styling intact.
  """

  alias Minga.Core.Face
  alias Minga.Language.Highlight.Span
  alias Minga.Parser.Manager, as: ParserManager
  alias MingaAgent.Markdown
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.Theme

  @highlight_timeout_ms 50

  @typedoc "Result returned by a hover code block highlighter."
  @type highlighter_result ::
          {:ok, [String.t()], [Span.t()]}
          | :unsupported
          | :timeout
          | :unavailable
          | {:error, term()}
          | nil

  @typedoc "Function used to request syntax spans for a code block."
  @type highlighter :: (String.t(), String.t(), keyword() -> highlighter_result())

  @typep indexed_line :: {non_neg_integer(), String.t()}
  @typep code_block :: %{language: String.t(), lines: [indexed_line()]}
  @typep segment_map :: %{non_neg_integer() => [Markdown.segment()]}

  @doc "Returns parsed hover lines with syntax-highlighted fenced code content where available."
  @spec enhance([Markdown.parsed_line()], Theme.t(), keyword()) :: [Markdown.parsed_line()]
  def enhance(parsed_lines, %Theme{} = theme, opts \\ []) when is_list(parsed_lines) do
    highlighter = Keyword.get(opts, :highlighter, &ParserManager.highlight_source/3)
    timeout = normalize_timeout(Keyword.get(opts, :timeout, @highlight_timeout_ms))

    deadline_ms = System.monotonic_time(:millisecond) + timeout

    parsed_lines
    |> collect_code_blocks()
    |> Enum.reduce(parsed_lines, fn block, lines ->
      replace_block(lines, block, theme, highlighter, deadline_ms)
    end)
  end

  @spec normalize_timeout(term()) :: non_neg_integer()
  defp normalize_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
  defp normalize_timeout(_timeout), do: @highlight_timeout_ms

  # ── Code block discovery ──────────────────────────────────────────────────

  @spec collect_code_blocks([Markdown.parsed_line()]) :: [code_block()]
  defp collect_code_blocks(parsed_lines) do
    parsed_lines
    |> Enum.with_index()
    |> do_collect_code_blocks([], nil)
  end

  @spec do_collect_code_blocks(
          [{Markdown.parsed_line(), non_neg_integer()}],
          [code_block()],
          code_block() | nil
        ) :: [code_block()]
  defp do_collect_code_blocks([], blocks, nil), do: Enum.reverse(blocks)
  defp do_collect_code_blocks([], blocks, block), do: Enum.reverse([finish_block(block) | blocks])

  defp do_collect_code_blocks([{{_segments, {:code_header, language}}, _idx} | rest], blocks, nil) do
    do_collect_code_blocks(rest, blocks, new_block(language))
  end

  defp do_collect_code_blocks(
         [{{_segments, {:code_header, language}}, _idx} | rest],
         blocks,
         block
       ) do
    do_collect_code_blocks(rest, [finish_block(block) | blocks], new_block(language))
  end

  defp do_collect_code_blocks(
         [{{[{text, {:code_content, _language}}], :code}, idx} | rest],
         blocks,
         block
       )
       when is_map(block) do
    do_collect_code_blocks(rest, blocks, add_line(block, idx, text))
  end

  defp do_collect_code_blocks([{{_segments, :code}, _idx} | rest], blocks, block)
       when is_map(block) do
    do_collect_code_blocks(rest, [finish_block(block) | blocks], nil)
  end

  defp do_collect_code_blocks([_line | rest], blocks, nil) do
    do_collect_code_blocks(rest, blocks, nil)
  end

  defp do_collect_code_blocks([_line | rest], blocks, block) do
    do_collect_code_blocks(rest, [finish_block(block) | blocks], nil)
  end

  @spec new_block(String.t()) :: code_block()
  defp new_block(language), do: %{language: normalize_language(language), lines: []}

  @spec normalize_language(String.t()) :: String.t()
  defp normalize_language(language) do
    language
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> then(&(&1 || ""))
  end

  @spec add_line(code_block(), non_neg_integer(), String.t()) :: code_block()
  defp add_line(block, idx, text), do: %{block | lines: [{idx, text} | block.lines]}

  @spec finish_block(code_block()) :: code_block()
  defp finish_block(block), do: %{block | lines: Enum.reverse(block.lines)}

  # ── Highlight application ─────────────────────────────────────────────────

  @spec replace_block(
          [Markdown.parsed_line()],
          code_block(),
          Theme.t(),
          highlighter(),
          integer()
        ) :: [Markdown.parsed_line()]
  defp replace_block(lines, %{language: ""}, _theme, _highlighter, _deadline_ms), do: lines
  defp replace_block(lines, %{lines: []}, _theme, _highlighter, _deadline_ms), do: lines

  defp replace_block(lines, block, theme, highlighter, deadline_ms) do
    timeout = remaining_timeout(deadline_ms)

    case highlighted_segments(block, theme, highlighter, timeout) do
      {:ok, segment_map} -> replace_lines(lines, segment_map)
      :skip -> lines
    end
  end

  @spec remaining_timeout(integer()) :: non_neg_integer()
  defp remaining_timeout(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  @spec highlighted_segments(code_block(), Theme.t(), highlighter(), non_neg_integer()) ::
          {:ok, segment_map()} | :skip
  defp highlighted_segments(_block, _theme, _highlighter, 0), do: :skip

  defp highlighted_segments(block, theme, highlighter, timeout) do
    source = Enum.map_join(block.lines, "\n", fn {_idx, text} -> text end)
    result = call_highlighter(highlighter, block.language, source, timeout)

    case normalize_highlight_result(result) do
      {:ok, names, spans} -> build_segment_map({:ok, names, spans}, block, theme)
      :skip -> log_unexpected_skip(block.language, result)
    end
  end

  @spec call_highlighter(highlighter(), String.t(), String.t(), non_neg_integer()) ::
          highlighter_result()
  defp call_highlighter(highlighter, language, source, timeout) do
    highlighter.(language, source, timeout: timeout)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  @spec normalize_highlight_result(highlighter_result()) ::
          {:ok, [String.t()], [Span.t()]} | :skip
  defp normalize_highlight_result({:ok, names, spans}) when is_list(names) and is_list(spans) do
    {:ok, names, spans}
  end

  defp normalize_highlight_result(_result), do: :skip

  @spec log_unexpected_skip(String.t(), highlighter_result()) :: :skip
  defp log_unexpected_skip(_language, result)
       when result in [:unsupported, :timeout, :unavailable, nil] do
    :skip
  end

  defp log_unexpected_skip(language, {:error, reason}) do
    Minga.Log.warning(
      :editor,
      "Hover code highlighting failed for #{language}: #{inspect(reason)}"
    )

    :skip
  end

  defp log_unexpected_skip(language, result) do
    Minga.Log.warning(
      :editor,
      "Hover code highlighting returned an invalid result for #{language}: #{inspect(result)}"
    )

    :skip
  end

  @spec build_segment_map({:ok, [String.t()], [Span.t()]}, code_block(), Theme.t()) ::
          {:ok, segment_map()} | :skip
  defp build_segment_map({:ok, names, spans}, block, theme) do
    highlight =
      theme
      |> Highlight.from_theme()
      |> Highlight.put_names(names)
      |> Highlight.put_spans(1, spans)

    {segment_map, highlighted?, _next_byte_offset} =
      Enum.reduce(block.lines, {%{}, false, 0}, fn {line_idx, text}, {acc, any?, byte_offset} ->
        segments = syntax_segments_for_line(highlight, text, byte_offset, block.language)
        next_byte_offset = byte_offset + byte_size(text) + 1
        {Map.put(acc, line_idx, segments), any? or syntax_segments?(segments), next_byte_offset}
      end)

    segment_map_result(segment_map, highlighted?)
  end

  @spec segment_map_result(segment_map(), boolean()) :: {:ok, segment_map()} | :skip
  defp segment_map_result(segment_map, true), do: {:ok, segment_map}
  defp segment_map_result(_segment_map, false), do: :skip

  @spec syntax_segments_for_line(Highlight.t(), String.t(), non_neg_integer(), String.t()) :: [
          Markdown.segment()
        ]
  defp syntax_segments_for_line(highlight, text, line_start_byte, language) do
    highlight
    |> Highlight.styles_for_line(text, line_start_byte)
    |> Enum.map(&to_hover_segment(&1, language))
  end

  @spec to_hover_segment(Highlight.styled_segment(), String.t()) :: Markdown.segment()
  defp to_hover_segment({text, %Face{} = face}, language) do
    if syntax_face?(face) do
      {text, {:syntax, face}}
    else
      {text, {:code_content, language}}
    end
  end

  @spec syntax_face?(Face.t()) :: boolean()
  defp syntax_face?(%Face{} = face), do: face.fg != nil and face.name != "default"

  @spec syntax_segments?([Markdown.segment()]) :: boolean()
  defp syntax_segments?(segments) do
    Enum.any?(segments, fn
      {_text, {:syntax, %Face{}}} -> true
      _segment -> false
    end)
  end

  @spec replace_lines([Markdown.parsed_line()], segment_map()) :: [Markdown.parsed_line()]
  defp replace_lines(lines, segment_map) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {{_segments, line_type} = line, idx} ->
      replace_line(line, line_type, Map.get(segment_map, idx))
    end)
  end

  @spec replace_line(Markdown.parsed_line(), Markdown.line_type(), [Markdown.segment()] | nil) ::
          Markdown.parsed_line()
  defp replace_line(line, _line_type, nil), do: line
  defp replace_line(_line, line_type, segments), do: {segments, line_type}
end
