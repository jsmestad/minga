defmodule MingaAgent.InferenceRoute.Usage do
  @moduledoc "Token usage a route reports for one request."

  defstruct input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer()
        }

  @fields [:input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens]

  @doc "Builds usage; missing counts are 0 and negative or non-integer counts are rejected."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {:invalid_usage, atom()}}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    Enum.reduce_while(@fields, {:ok, %__MODULE__{}}, fn field, {:ok, usage} ->
      case Map.get(attrs, field, 0) do
        count when is_integer(count) and count >= 0 ->
          {:cont, {:ok, Map.put(usage, field, count)}}

        _invalid ->
          {:halt, {:error, {:invalid_usage, field}}}
      end
    end)
  end

  @doc "Revalidates a usage struct returned by a route."
  @spec validate(term()) :: {:ok, t()} | {:error, {:invalid_usage, atom()}}
  def validate(%__MODULE__{} = usage), do: usage |> Map.from_struct() |> new()
  def validate(_usage), do: {:error, {:invalid_usage, :struct}}
end
