defmodule Minga.Agent.ModelLimits do
  @moduledoc """
  Context window size lookup for known LLM models.

  Returns the maximum input token count for a model name. Used by the
  context usage bar to calculate fill percentage. Falls back to nil for
  unknown models (the bar is hidden in that case).
  """

  # Context limits in tokens. These are the *input* context limits
  # (the window the model can read), not the output limit.
  @limits %{
    # Anthropic Claude
    "claude-sonnet-4-20250514" => 200_000,
    "claude-sonnet-4" => 200_000,
    "claude-opus-4" => 200_000,
    "claude-3-7-sonnet" => 200_000,
    "claude-3-5-sonnet" => 200_000,
    "claude-3-5-haiku" => 200_000,
    "claude-3-opus" => 200_000,
    "claude-3-sonnet" => 200_000,
    "claude-3-haiku" => 200_000,
    # OpenAI
    "gpt-4o" => 128_000,
    "gpt-4o-mini" => 128_000,
    "gpt-4-turbo" => 128_000,
    "gpt-4" => 8_192,
    "o1" => 200_000,
    "o1-mini" => 128_000,
    "o1-preview" => 128_000,
    "o3" => 200_000,
    "o3-mini" => 200_000,
    "o4-mini" => 200_000,
    # Google Gemini
    "gemini-2.5-pro" => 1_048_576,
    "gemini-2.5-flash" => 1_048_576,
    "gemini-2.0-flash" => 1_048_576,
    "gemini-1.5-pro" => 2_097_152,
    "gemini-1.5-flash" => 1_048_576,
    # DeepSeek
    "deepseek-chat" => 64_000,
    "deepseek-reasoner" => 64_000
  }

  @doc """
  Returns the context window limit (in tokens) for the given model name.

  Tries exact match first, then prefix match (e.g., "claude-sonnet-4-20250514"
  matches "claude-sonnet-4"). Returns `nil` for unknown models.
  """
  @spec context_limit(String.t()) :: non_neg_integer() | nil
  def context_limit(model_name) when is_binary(model_name) do
    Map.get(@limits, model_name) || prefix_match(model_name)
  end

  # Sorted by key length descending so "gpt-4o" matches before "gpt-4".
  @sorted_limits @limits |> Enum.sort_by(fn {k, _} -> -String.length(k) end)

  @spec prefix_match(String.t()) :: non_neg_integer() | nil
  defp prefix_match(model_name) do
    @sorted_limits
    |> Enum.find(fn {key, _} -> String.starts_with?(model_name, key) end)
    |> then(fn
      {_, limit} -> limit
      nil -> nil
    end)
  end
end
