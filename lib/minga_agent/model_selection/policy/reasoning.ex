defmodule MingaAgent.ModelSelection.Policy.Reasoning do
  @moduledoc "Validated reasoning choices for an exact execution route."
  @enforce_keys [:effort, :options]
  defstruct @enforce_keys

  @type t :: %__MODULE__{effort: String.t(), options: [String.t()]}

  @doc "Accepts only a reasoning choice advertised by this route."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_reasoning}
  def new(%{effort: effort, options: options}) when is_binary(effort) and is_list(options) do
    if options != [] and Enum.all?(options, &is_binary/1) and effort in options do
      {:ok, %__MODULE__{effort: effort, options: options}}
    else
      {:error, :invalid_reasoning}
    end
  end

  def new(_attrs), do: {:error, :invalid_reasoning}

  @doc "Chooses another supported effort without changing its advertised options."
  @spec choose(t(), String.t()) :: {:ok, t()} | {:error, :unsupported_reasoning}
  def choose(%__MODULE__{} = reasoning, effort) when is_binary(effort) do
    if effort in reasoning.options do
      {:ok, %{reasoning | effort: effort}}
    else
      {:error, :unsupported_reasoning}
    end
  end
end
