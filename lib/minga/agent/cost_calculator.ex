defmodule Minga.Agent.CostCalculator do
  @moduledoc """
  Calculates per-turn cost from token counts and LLMDB pricing data.

  When the API response includes a cost value (e.g., Anthropic), that
  value is used directly. When the API does not report cost, this module
  looks up the model's per-token rates from LLMDB and computes the cost
  from input/output/cache token counts.

  All costs are in USD. Rates in LLMDB are per million tokens.
  """

  @typedoc "Token usage with cost."
  @type usage_with_cost :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          cost: float()
        }

  @doc """
  Ensures the usage map has an accurate cost value.

  If the existing cost is non-zero, it's returned as-is (the API's value
  is authoritative). Otherwise, the cost is calculated from LLMDB pricing
  for the given model.

  `model` should be the bare model ID (without provider prefix).
  `provider` should be the provider atom (e.g., :anthropic).
  """
  @spec ensure_cost(map(), String.t(), atom()) :: map()
  def ensure_cost(usage, model_id, provider) when is_map(usage) do
    existing_cost = Map.get(usage, :cost, 0.0) || 0.0

    if existing_cost > 0.0 do
      usage
    else
      calculated = calculate_cost(usage, model_id, provider)
      Map.put(usage, :cost, calculated)
    end
  end

  @doc """
  Calculates cost from token counts and LLMDB pricing.

  Returns 0.0 if the model is not found in LLMDB.
  """
  @spec calculate_cost(map(), String.t(), atom()) :: float()
  def calculate_cost(usage, model_id, provider) do
    case find_model_pricing(model_id, provider) do
      nil ->
        0.0

      rates ->
        input = (Map.get(usage, :input, 0) || 0) * rate(rates, :input)
        output = (Map.get(usage, :output, 0) || 0) * rate(rates, :output)
        cache_read = (Map.get(usage, :cache_read, 0) || 0) * rate(rates, :cache_read)
        cache_write = (Map.get(usage, :cache_write, 0) || 0) * rate(rates, :cache_write)

        Float.round(input + output + cache_read + cache_write, 6)
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec find_model_pricing(String.t(), atom()) :: map() | nil
  defp find_model_pricing(model_id, provider) do
    case Enum.find(LLMDB.models(), &(&1.id == model_id and &1.provider == provider)) do
      nil -> nil
      model -> model.cost
    end
  rescue
    _ -> nil
  end

  # Returns the per-token rate (LLMDB stores per-million-token rates).
  @spec rate(map(), atom()) :: float()
  defp rate(rates, key) do
    case Map.get(rates, key) do
      nil -> 0.0
      r when is_number(r) -> r / 1_000_000
      _ -> 0.0
    end
  end
end
