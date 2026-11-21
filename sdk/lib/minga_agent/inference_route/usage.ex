defmodule MingaAgent.InferenceRoute.Usage do
  @moduledoc """
  Token usage a route reports for one request. Counts default to 0.

  This is a compile-time stub.
  """

  defstruct input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {:invalid_usage, atom()}}
  def new(_attrs), do: raise("minga_sdk is compile-time only")
end
