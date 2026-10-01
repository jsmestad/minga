defmodule MingaAgent.ModelSelection.Policy do
  @moduledoc "Minga-owned reasoning, limit, capability, and cost policy."

  alias __MODULE__.{Capabilities, Limits, Reasoning}

  @enforce_keys [:reasoning, :limits, :capabilities, :cost]
  defstruct @enforce_keys

  @type capability :: Capabilities.capability()
  @type reasoning :: Reasoning.t()
  @type limits :: Limits.t()
  @type capabilities :: Capabilities.t()
  @type t :: %__MODULE__{
          reasoning: reasoning(),
          limits: limits(),
          capabilities: capabilities(),
          cost: map()
        }

  @doc "Builds validated model policy."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_policy}
  def new(attrs) when is_map(attrs) do
    cost = Map.get(attrs, :cost, %{})

    with {:ok, reasoning} <- Reasoning.new(Map.get(attrs, :reasoning)),
         {:ok, limits} <- Limits.new(Map.get(attrs, :limits)),
         {:ok, capabilities} <- Capabilities.new(Map.get(attrs, :capabilities)),
         true <- is_map(cost) do
      {:ok,
       %__MODULE__{
         reasoning: reasoning,
         limits: limits,
         capabilities: capabilities,
         cost: cost
       }}
    else
      _invalid -> {:error, :invalid_policy}
    end
  end

  def new(_attrs), do: {:error, :invalid_policy}

  @doc "Returns policy with a validated reasoning choice."
  @spec with_reasoning(t(), String.t()) :: {:ok, t()} | {:error, :unsupported_reasoning}
  def with_reasoning(%__MODULE__{} = policy, effort) when is_binary(effort) do
    case Reasoning.choose(policy.reasoning, effort) do
      {:ok, reasoning} -> {:ok, %{policy | reasoning: reasoning}}
      {:error, :unsupported_reasoning} = error -> error
    end
  end
end
