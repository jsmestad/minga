defmodule MingaAgent.CompactionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Compaction
  alias MingaAgent.Compaction.Group
  alias MingaAgent.Compaction.Plan
  alias ReqLLM.Context

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

  defp tool_call(id, name) do
    ReqLLM.ToolCall.new(id, name, "{}")
  end

  defp tool_result(call) do
    %ReqLLM.Message{
      role: :tool,
      tool_call_id: call.id,
      content: [ReqLLM.Message.ContentPart.text("tool output")]
    }
  end

  # ── group_messages/1 ─────────────────────────────────────────────────────────

  describe "group_messages/1" do
    test "consecutive system messages form one group" do
      messages = [
        Context.system("system 1"),
        Context.system("system 2"),
        Context.user("hello")
      ]

      groups = Compaction.group_messages(messages)
      assert [%Group{kind: :system, messages: [_, _]}, %Group{kind: :user}] = groups
    end

    test "plain assistant message forms its own group" do
      messages = [
        Context.user("hello"),
        Context.assistant("world")
      ]

      groups = Compaction.group_messages(messages)
      assert [%Group{kind: :user}, %Group{kind: :assistant}] = groups
    end

    test "assistant with tool_calls groups with subsequent tool results" do
      call_a = tool_call("a", "read_file")
      call_b = tool_call("b", "write_file")

      messages = [
        Context.user("do something"),
        %ReqLLM.Message{role: :assistant, tool_calls: [call_a, call_b]},
        tool_result(call_a),
        tool_result(call_b),
        Context.assistant("done")
      ]

      groups = Compaction.group_messages(messages)

      assert [
               %Group{kind: :user},
               %Group{kind: :tool_exchange, messages: exchange},
               %Group{kind: :assistant}
             ] = groups

      assert [_, _, _] = exchange
    end

    test "tool result without preceding tool-call assistant is grouped as tool_exchange" do
      orphan = %ReqLLM.Message{
        role: :tool,
        tool_call_id: "orphan",
        content: [ReqLLM.Message.ContentPart.text("stray")]
      }

      groups = Compaction.group_messages([orphan])
      assert [%Group{kind: :tool_exchange, messages: [^orphan]}] = groups
    end

    test "mixed conversation groups correctly" do
      call = tool_call("c1", "search")

      messages = [
        Context.system("instructions"),
        Context.user("find foo"),
        %ReqLLM.Message{role: :assistant, tool_calls: [call]},
        tool_result(call),
        Context.assistant("found it"),
        Context.user("thanks"),
        Context.assistant("you're welcome")
      ]

      groups = Compaction.group_messages(messages)

      kinds = Enum.map(groups, & &1.kind)
      assert kinds == [:system, :user, :tool_exchange, :assistant, :user, :assistant]
    end

    test "each group has a positive token estimate" do
      messages = [
        Context.system("instructions"),
        Context.user("hello world")
      ]

      groups = Compaction.group_messages(messages)
      assert Enum.all?(groups, fn g -> g.token_estimate > 0 end)
    end
  end

  # ── plan/2 ───────────────────────────────────────────────────────────────────

  describe "plan/2" do
    test "system groups are always kept" do
      messages = [
        Context.system("system prompt"),
        Context.user("msg 1"),
        Context.assistant("reply 1"),
        Context.user("msg 2"),
        Context.assistant("reply 2")
      ]

      plan = Compaction.plan(messages, 2)

      system_in_keep = Enum.filter(plan.to_keep, &(&1.kind == :system))
      system_in_compact = Enum.filter(plan.to_compact, &(&1.kind == :system))

      assert [_] = system_in_keep
      assert system_in_compact == []
    end

    test "keeps the last N non-system groups" do
      messages = [
        Context.system("sys"),
        Context.user("old"),
        Context.assistant("old reply"),
        Context.user("recent"),
        Context.assistant("recent reply")
      ]

      plan = Compaction.plan(messages, 2)
      kept_kinds = plan.to_keep |> Enum.reject(&(&1.kind == :system)) |> Enum.map(& &1.kind)
      assert kept_kinds == [:user, :assistant]
    end

    test "tool exchanges are never split" do
      call = tool_call("t1", "read")

      messages = [
        Context.system("sys"),
        Context.user("old user"),
        %ReqLLM.Message{role: :assistant, tool_calls: [call]},
        tool_result(call),
        Context.assistant("done"),
        Context.user("new user"),
        Context.assistant("new reply")
      ]

      plan = Compaction.plan(messages, 2)

      # The tool exchange should be in to_compact as a single group
      assert [exchange] = Enum.filter(plan.to_compact, &(&1.kind == :tool_exchange))
      assert [_, _] = exchange.messages
    end

    test "returns empty to_compact when conversation is short" do
      messages = [
        Context.system("sys"),
        Context.user("hello"),
        Context.assistant("world")
      ]

      plan = Compaction.plan(messages, 6)
      refute Plan.actionable?(plan)
      assert plan.to_compact == []
    end

    test "plan is not actionable when keep_recent covers all groups" do
      messages = [
        Context.system("sys"),
        Context.user("hello")
      ]

      plan = Compaction.plan(messages, 10)
      refute Plan.actionable?(plan)
    end
  end

  # ── maybe_compact/2 ─────────────────────────────────────────────────────────

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
      assert Enum.count(new_context.messages) < Enum.count(context.messages)
    end
  end

  # ── compact/2 ────────────────────────────────────────────────────────────────

  describe "compact/2" do
    test "keeps system messages" do
      context = build_context(10)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        keep_recent: 4
      ]

      assert {:compacted, new_context, _info} = Compaction.compact(context, opts)

      [first | _] = new_context.messages
      assert first.role == :system
    end

    test "keeps recent groups verbatim" do
      context = build_context(10)
      original_messages = context.messages

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        keep_recent: 4
      ]

      assert {:compacted, new_context, _info} = Compaction.compact(context, opts)

      # Last 4 non-system messages should be from the original conversation
      kept = Enum.take(new_context.messages, -4)
      original_last = Enum.take(original_messages, -4)
      assert kept == original_last
    end

    test "inserts a summary message after system" do
      context = build_context(10)

      opts = [
        model: "anthropic:claude-sonnet-4-20250514",
        llm_client: &mock_llm_client/3,
        keep_recent: 4
      ]

      assert {:compacted, new_context, _info} = Compaction.compact(context, opts)

      # system + summary + 4 kept = 6 messages
      assert Enum.count(new_context.messages) == 6

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
      assert summary_info =~ "->"
      assert summary_info =~ "tokens"
    end

    test "tool exchange is kept intact when it falls in the recent window" do
      calls = Enum.map(["one", "two"], &ReqLLM.ToolCall.new(&1, "read_file", "{}"))
      assistant = %ReqLLM.Message{role: :assistant, tool_calls: calls}

      results =
        Enum.map(calls, fn call ->
          %ReqLLM.Message{
            role: :tool,
            tool_call_id: call.id,
            content: [ReqLLM.Message.ContentPart.text("found")]
          }
        end)

      retained = [assistant | results] ++ [Context.assistant("finished")]

      messages =
        [
          Context.system("instructions"),
          Context.user("old"),
          Context.assistant("old reply"),
          Context.user("inspect")
        ] ++ retained

      # The tool exchange (assistant + 2 results) counts as one group,
      # and "finished" is a separate group. With keep_recent 2-4 the
      # exchange should always stay intact.
      for keep_recent <- [2, 3, 4] do
        assert {:compacted, compacted, _info} =
                 Compaction.compact(Context.new(messages),
                   model: "model",
                   llm_client: &mock_llm_client/3,
                   keep_recent: keep_recent
                 )

        assert Enum.take(compacted.messages, -4) == retained

        assert {:ok, _portable, _counts} =
                 MingaAgent.Session.PortableHistory.convert(compacted.messages)
      end
    end

    test "summary prompt includes tool call details" do
      call = tool_call("tc1", "read_file")

      messages = [
        Context.system("sys"),
        Context.user("read it"),
        %ReqLLM.Message{role: :assistant, tool_calls: [call]},
        tool_result(call),
        Context.user("now write it"),
        Context.assistant("ok")
      ]

      # With keep_recent: 2, the tool exchange group is compacted.
      # We capture the summary prompt by checking the LLM client receives tool content.
      capture_client = fn _model, [_sys, user_msg], _opts ->
        text = extract_content(user_msg)
        assert text =~ "tool call"
        assert text =~ "read_file"
        {:ok, "Summary with tools."}
      end

      assert {:compacted, _context, _info} =
               Compaction.compact(Context.new(messages),
                 model: "model",
                 llm_client: capture_client,
                 keep_recent: 2
               )
    end

    test "second compaction on already-compacted context works" do
      context = build_context(20)

      opts = [
        model: "model",
        llm_client: &mock_llm_client/3,
        keep_recent: 4
      ]

      assert {:compacted, first_compact, _info} = Compaction.compact(context, opts)

      # Add more messages to exceed keep_recent again
      new_messages =
        first_compact.messages ++
          [
            Context.user("new question 1"),
            Context.assistant("new answer 1"),
            Context.user("new question 2"),
            Context.assistant("new answer 2"),
            Context.user("new question 3"),
            Context.assistant("new answer 3")
          ]

      second_context = Context.new(new_messages)

      assert {:compacted, second_compact, _info} = Compaction.compact(second_context, opts)
      assert Enum.count(second_compact.messages) < Enum.count(second_context.messages)
      # System prompt preserved
      assert hd(second_compact.messages).role == :system
    end
  end

  defp extract_content(%{content: content}) when is_binary(content), do: content
  defp extract_content(%{content: [%{text: text} | _]}), do: text
  defp extract_content(_), do: ""
end
