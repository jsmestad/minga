defmodule MingaEditor.RenderModel.Window.SourceOffsetMap do
  @moduledoc """
  Maps buffer byte boundaries to UTF-16 offsets in one composed visual line.

  The map records only composition edits. Source text remains authoritative for
  unchanged spans, so mapping does not allocate one entry per grapheme on long
  lines.
  """

  alias Minga.Core.Decorations
  alias Minga.Core.Decorations.ConcealRange
  alias Minga.Core.Decorations.VirtualText
  alias Minga.Core.Unicode

  @enforce_keys [
    :source_text,
    :source_start_byte,
    :source_end_byte,
    :composed_start_utf16,
    :composed_end_utf16,
    :insertions,
    :replacements
  ]
  defstruct @enforce_keys

  @type insertion :: {non_neg_integer(), non_neg_integer()}
  @type replacement :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type affinity :: :start | :end

  @type t :: %__MODULE__{
          source_text: String.t(),
          source_start_byte: non_neg_integer(),
          source_end_byte: non_neg_integer(),
          composed_start_utf16: non_neg_integer(),
          composed_end_utf16: non_neg_integer(),
          insertions: [insertion()],
          replacements: [replacement()]
        }

  @spec new(String.t(), String.t(), Decorations.t(), non_neg_integer()) :: t()
  def new(source_text, composed_text, %Decorations{} = decorations, line) do
    line_width = Unicode.display_width(source_text)

    insertions =
      decorations
      |> Decorations.inline_virtual_texts_for_line(line)
      |> Enum.map(fn %VirtualText{anchor: {_line, col}, segments: segments} ->
        {Unicode.display_col_to_byte(source_text, min(col, line_width)), utf16_segments(segments)}
      end)

    replacements =
      decorations
      |> Decorations.conceals_for_line(line)
      |> Enum.map(&conceal_replacement(&1, source_text, line, line_width))

    %__MODULE__{
      source_text: source_text,
      source_start_byte: 0,
      source_end_byte: byte_size(source_text),
      composed_start_utf16: 0,
      composed_end_utf16: utf16_length(composed_text),
      insertions: insertions,
      replacements: replacements
    }
  end

  @spec slice(t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          t()
  def slice(%__MODULE__{} = map, source_start, source_end, composed_start, composed_end) do
    %{
      map
      | source_start_byte: source_start,
        source_end_byte: source_end,
        composed_start_utf16: composed_start,
        composed_end_utf16: composed_end
    }
  end

  @spec source_to_composed_utf16(t(), non_neg_integer(), affinity()) :: non_neg_integer()
  def source_to_composed_utf16(%__MODULE__{} = map, source_byte, affinity) do
    source_byte = min(source_byte, byte_size(map.source_text))
    source_utf16 = utf16_offset(map.source_text, source_byte)

    replacement_delta =
      Enum.reduce(map.replacements, 0, fn {start_byte, end_byte, replacement_utf16}, delta ->
        delta +
          replacement_delta(map.source_text, source_byte, start_byte, end_byte, replacement_utf16)
      end)

    insertion_delta =
      Enum.reduce(map.insertions, 0, fn {anchor_byte, inserted_utf16}, delta ->
        if insertion_before_boundary?(anchor_byte, source_byte, affinity),
          do: delta + inserted_utf16,
          else: delta
      end)

    max(source_utf16 + replacement_delta + insertion_delta, 0)
  end

  @spec conceal_replacement(ConcealRange.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          replacement()
  defp conceal_replacement(%ConcealRange{} = conceal, source_text, line, line_width) do
    {start_line, start_col} = conceal.start_pos
    {end_line, end_col} = conceal.end_pos
    effective_start = if start_line < line, do: 0, else: min(start_col, line_width)
    effective_end = if end_line > line, do: line_width, else: min(end_col, line_width)

    {
      Unicode.display_col_to_byte(source_text, effective_start),
      Unicode.display_col_to_byte(source_text, max(effective_end, effective_start)),
      utf16_length(conceal.replacement || "")
    }
  end

  @spec replacement_delta(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: integer()
  defp replacement_delta(_text, source_byte, start_byte, _end_byte, _replacement_utf16)
       when source_byte <= start_byte,
       do: 0

  defp replacement_delta(text, source_byte, start_byte, end_byte, replacement_utf16) do
    removed_end = min(source_byte, end_byte)
    removed_utf16 = utf16_offset(text, removed_end) - utf16_offset(text, start_byte)
    replacement_utf16 - removed_utf16
  end

  @spec insertion_before_boundary?(non_neg_integer(), non_neg_integer(), affinity()) :: boolean()
  defp insertion_before_boundary?(anchor_byte, source_byte, :start),
    do: anchor_byte <= source_byte

  defp insertion_before_boundary?(anchor_byte, source_byte, :end), do: anchor_byte < source_byte

  @spec utf16_segments([{String.t(), term()}]) :: non_neg_integer()
  defp utf16_segments(segments) do
    Enum.reduce(segments, 0, fn {text, _face}, total -> total + utf16_length(text) end)
  end

  @spec utf16_length(String.t()) :: non_neg_integer()
  defp utf16_length(text), do: utf16_offset(text, byte_size(text))

  @spec utf16_offset(String.t(), non_neg_integer()) :: non_neg_integer()
  defp utf16_offset(text, byte_offset) do
    text
    |> binary_part(0, min(byte_offset, byte_size(text)))
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, units -> units + if(codepoint > 0xFFFF, do: 2, else: 1) end)
  end
end
