defmodule MingaAgent.ModelSelection.Policy do
  @moduledoc """
  Minga-owned reasoning, limit, capability, cost, and route behavior policy.

  `compaction`, `usage`, and `cost_mode` record route behavior as data so the native loop reads policy instead of matching on a route. Catalog routes keep the defaults: native compaction, token usage, and metered cost.
  """

  alias __MODULE__.{Capabilities, Limits, Reasoning}

  @enforce_keys [:reasoning, :limits, :capabilities, :cost]
  defstruct @enforce_keys ++ [compaction: :native, usage: :tokens, cost_mode: :metered]

  @type capability :: Capabilities.capability()
  @type reasoning :: Reasoning.t()
  @type limits :: Limits.t()
  @type capabilities :: Capabilities.t()
  @type compaction :: :native | :unsupported
  @type usage :: :tokens | :none
  @type cost_mode :: :metered | :subscription
  @type t :: %__MODULE__{
          reasoning: reasoning(),
          limits: limits(),
          capabilities: capabilities(),
          cost: map(),
          compaction: compaction(),
          usage: usage(),
          cost_mode: cost_mode()
        }

  @doc "Builds validated model policy."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_policy}
  def new(attrs) when is_map(attrs) do
    cost = Map.get(attrs, :cost, %{})
    compaction = Map.get(attrs, :compaction, :native)
    usage = Map.get(attrs, :usage, :tokens)
    cost_mode = Map.get(attrs, :cost_mode, :metered)

    with {:ok, reasoning} <- Reasoning.new(Map.get(attrs, :reasoning)),
         {:ok, limits} <- Limits.new(Map.get(attrs, :limits)),
         {:ok, capabilities} <- Capabilities.new(Map.get(attrs, :capabilities)),
         :ok <- validate_modes(cost, compaction, usage, cost_mode) do
      {:ok,
       %__MODULE__{
         reasoning: reasoning,
         limits: limits,
         capabilities: capabilities,
         cost: MingaAgent.ModelSelection.Encoding.stringify(cost),
         compaction: compaction,
         usage: usage,
         cost_mode: cost_mode
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

  @doc "Returns policy with a route's declared compaction and usage behavior."
  @spec with_behavior(t(), %{compaction: compaction(), usage: usage()}) ::
          {:ok, t()} | {:error, :invalid_policy}
  def with_behavior(%__MODULE__{} = policy, %{compaction: compaction, usage: usage}) do
    with :ok <- validate_modes(policy.cost, compaction, usage, policy.cost_mode) do
      {:ok, %{policy | compaction: compaction, usage: usage}}
    end
  end

  @spec validate_modes(term(), term(), term(), term()) :: :ok | {:error, :invalid_policy}
  defp validate_modes(cost, compaction, usage, cost_mode)
       when is_map(cost) and compaction in [:native, :unsupported] and usage in [:tokens, :none] and
              cost_mode in [:metered, :subscription],
       do: :ok

  defp validate_modes(_cost, _compaction, _usage, _cost_mode), do: {:error, :invalid_policy}
end
