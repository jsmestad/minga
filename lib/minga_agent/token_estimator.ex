defmodule MingaAgent.TokenEstimator do
  @moduledoc """
  Estimates token counts for LLM message lists.

  Uses a character-based heuristic: roughly 1 token per 3.5 characters
  for English text, plus overhead for message framing (role tokens,
  formatting). This is accurate to within ~20% of actual usage for
  typical code-heavy conversations.

  The estimator is intentionally simple. Exact token counting requires
  a tokenizer (tiktoken for OpenAI, Anthropic's tokenizer for Claude),
  which adds dependencies and complexity. The heuristic is good enough
  for context bar display and compaction trigger decisions.
  """

  @typedoc "A message-like map with content and role."
  @type message :: %{
          optional(:role) => String.t() | atom(),
          optional(:content) => String.t() | list(),
          optional(atom()) => term()
        }

  # Average characters per token for English/code mix.
  @chars_per_token 3.5

  # Overhead tokens per message for role framing, special tokens, etc.
  @message_overhead 4

  # Extra overhead for the system prompt (Anthropic caches system separately).
  @system_overhead 8

  @doc """
  Estimates the total token count for a list of messages.

  Each message's content is measured by character count divided by
  #{@chars_per_token}, plus #{@message_overhead} tokens of overhead for
  role framing. System messages get an extra #{@system_overhead} tokens.

  ## Examples

      iex> messages = [%{role: "system", content: "You are helpful."}, %{role: "user", content: "Hello"}]
      iex> MingaAgent.TokenEstimator.estimate(messages)
      22
  """
  @spec estimate([message()]) :: non_neg_integer()
  def estimate(messages) when is_list(messages) do
    messages
    |> Enum.map(&estimate_message/1)
    |> Enum.sum()
    |> round()
    |> max(0)
  end

  @doc """
  Estimates the token count for a single string.

  ## Examples

      iex> MingaAgent.TokenEstimator.estimate_string("Hello, world!")
      4
  """
  @spec estimate_string(String.t()) :: non_neg_integer()
  def estimate_string(text) when is_binary(text) do
    max(round(String.length(text) / @chars_per_token), 1)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec estimate_message(message()) :: number()
  defp estimate_message(msg) do
    content_tokens = content_token_count(msg)
    overhead = base_overhead(msg)
    content_tokens + overhead
  end

  @spec content_token_count(message()) :: number()
  defp content_token_count(%{content: content}) when is_binary(content) do
    String.length(content) / @chars_per_token
  end

  defp content_token_count(%{content: parts}) when is_list(parts) do
    Enum.reduce(parts, 0, fn part, acc ->
      acc + part_token_count(part)
    end)
  end

  defp content_token_count(_), do: 0

  @spec part_token_count(map()) :: number()
  defp part_token_count(%{text: text}) when is_binary(text) do
    String.length(text) / @chars_per_token
  end

  defp part_token_count(%{content: text}) when is_binary(text) do
    String.length(text) / @chars_per_token
  end

  defp part_token_count(_), do: 0

  @spec base_overhead(message()) :: number()
  defp base_overhead(%{role: role}) when role in ["system", :system] do
    @message_overhead + @system_overhead
  end

  defp base_overhead(_), do: @message_overhead
end
