defmodule MingaAgent.CompactionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Compaction
  alias ReqLLM.Context
  # A mock LLM client that returns summary text directly
  defp mock_llm_client(_model, _messages, _opts) do
    {:ok, "Summary: discussed file edits, ran tests, fixed bugs."}
  end

  defp failing_llm_client(_model, _messages, _opts) do
    {:error, "API connection failed"}
  end

  defp build_context(message_count) do
    system = Context.system("You are a helpful assistant.")

    conversation =
      for i <- 1..message_count do
        if rem(i, 2) == 1 do
          Context.user(
            "User message #{i} with some content about editing files and running tests. " <>
              String.duplicate("x", 200)
          )
        else
          Context.assistant(
            "Assistant response #{i} with detailed code analysis. " <> String.duplicate("y", 200)
          )
        end
      end

    Context.new([system | conversation])
  end

  describe "maybe_compact/2" do
    test "returns {:ok, context} when under threshold" do
      context = build_context(4)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        context_limit: 100_000,
        threshold: 0.80
      ]

      assert {:ok, ^context} = Compaction.maybe_compact(context, opts)
    end

    test "triggers compaction when over threshold" do
      context = build_context(20)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        context_limit: 500,
        threshold: 0.10
      ]

      assert {:compacted, new_context, summary_info} = Compaction.maybe_compact(context, opts)
      assert is_binary(summary_info)
      assert summary_info =~ "compacted"
      # Compacted context should have fewer messages
      assert length(new_context.messages) < length(context.messages)
    end
  end

  describe "compact/2" do
    test "keeps system messages" do
      context = build_context(10)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        keep_recent: 4
      ]

      assert {:compacted, new_context, _info} = Compaction.compact(context, opts)

      # First message should still be the system prompt
      [first | _] = new_context.messages
      assert first.role == :system
    end

    test "keeps recent messages verbatim" do
      context = build_context(10)
      original_messages = context.messages

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        keep_recent: 4
      ]

      assert {:compacted, new_context, _info} = Compaction.compact(context, opts)

      # Last 4 messages should be from the original conversation
      kept = Enum.take(new_context.messages, -4)
      original_last = Enum.take(original_messages, -4)
      assert kept == original_last
    end

    test "inserts a summary message" do
      context = build_context(10)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        keep_recent: 4
      ]

      assert {:compacted, new_context, _info} = Compaction.compact(context, opts)

      # Should have: system + summary + 4 kept = 6 messages
      assert length(new_context.messages) == 6

      # Second message should be the summary
      summary = Enum.at(new_context.messages, 1)
      assert summary.role == :user
      assert extract_content(summary) =~ "Conversation Summary"
    end

    test "skips compaction when conversation is too short" do
      context = build_context(4)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        keep_recent: 6
      ]

      assert {:ok, ^context} = Compaction.compact(context, opts)
    end

    test "returns error when LLM call fails" do
      context = build_context(10)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &failing_llm_client/3,
        keep_recent: 4
      ]

      assert {:error, reason} = Compaction.compact(context, opts)
      assert reason =~ "Compaction failed"
    end

    test "summary info includes token reduction" do
      context = build_context(20)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        keep_recent: 4
      ]

      assert {:compacted, _new_context, summary_info} = Compaction.compact(context, opts)
      assert summary_info =~ "→"
      assert summary_info =~ "tokens"
    end
  end

  defp extract_content(%{content: content}) when is_binary(content), do: content
  defp extract_content(%{content: [%{text: text} | _]}), do: text
  defp extract_content(_), do: ""
end
