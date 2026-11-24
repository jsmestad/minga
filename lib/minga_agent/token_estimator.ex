defmodule MingaAgent.TokenEstimator do
  @moduledoc """
  Estimates token counts for LLM message lists.

  Uses a character-based heuristic: roughly 1 token per 3.5 characters
  for English text, plus overhead for message framing (role tokens,
  formatting). Counts message content, tool call names, arguments and IDs,
  and the text of reasoning details.

  Images, video and files count a fixed per-part cost, because providers
  bill them by dimensions or pages rather than by encoded bytes.

  The result is an estimate, not an upper bound: exact counts need a
  provider tokenizer. Use it for display and soft thresholds such as
  compaction triggers; a hosted request's admission is decided by
  `MingaAgent.ModelSelection.Policy.RequestCapacity` from a bound.
  """

  @typedoc "A message-like map with content and role."
  @type message :: %{
          optional(:role) => String.t() | atom(),
          optional(:content) => String.t() | list(),
          optional(atom()) => term()
        }

  @chars_per_token 3.5

  @message_overhead 4

  @system_overhead 8

  # Per tool call: id token, type token, function name token, JSON framing.
  @tool_call_overhead 6

  # Typical provider cost of one image, video frame set or file attachment.
  @media_part_tokens 1_600

  @doc """
  Estimates the total token count for a list of messages.

  Accounts for content text, tool call names and arguments, tool call
  IDs, reasoning details, and message framing overhead.

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
    content_token_count(msg) +
      tool_calls_token_count(msg) +
      tool_call_id_token_count(msg) +
      reasoning_token_count(msg) +
      base_overhead(msg)
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

  @spec tool_calls_token_count(message()) :: number()
  defp tool_calls_token_count(%{tool_calls: calls}) when is_list(calls) and calls != [] do
    Enum.reduce(calls, 0, fn call, acc ->
      func = Map.get(call, :function, %{})
      name = Map.get(func, :name, "")
      args = Map.get(func, :arguments, "")

      name_tokens = if is_binary(name), do: String.length(name) / @chars_per_token, else: 0
      args_tokens = if is_binary(args), do: String.length(args) / @chars_per_token, else: 0

      acc + name_tokens + args_tokens + @tool_call_overhead
    end)
  end

  defp tool_calls_token_count(_), do: 0

  @spec tool_call_id_token_count(message()) :: number()
  defp tool_call_id_token_count(%{tool_call_id: id}) when is_binary(id) and id != "" do
    String.length(id) / @chars_per_token
  end

  defp tool_call_id_token_count(_), do: 0

  @spec reasoning_token_count(message()) :: number()
  defp reasoning_token_count(%{reasoning_details: details}) when is_list(details) do
    Enum.reduce(details, 0, fn detail, acc ->
      text = Map.get(detail, :text, nil)
      text_tokens = if is_binary(text), do: String.length(text) / @chars_per_token, else: 0
      acc + text_tokens
    end)
  end

  defp reasoning_token_count(_), do: 0

  @spec part_token_count(map()) :: number()
  defp part_token_count(%{text: text}) when is_binary(text) do
    String.length(text) / @chars_per_token
  end

  defp part_token_count(%{content: text}) when is_binary(text) do
    String.length(text) / @chars_per_token
  end

  defp part_token_count(%{type: type}) when type in [:image, :image_url, :video_url, :file],
    do: @media_part_tokens

  defp part_token_count(_), do: 0

  @spec base_overhead(message()) :: number()
  defp base_overhead(%{role: role}) when role in ["system", :system] do
    @message_overhead + @system_overhead
  end

  defp base_overhead(_), do: @message_overhead
end
