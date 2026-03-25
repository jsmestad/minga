defmodule Minga.Agent.TurnUsage do
  @moduledoc """
  Token usage data for a single agent turn.

  Tracks input/output token counts, cache statistics, and estimated cost.
  Constructed by the provider after each turn completes, then accumulated
  into the session's total via `add/2`.
  """

  @typedoc "Per-turn token usage."
  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          cost: float()
        }

  defstruct input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            cost: 0.0

  @doc "Creates a new empty usage record."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Creates a usage record from the given values."
  @spec new(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), float()) ::
          t()
  def new(input, output, cache_read, cache_write, cost)
      when is_integer(input) and is_integer(output) do
    %__MODULE__{
      input: input,
      output: output,
      cache_read: cache_read,
      cache_write: cache_write,
      cost: cost
    }
  end

  @doc """
  Adds two usage records together, combining all counters.

  Used to accumulate per-turn usage into a session total.
  """
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = total, %__MODULE__{} = turn) do
    %__MODULE__{
      input: total.input + turn.input,
      output: total.output + turn.output,
      cache_read: total.cache_read + turn.cache_read,
      cache_write: total.cache_write + turn.cache_write,
      cost: total.cost + turn.cost
    }
  end

  @doc "Formats the usage as a short summary string for display."
  @spec format_short(t()) :: String.t()
  def format_short(%__MODULE__{} = u) do
    "↑#{u.input} ↓#{u.output} $#{u.cost}"
  end
end
