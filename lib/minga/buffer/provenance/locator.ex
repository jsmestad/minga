defmodule Minga.Buffer.Provenance.Locator do
  @moduledoc """
  Dense, ordered identifiers for authorship runs.

  A locator is a nonempty list of integers, compared with Erlang term order, which compares lists element by element and puts a proper prefix first. `between/2` always finds a new locator strictly between two others, so a run inserted between two runs, or split off from one, gets an identifier that sorts in document order. Because identifiers sort the same way the runs do, one balanced tree can find a run both by its byte offset and by its locator.

  This is the locator scheme Zed's buffer uses for its fragments. Each new digit takes a small fraction of the remaining gap, so runs appended one after another at the same place still produce short locators.
  """

  import Bitwise

  # Digits stay below 2^56, so every digit is a small integer on a 64-bit BEAM.
  @max_digit (1 <<< 56) - 1

  # A biased step takes 1/65536 of the gap, so a sequence of insertions shrinks the free gap slowly.
  @step_shift 16

  @typedoc "A run identifier. Locators sort in document order."
  @type t :: nonempty_list(non_neg_integer())

  @typedoc """
  Where in the gap a new locator goes: at the middle, or close to one side.

  Insertions that keep landing next to the locator made just before them should take a small step away from it, so the rest of the gap stays free for the next one: `:low` for a sequence that moves forward, `:high` for one that moves backward.
  """
  @type bias :: :low | :middle | :high

  @doc """
  Returns a locator strictly between `lower` and `upper`, placed in the gap as `bias` says.

  `nil` stands for the open end on either side. `lower` must sort before `upper`.
  """
  @spec between(t() | nil, t() | nil, bias()) :: t()
  def between(lower, upper, bias \\ :middle) when bias in [:low, :middle, :high],
    do: digits(lower || [], upper || [], bias, [])

  @spec digits([non_neg_integer()], [non_neg_integer()], bias(), [non_neg_integer()]) :: t()
  defp digits(lower, upper, bias, acc) do
    {low, lower_rest} = first_digit(lower, 0)
    {high, upper_rest} = first_digit(upper, @max_digit)
    candidate = candidate(low, high, bias)

    cond do
      candidate > low and candidate < high -> Enum.reverse([candidate | acc])
      # Already below `upper` at this digit, so every later digit is free up to the maximum.
      low < high -> digits(lower_rest, [], bias, [low | acc])
      true -> digits(lower_rest, upper_rest, bias, [low | acc])
    end
  end

  @spec candidate(non_neg_integer(), non_neg_integer(), bias()) :: non_neg_integer()
  defp candidate(low, high, :middle), do: low + ((high - low) >>> 1)
  defp candidate(low, high, :low), do: low + max((high - low) >>> @step_shift, 1)
  defp candidate(low, high, :high), do: high - max((high - low) >>> @step_shift, 1)

  @doc "Returns `count` one-digit locators in increasing order, spread evenly over the digit range."
  @spec even(non_neg_integer()) :: [t()]
  def even(count) when is_integer(count) and count >= 0 do
    spacing = div(@max_digit, count + 1)
    for index <- 1..count//1, do: [index * spacing]
  end

  @spec first_digit([non_neg_integer()], non_neg_integer()) ::
          {non_neg_integer(), [non_neg_integer()]}
  defp first_digit([], padding), do: {padding, []}
  defp first_digit([digit | rest], _padding), do: {digit, rest}
end
