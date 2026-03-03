defmodule Minga.Diagnostics.Diagnostic do
  @moduledoc """
  A single diagnostic — an error, warning, info, or hint tied to a location.

  Source-agnostic: LSP servers, external linters, compilers, and test runners
  all produce the same struct. The `source` field identifies the producer
  (e.g., `"lexical"`, `"mix_compile"`).
  """

  @enforce_keys [:range, :severity, :message]
  defstruct [:range, :severity, :message, :source, :code]

  @typedoc "Severity level, ordered from most to least severe."
  @type severity :: :error | :warning | :info | :hint

  @typedoc "A source location range (zero-indexed lines and byte columns)."
  @type range :: %{
          start_line: non_neg_integer(),
          start_col: non_neg_integer(),
          end_line: non_neg_integer(),
          end_col: non_neg_integer()
        }

  @typedoc "A diagnostic entry."
  @type t :: %__MODULE__{
          range: range(),
          severity: severity(),
          message: String.t(),
          source: String.t() | nil,
          code: String.t() | integer() | nil
        }

  @severity_rank %{error: 0, warning: 1, info: 2, hint: 3}

  @doc """
  Compares two severities. Returns `:lt`, `:eq`, or `:gt`.

  `:error` is the most severe (lowest rank).

  ## Examples

      iex> Minga.Diagnostics.Diagnostic.compare_severity(:error, :warning)
      :lt

      iex> Minga.Diagnostics.Diagnostic.compare_severity(:hint, :error)
      :gt
  """
  @spec compare_severity(severity(), severity()) :: :lt | :eq | :gt
  def compare_severity(a, b) when is_atom(a) and is_atom(b) do
    rank_a = Map.fetch!(@severity_rank, a)
    rank_b = Map.fetch!(@severity_rank, b)

    cond do
      rank_a < rank_b -> :lt
      rank_a > rank_b -> :gt
      true -> :eq
    end
  end

  @doc """
  Returns the more severe of two severities.

  ## Examples

      iex> Minga.Diagnostics.Diagnostic.more_severe(:warning, :error)
      :error

      iex> Minga.Diagnostics.Diagnostic.more_severe(:info, :hint)
      :info
  """
  @spec more_severe(severity(), severity()) :: severity()
  def more_severe(a, b) when is_atom(a) and is_atom(b) do
    case compare_severity(a, b) do
      :lt -> a
      :eq -> a
      :gt -> b
    end
  end

  @doc """
  Sorts diagnostics by line, then column, then severity (most severe first).
  """
  @spec sort([t()]) :: [t()]
  def sort(diagnostics) when is_list(diagnostics) do
    Enum.sort(diagnostics, fn a, b ->
      a_line = a.range.start_line
      b_line = b.range.start_line
      a_col = a.range.start_col
      b_col = b.range.start_col

      a_line < b_line or
        (a_line == b_line and a_col < b_col) or
        (a_line == b_line and a_col == b_col and
           compare_severity(a.severity, b.severity) == :lt)
    end)
  end
end
