defmodule MingaAgent.Compaction do
  @moduledoc """
  Semantic tool-group-aware context compaction for agent sessions.

  Compaction plans over complete semantic groups so tool calls and their
  results are never split. A "group" is one of:

  - Consecutive system messages (always kept, never compacted).
  - A single user message.
  - A plain assistant message (no tool calls).
  - A tool exchange: an assistant message with `tool_calls` plus all matching
    tool-result messages.

  Two compaction strategies are available based on route policy:

  - **Native** (`:native` policy): delegates to `ReqLLM.compact_context/3`.
    The provider endpoint's output is authoritative; the returned messages
    replace the conversation verbatim.
  - **Portable summary** (`:unsupported` policy or native fallback): generates
    a summary via LLM that preserves tool arguments, results, decisions, and
    obligations.

  Compaction is a version-checked durable Session transition. The provider's
  `compact/2` callback returns new messages; Session installs them via
  `Continuation.replace_messages` after persistence succeeds.
  """

  alias MingaAgent.Compaction.Group
  alias MingaAgent.Compaction.Plan
  alias MingaAgent.TokenEstimator
  alias ReqLLM.Context
  alias ReqLLM.Message

  @typedoc "A function that takes (model, messages, opts) and returns {:ok, text} or {:error, reason}."
  @type summary_fn :: (LLMDB.Model.t(), [Message.t()], keyword() ->
                         {:ok, String.t()} | {:error, term()})

  @typedoc "Options for compaction."
  @type compact_opts :: [
          model: LLMDB.Model.t(),
          llm_client: summary_fn(),
          context_limit: pos_integer() | nil,
          threshold: float(),
          keep_recent: pos_integer()
        ]

  @default_threshold 0.80
  @default_keep_recent 6
  @summary_max_tokens 2048

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Checks whether compaction is needed and performs it if so.

  Returns `{:compacted, new_context, summary_text}` if compaction was
  performed, or `{:ok, context}` if the context is within limits.

  Options:
  - `:model` -- exact request model used for the summary call
  - `:llm_client` -- the LLM client function for generating the summary
  - `:context_limit` -- exact resolved context limit; automatic compaction is disabled when unknown
  - `:threshold` -- fraction of context limit that triggers compaction (default: 0.80)
  - `:keep_recent` -- number of recent non-system groups to preserve verbatim (default: 6)
  """
  @spec maybe_compact(Context.t(), compact_opts()) ::
          {:compacted, Context.t(), String.t()} | {:ok, Context.t()} | {:error, String.t()}
  def maybe_compact(context, opts) do
    estimated = TokenEstimator.estimate(context.messages)
    limit = Keyword.get(opts, :context_limit)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    if is_integer(limit) and limit > 0 and estimated > limit * threshold do
      compact(context, opts)
    else
      {:ok, context}
    end
  end

  @doc """
  Forces compaction regardless of token count.

  Groups the conversation into semantic units, plans which groups to compact,
  and generates a summary of the compacted groups. System groups are always
  kept. The most recent `keep_recent` non-system groups are kept verbatim.
  Tool exchanges (assistant + tool results) are never split.
  """
  @spec compact(Context.t(), compact_opts()) ::
          {:compacted, Context.t(), String.t()} | {:ok, Context.t()} | {:error, String.t()}
  def compact(context, opts) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    plan = plan(context.messages, keep_recent)

    if Plan.actionable?(plan) do
      do_portable_compact(plan, opts)
    else
      {:ok, context}
    end
  end

  @doc """
  Groups messages into semantic units and partitions them into a compaction plan.

  System groups are always kept. The last `keep_recent` non-system groups are
  kept verbatim. Everything else is marked for compaction.
  """
  @spec plan([Message.t()], non_neg_integer()) :: Plan.t()
  def plan(messages, keep_recent) when is_list(messages) and is_integer(keep_recent) do
    groups = group_messages(messages)
    partition_groups(groups, keep_recent)
  end

  @doc """
  Groups a flat message list into semantic units.

  Scans left-to-right:
  - Consecutive `:system` messages form one `:system` group.
  - A `:user` message forms one `:user` group.
  - An `:assistant` message with `tool_calls` starts a `:tool_exchange` group
    that includes subsequent `:tool` messages.
  - A plain `:assistant` message forms one `:assistant` group.
  """
  @spec group_messages([Message.t()]) :: [Group.t()]
  def group_messages(messages) when is_list(messages) do
    messages
    |> do_group([])
    |> Enum.reverse()
  end

  # ── Portable summary compaction ──────────────────────────────────────────────

  @spec do_portable_compact(Plan.t(), compact_opts()) ::
          {:compacted, Context.t(), String.t()} | {:error, String.t()}
  defp do_portable_compact(plan, opts) do
    model = Keyword.fetch!(opts, :model)
    llm_client = Keyword.fetch!(opts, :llm_client)

    summary_prompt = build_summary_prompt(plan.to_compact)

    summary_messages = [
      Context.system(
        "You are a conversation summarizer. Produce a concise summary of the conversation below. " <>
          "Preserve: file paths, code snippets discussed, decisions made, tool call arguments and results, " <>
          "current task obligations, and durable output references. Use bullet points. Be thorough but concise."
      ),
      Context.user(summary_prompt)
    ]

    case llm_client.(model, summary_messages, max_tokens: @summary_max_tokens) do
      {:ok, summary_text} when is_binary(summary_text) ->
        before_tokens =
          TokenEstimator.estimate(Plan.compactable_messages(plan) ++ Plan.kept_messages(plan))

        summary_msg =
          Context.user(
            "[Conversation Summary -- earlier context was compacted]\n\n#{summary_text}"
          )

        system_msgs = kept_system(plan)
        recent_msgs = kept_non_system(plan)
        new_messages = system_msgs ++ [summary_msg] ++ recent_msgs
        after_tokens = TokenEstimator.estimate(new_messages)

        summary_info =
          "Context compacted (#{format_tokens(before_tokens)} -> #{format_tokens(after_tokens)} estimated tokens)"

        {:compacted, Context.new(new_messages), summary_info}

      {:error, reason} ->
        {:error, "Compaction failed: #{inspect(reason)}"}
    end
  end

  @spec kept_system(Plan.t()) :: [Message.t()]
  defp kept_system(%Plan{to_keep: groups}) do
    groups
    |> Enum.filter(&(&1.kind == :system))
    |> Enum.flat_map(& &1.messages)
  end

  @spec kept_non_system(Plan.t()) :: [Message.t()]
  defp kept_non_system(%Plan{to_keep: groups}) do
    groups
    |> Enum.reject(&(&1.kind == :system))
    |> Enum.flat_map(& &1.messages)
  end

  # ── Grouping ─────────────────────────────────────────────────────────────────

  @spec do_group([Message.t()], [Group.t()]) :: [Group.t()]
  defp do_group([], groups), do: groups

  defp do_group([%Message{role: :system} = msg | rest], groups) do
    {system_rest, remaining} = Enum.split_while(rest, &(&1.role == :system))
    system_msgs = [msg | system_rest]
    group = Group.new(:system, system_msgs, TokenEstimator.estimate(system_msgs))
    do_group(remaining, [group | groups])
  end

  defp do_group([%Message{role: :user} = msg | rest], groups) do
    group = Group.new(:user, [msg], TokenEstimator.estimate([msg]))
    do_group(rest, [group | groups])
  end

  defp do_group([%Message{role: :assistant, tool_calls: calls} = msg | rest], groups)
       when is_list(calls) and calls != [] do
    {tool_results, remaining} = Enum.split_while(rest, &(&1.role == :tool))
    exchange_msgs = [msg | tool_results]
    group = Group.new(:tool_exchange, exchange_msgs, TokenEstimator.estimate(exchange_msgs))
    do_group(remaining, [group | groups])
  end

  defp do_group([%Message{role: :assistant} = msg | rest], groups) do
    group = Group.new(:assistant, [msg], TokenEstimator.estimate([msg]))
    do_group(rest, [group | groups])
  end

  defp do_group([%Message{role: :tool} = msg | rest], groups) do
    # Orphaned tool result (no preceding assistant with tool_calls).
    # Treat as its own group so it is never silently dropped.
    group = Group.new(:tool_exchange, [msg], TokenEstimator.estimate([msg]))
    do_group(rest, [group | groups])
  end

  # ── Partitioning ─────────────────────────────────────────────────────────────

  @spec partition_groups([Group.t()], non_neg_integer()) :: Plan.t()
  defp partition_groups(groups, keep_recent) do
    {system_groups, non_system} = Enum.split_with(groups, &(&1.kind == :system))

    total = length(non_system)
    keep_count = min(keep_recent, total)
    split_at = total - keep_count

    {to_compact, to_keep_non_system} = Enum.split(non_system, split_at)

    Plan.new(to_compact, system_groups ++ to_keep_non_system)
  end

  # ── Summary building ─────────────────────────────────────────────────────────

  @spec build_summary_prompt([Group.t()]) :: String.t()
  defp build_summary_prompt(groups) do
    formatted =
      groups
      |> Enum.flat_map(& &1.messages)
      |> Enum.map_join("\n\n", fn msg ->
        role = msg.role |> Atom.to_string() |> String.capitalize()
        content = extract_content(msg)

        tool_info =
          case msg do
            %{role: :assistant, tool_calls: [_ | _] = calls} ->
              call_summary =
                Enum.map_join(calls, "\n", fn call ->
                  func = Map.get(call, :function, %{})
                  name = Map.get(func, :name, "unknown")
                  args = Map.get(func, :arguments, "{}")
                  "  Tool call: #{name}(#{args})"
                end)

              "\n#{call_summary}"

            %{role: :tool, tool_call_id: id} when is_binary(id) ->
              " [tool_call_id: #{id}]"

            _ ->
              ""
          end

        "**#{role}:**#{tool_info}\n#{content}"
      end)

    "Summarize this conversation, preserving tool call details and results:\n\n#{formatted}"
  end

  @spec extract_content(Message.t()) :: String.t()
  defp extract_content(%{content: content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{text: text} when is_binary(text) -> text
      other -> inspect(other)
    end)
  end

  defp extract_content(%{content: content}) when is_binary(content), do: content
  defp extract_content(_), do: ""

  @spec format_tokens(non_neg_integer()) :: String.t()
  defp format_tokens(tokens) when tokens >= 1000 do
    "#{Float.round(tokens / 1000, 1)}k"
  end

  defp format_tokens(tokens), do: "#{tokens}"
end
