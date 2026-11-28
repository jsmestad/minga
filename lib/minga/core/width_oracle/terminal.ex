defmodule Minga.Core.WidthOracle.Terminal do
  @moduledoc "Measures grapheme cells with the pinned terminal renderer's default width data."

  defstruct []

  @type t :: %__MODULE__{}
end

defimpl Minga.Core.WidthOracle, for: Minga.Core.WidthOracle.Terminal do
  @moduledoc false

  alias Minga.Core.WidthOracle.Terminal

  @data Path.join(__DIR__, "terminal_cell_widths.tsv")
  @external_resource @data
  @ranges @data
          |> File.stream!()
          |> Stream.reject(&String.starts_with?(&1, "#"))
          |> Enum.map(fn line ->
            [lo, hi, cells] = String.split(line)
            {String.to_integer(lo, 16), String.to_integer(hi, 16), String.to_integer(cells)}
          end)
          |> List.to_tuple()

  @spec grapheme_width(Terminal.t(), String.t()) :: non_neg_integer()
  def grapheme_width(%Terminal{}, <<c, _::binary>>) when c < 32 or c == 127, do: 0
  def grapheme_width(%Terminal{}, <<_c::utf8, "\uFE0F", _::binary>>), do: 2
  def grapheme_width(%Terminal{}, <<c, _::binary>>) when c < 128, do: 1
  def grapheme_width(%Terminal{}, <<c::utf8, _::binary>>), do: lookup(c, 0, tuple_size(@ranges))
  def grapheme_width(%Terminal{}, ""), do: 0
  def grapheme_width(%Terminal{}, _invalid), do: 1

  @spec display_width(Terminal.t(), String.t()) :: non_neg_integer()
  def display_width(oracle, text), do: display_width(oracle, text, 0)

  @spec fingerprint(Terminal.t()) :: :terminal_graphemes
  def fingerprint(%Terminal{}), do: :terminal_graphemes

  @spec display_width(Terminal.t(), String.t(), non_neg_integer()) :: non_neg_integer()
  defp display_width(_oracle, "", width), do: width

  defp display_width(oracle, text, width) do
    {grapheme, rest} = String.next_grapheme(text)
    display_width(oracle, rest, width + grapheme_width(oracle, grapheme))
  end

  @spec lookup(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp lookup(_cp, index, index), do: 1

  defp lookup(cp, start, stop) do
    mid = div(start + stop, 2)
    {lo, hi, width} = elem(@ranges, mid)

    cond do
      cp < lo -> lookup(cp, start, mid)
      cp > hi -> lookup(cp, mid + 1, stop)
      true -> width
    end
  end
end
