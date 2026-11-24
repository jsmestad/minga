defmodule Minga.Buffer.Provenance.Locator do
  @moduledoc """
  Dense, ordered identifiers for authorship runs.

  A locator is a nonempty list of integers, compared with Erlang term order, which compares lists element by element and puts a proper prefix first. `between/2` always finds a new locator strictly between two others, so a run inserted between two runs, or split off from one, gets an identifier that sorts in document order. Because identifiers sort the same way the runs do, one balanced tree can find a run both by its byte offset and by its locator.

  This is the locator scheme Zed's buffer uses for its fragments. Each new digit takes a small fraction of the remaining gap, so runs appended one after another at the same place still produce short locators.
  """

  import Bitwise

  # Digits stay below 2^56, so every digit is a small integer on a 64-bit BEAM.
  @max_digit (1 <<< 56) - 1
  @gap_shift 16

  @typedoc "A run identifier. Locators sort in document order."
  @type t :: nonempty_list(non_neg_integer())

  @doc """
  Returns a locator strictly between `lower` and `upper`.

  `nil` stands for the open end on either side. `lower` must sort before `upper`.
  """
  @spec between(t() | nil, t() | nil) :: t()
  def between(lower, upper), do: digits(lower || [], upper || [], [])

  @spec digits([non_neg_integer()], [non_neg_integer()], [non_neg_integer()]) :: t()
  defp digits(lower, upper, acc) do
    {low, lower_rest} = first_digit(lower, 0)
    {high, upper_rest} = first_digit(upper, @max_digit)
    mid = low + (max(high - low, 0) >>> @gap_shift)

    cond do
      mid > low -> Enum.reverse([mid | acc])
      # Already below `upper` at this digit, so every later digit is free up to the maximum.
      mid < high -> digits(lower_rest, [], [mid | acc])
      true -> digits(lower_rest, upper_rest, [mid | acc])
    end
  end

  @spec first_digit([non_neg_integer()], non_neg_integer()) ::
          {non_neg_integer(), [non_neg_integer()]}
  defp first_digit([], padding), do: {padding, []}
  defp first_digit([digit | rest], _padding), do: {digit, rest}
end
