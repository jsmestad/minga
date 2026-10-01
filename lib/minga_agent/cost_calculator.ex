defmodule MingaAgent.CostCalculator do
  @moduledoc """
  Calculates per-turn cost from token counts and LLMDB pricing data.

  When the API response includes a cost value (e.g., Anthropic), that
  value is used directly. When the API does not report cost, this module
  looks up the model's per-token rates from LLMDB and computes the cost
  from input/output/cache token counts.

  All costs are in USD. Rates in LLMDB are per million tokens.
  """

  @typedoc "Deprecated: use `MingaAgent.TurnUsage.t()` directly."
  @type usage_with_cost :: MingaAgent.TurnUsage.t()

  @doc """
  Ensures the usage struct has an accurate cost value.

  If the existing cost is non-zero, it's returned as-is (the API's value
  is authoritative). Otherwise, the cost is calculated from LLMDB pricing
  for the given model.

  `model` is the exact bare catalog model ID and `provider` is the exact
  catalog provider string from the resolved selection.
  """
  @spec ensure_cost(MingaAgent.TurnUsage.t(), String.t(), String.t()) ::
          MingaAgent.TurnUsage.t()
  def ensure_cost(%MingaAgent.TurnUsage{} = usage, model_id, provider)
      when is_binary(provider) do
    if usage.cost > 0.0 do
      usage
    else
      calculated = calculate_cost(usage, model_id, provider)
      %{usage | cost: calculated}
    end
  end

  @doc """
  Calculates cost from token counts and LLMDB pricing.

  Returns 0.0 if the model is not found in LLMDB.
  """
  @spec calculate_cost(MingaAgent.TurnUsage.t(), String.t(), String.t()) :: float()
  def calculate_cost(%MingaAgent.TurnUsage{} = usage, model_id, provider)
      when is_binary(provider) do
    case find_model_pricing(model_id, provider) do
      nil ->
        0.0

      rates ->
        input = usage.input * rate(rates, :input)
        output = usage.output * rate(rates, :output)
        cache_read = usage.cache_read * rate(rates, :cache_read)
        cache_write = usage.cache_write * rate(rates, :cache_write)

        Float.round(input + output + cache_read + cache_write, 6)
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec find_model_pricing(String.t(), String.t()) :: map() | nil
  defp find_model_pricing(model_id, provider) do
    case Enum.find(LLMDB.models(), fn model ->
           model.id == model_id and Atom.to_string(model.provider) == provider
         end) do
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
