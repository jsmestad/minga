defmodule MingaEditor.RenderModel.Window.ReviewSyntax do
  @moduledoc """
  Maps Diff Review lines onto the syntax highlight of the text each line came from.

  Context and removed lines read the original text's highlight; added lines read the post-image's highlight. A line renders flat when its side has no ready result, or when its text no longer matches that side's source line.
  """

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.DiffReview.DisplayLine
  alias MingaEditor.RenderModel.Window.ReviewLayout
  alias MingaEditor.UI.Highlight

  @typedoc "Syntax segments for the lines that have them, keyed by display-line source."
  @type t :: %{DisplayLine.source() => [Highlight.styled_segment()]}

  @doc """
  Resolves syntax segments for `lines`.

  `baseline` is the review's original text as lines. Each side is resolved in one ordered pass over its highlight spans, so the cost does not grow with the number of lines times the number of spans.
  """
  @spec segments(ReviewLayout.t(), DiffReview.t(), [String.t()], [DisplayLine.t()]) :: t()
  def segments(%ReviewLayout{} = layout, %DiffReview{} = review, baseline, lines)
      when is_list(baseline) and is_list(lines) do
    {old_lines, new_lines} =
      lines
      |> Enum.reject(&(&1.kind == :hunk_header))
      |> Enum.split_with(&match?(%DisplayLine{source: {:baseline, _line}}, &1))

    hunk_starts = review.hunks |> Enum.map(& &1.start_line) |> List.to_tuple()

    layout
    |> side_segments(:old, baseline, old_lines, fn {:baseline, line} -> line end)
    |> Map.merge(
      side_segments(layout, :new, review.after_lines, new_lines, fn {:added, hunk, offset} ->
        elem(hunk_starts, hunk) + offset
      end)
    )
  end

  @spec side_segments(
          ReviewLayout.t(),
          MingaEditor.Agent.ReviewHighlights.side(),
          [String.t()],
          [DisplayLine.t()],
          (DisplayLine.source() -> non_neg_integer())
        ) :: t()
  defp side_segments(_layout, _side, _source_lines, [], _index), do: %{}

  defp side_segments(layout, side, source_lines, lines, index) do
    case ReviewLayout.highlight(layout, side) do
      nil -> %{}
      highlight -> resolve(highlight, source_lines, lines, index)
    end
  end

  @spec resolve(
          Highlight.t(),
          [String.t()],
          [DisplayLine.t()],
          (DisplayLine.source() -> non_neg_integer())
        ) :: t()
  defp resolve(highlight, source_lines, lines, index) do
    texts = List.to_tuple(source_lines)
    offsets = line_offsets(source_lines)

    located =
      lines
      |> Enum.flat_map(fn %DisplayLine{source: source, text: text} ->
        line = index.(source)

        if line < tuple_size(texts) and elem(texts, line) == text,
          do: [{source, text, elem(offsets, line)}],
          else: []
      end)
      |> Enum.sort_by(fn {_source, _text, offset} -> offset end)

    styled =
      Highlight.styles_for_visible_lines(
        highlight,
        Enum.map(located, fn {_source, text, offset} -> {text, offset} end)
      )

    located
    |> Enum.zip(styled)
    |> Map.new(fn {{source, _text, _offset}, segments} -> {source, segments} end)
  end

  @spec line_offsets([String.t()]) :: tuple()
  defp line_offsets(lines) do
    {offsets, _next} =
      Enum.map_reduce(lines, 0, fn line, offset -> {offset, offset + byte_size(line) + 1} end)

    List.to_tuple(offsets)
  end
end
