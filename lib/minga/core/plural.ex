defmodule Minga.Core.Plural do
  @moduledoc """
  Count labels for user-facing copy.

  A count next to a noun must agree with it: `1 line`, never `1 lines`. Callers pass both forms, so irregular nouns need no rules here.
  """

  @doc """
  Returns the count followed by the noun form that agrees with it.

      iex> Minga.Core.Plural.count(1, "line", "lines")
      "1 line"

      iex> Minga.Core.Plural.count(0, "line", "lines")
      "0 lines"
  """
  @spec count(integer(), String.t(), String.t()) :: String.t()
  def count(count, singular, plural) when is_integer(count),
    do: "#{count} #{noun(count, singular, plural)}"

  @doc """
  Returns the noun form that agrees with the count, without the count.

      iex> Minga.Core.Plural.noun(1, "file", "files")
      "file"

      iex> Minga.Core.Plural.noun(3, "file", "files")
      "files"
  """
  @spec noun(integer(), String.t(), String.t()) :: String.t()
  def noun(1, singular, _plural), do: singular
  def noun(count, _singular, plural) when is_integer(count), do: plural
end
