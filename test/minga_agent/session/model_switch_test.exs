defmodule MingaAgent.Session.ModelSwitchTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelSelection
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.ModelSwitch
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.PrefixStore
  alias MingaAgent.Test.ModelSelectionFixture
  alias ReqLLM.Context
  alias ReqLLM.ToolCall

  # -- Helpers ----------------------------------------------------------------

  defp identity do
    selection =
      ModelSelectionFixture.selection(request_provider: :openai_codex, model_id: "test-model")

    ModelSelection.replay_identity(
      selection,
      %{kind: :oauth, account_id: "fixture-account", source_id: String.duplicate("a", 64)}
    )
  end

  defp schema do
    %{
      name: "inspect",
      description: "Inspect a project value",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{"mode" => %{"enum" => ["brief", "full"]}}
      },
      strict: false,
      provider_options: %{},
      source: :config
    }
  end

  defp candidate(instructions \\ "system instructions") do
    {:ok, candidate} = PrefixStore.candidate(instructions, [schema()], identity())
    candidate
  end

  defp empty_continuation do
    Continuation.new()
  end

  defp continuation_with_history do
    prefix = candidate()
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)
    {:ok, request, active} = Continuation.begin_request(initial, "req-1", 1, "hello world")
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    outcome = Outcome.new(request, request.messages ++ [Context.assistant("hi there")])
    {:ok, completed} = Continuation.complete(active, outcome, 2)
    completed
  end

  defp continuation_with_active_request do
    prefix = candidate()
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)
    {:ok, _request, active} = Continuation.begin_request(initial, "req-1", 1, "question")
    active
  end

  defp continuation_with_tool_checkpoint do
    prefix = candidate()
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)
    {:ok, request, active} = Continuation.begin_request(initial, "req-1", 1, "run tool")

    assistant =
      Context.assistant("",
        tool_calls: [ToolCall.new("tc-1", "shell", ~s({"command":"ls"}))]
      )

    {:ok, _checkpoint_id, checkpointed} =
      Continuation.checkpoint_tool_group(
        active,
        request.request_id,
        # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
        request.messages ++ [assistant],
        [%{tool_call_id: "tc-1", name: "shell", arguments: %{"command" => "ls"}}]
      )

    checkpointed
  end

  defp continuation_with_tools do
    prefix = candidate()
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)
    {:ok, request, active} = Continuation.begin_request(initial, "req-tools", 1, "use a tool")

    tool_call = ToolCall.new("tc-1", "read_file", ~s({"path":"/tmp/x"}))
    assistant = Context.assistant("", tool_calls: [tool_call])

    {:ok, _checkpoint_id, checkpointed} =
      Continuation.checkpoint_tool_group(
        active,
        request.request_id,
        # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
        request.messages ++ [assistant],
        [%{tool_call_id: "tc-1", name: "read_file", arguments: %{"path" => "/tmp/x"}}]
      )

    result =
      Context.tool_result_message("read_file", "tc-1", "file contents", %{
        tool_outcome: :complete,
        is_error: false
      })

    {:ok, completed} =
      Continuation.complete_tool_effect(
        checkpointed,
        request.request_id,
        checkpointed.tool_checkpoint.checkpoint_id,
        "tc-1",
        result
      )

    outcome =
      Outcome.new(
        request,
        completed.tool_checkpoint.messages ++
          [result] ++ [Context.assistant("Done with the tool")]
      )

    {:ok, finished} = Continuation.complete(completed, outcome, 2)
    finished
  end

  defp large_selection do
    ModelSelectionFixture.selection(
      model_id: "large-model",
      limits: %{context: 200_000, input: nil, output: 8_192, request_output: 8_192}
    )
  end

  defp small_selection do
    ModelSelectionFixture.selection(
      model_id: "small-model",
      limits: %{context: 100, input: nil, output: 50, request_output: 50}
    )
  end

  defp no_tools_selection do
    ModelSelectionFixture.selection(
      model_id: "no-tools",
      capabilities: %{tools: false, images: true, streaming: true}
    )
  end

  defp no_images_selection do
    ModelSelectionFixture.selection(
      model_id: "no-images",
      capabilities: %{tools: true, images: false, streaming: true}
    )
  end

  # -- classify/2 -------------------------------------------------------------

  describe "classify/2" do
    test "returns :exact when routes are identical" do
      selection = ModelSelectionFixture.selection()
      assert ModelSwitch.classify(selection, selection) == :exact
    end

    test "returns {:handoff, :retain} for same provider/endpoint/credential with different model" do
      source = ModelSelectionFixture.selection(model_id: "model-a")
      dest = ModelSelectionFixture.selection(model_id: "model-b")

      assert ModelSwitch.classify(source, dest) == {:handoff, :retain}
    end

    test "returns {:handoff, :reject} for different providers" do
      source = ModelSelectionFixture.selection(request_provider: :openai)
      dest = ModelSelectionFixture.selection(request_provider: :anthropic)

      assert ModelSwitch.classify(source, dest) == {:handoff, :reject}
    end

    test "returns {:handoff, :reject} when source is nil" do
      dest = ModelSelectionFixture.selection()
      assert ModelSwitch.classify(nil, dest) == {:handoff, :reject}
    end

    test "returns {:handoff, :reject} for different base URLs" do
      source = ModelSelectionFixture.selection(base_url: "https://api.a.example/v1")
      dest = ModelSelectionFixture.selection(base_url: "https://api.b.example/v1")

      assert ModelSwitch.classify(source, dest) == {:handoff, :reject}
    end
  end

  # -- check_idle/1 -----------------------------------------------------------

  describe "check_idle/1" do
    test "returns :ok for empty continuation" do
      assert ModelSwitch.check_idle(empty_continuation()) == :ok
    end

    test "returns :ok for completed continuation" do
      assert ModelSwitch.check_idle(continuation_with_history()) == :ok
    end

    test "returns {:error, :busy} for active request" do
      assert ModelSwitch.check_idle(continuation_with_active_request()) == {:error, :busy}
    end

    test "returns {:error, :busy} for active tool checkpoint" do
      assert ModelSwitch.check_idle(continuation_with_tool_checkpoint()) == {:error, :busy}
    end
  end

  # -- check_budget/2 ---------------------------------------------------------

  describe "check_budget/2" do
    test "returns :ok when destination has no context limit" do
      selection =
        ModelSelectionFixture.selection(
          limits: %{context: nil, input: nil, output: 8_192, request_output: 8_192}
        )

      assert ModelSwitch.check_budget(selection, continuation_with_history()) == :ok
    end

    test "returns :ok when conversation fits in destination context" do
      assert ModelSwitch.check_budget(large_selection(), continuation_with_history()) == :ok
    end

    test "returns :ok for empty continuation regardless of context size" do
      assert ModelSwitch.check_budget(small_selection(), empty_continuation()) == :ok
    end

    test "returns {:error, :budget_exceeded} when history exceeds destination context" do
      # small_selection has 100 context, 50 reserve = 50 available tokens
      prefix = candidate(String.duplicate("a", 400))
      {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)

      {:ok, request, active} =
        Continuation.begin_request(initial, "big-req", 1, String.duplicate("b", 400))

      # credo:disable-for-lines:2 Credo.Check.Refactor.AppendSingleItem
      outcome =
        Outcome.new(request, request.messages ++ [Context.assistant(String.duplicate("c", 400))])

      {:ok, big} = Continuation.complete(active, outcome, 2)

      assert {:error, :budget_exceeded} = ModelSwitch.check_budget(small_selection(), big)
    end
  end

  # -- estimate_tokens/1 ------------------------------------------------------

  describe "estimate_tokens/1" do
    test "returns 0 for empty message list" do
      assert ModelSwitch.estimate_tokens([]) == 0
    end

    test "estimates tokens from text content" do
      messages = [Context.user("hello world")]
      tokens = ModelSwitch.estimate_tokens(messages)
      # "hello world" is 11 chars, ~2-3 tokens at 4 chars/token
      assert tokens > 0
      assert tokens <= 10
    end

    test "estimates tokens from multiple messages" do
      messages = [
        Context.system("You are helpful"),
        Context.user("What is 2+2?"),
        Context.assistant("4")
      ]

      tokens = ModelSwitch.estimate_tokens(messages)
      assert tokens > 0
    end
  end

  # -- capability_gaps/2 ------------------------------------------------------

  describe "capability_gaps/2" do
    test "returns empty list when no gaps" do
      source = ModelSelectionFixture.selection()
      dest = ModelSelectionFixture.selection()
      assert ModelSwitch.capability_gaps(source, dest) == []
    end

    test "returns empty list when source is nil" do
      dest = ModelSelectionFixture.selection()
      assert ModelSwitch.capability_gaps(nil, dest) == []
    end

    test "detects tool capability gap" do
      source =
        ModelSelectionFixture.selection(
          capabilities: %{tools: true, images: true, streaming: true}
        )

      dest = no_tools_selection()
      gaps = ModelSwitch.capability_gaps(source, dest)
      assert :tools in gaps
    end

    test "detects image capability gap" do
      source =
        ModelSelectionFixture.selection(
          capabilities: %{tools: true, images: true, streaming: true}
        )

      dest = no_images_selection()
      gaps = ModelSwitch.capability_gaps(source, dest)
      assert :images in gaps
    end

    test "does not flag gap when source also lacks the capability" do
      source = no_tools_selection()
      dest = no_tools_selection()
      assert ModelSwitch.capability_gaps(source, dest) == []
    end
  end

  # -- validate/3 (integration) -----------------------------------------------

  describe "validate/3" do
    test "succeeds for compatible switch with empty history" do
      source = ModelSelectionFixture.selection(model_id: "model-a")
      dest = ModelSelectionFixture.selection(model_id: "model-b")

      assert {:ok, {:handoff, :retain}} =
               ModelSwitch.validate(source, dest, empty_continuation())
    end

    test "succeeds for exact route match" do
      selection = ModelSelectionFixture.selection()

      assert {:ok, :exact} =
               ModelSwitch.validate(selection, selection, continuation_with_history())
    end

    test "succeeds for compatible switch with history that fits" do
      source = large_selection()
      dest = large_selection()

      assert {:ok, _compat} =
               ModelSwitch.validate(source, dest, continuation_with_history())
    end

    test "rejects switch during active request" do
      source = ModelSelectionFixture.selection()
      dest = ModelSelectionFixture.selection(model_id: "other")

      assert {:error, :busy} =
               ModelSwitch.validate(source, dest, continuation_with_active_request())
    end

    test "rejects switch during tool checkpoint" do
      source = ModelSelectionFixture.selection()
      dest = ModelSelectionFixture.selection(model_id: "other")

      assert {:error, :busy} =
               ModelSwitch.validate(source, dest, continuation_with_tool_checkpoint())
    end

    test "rejects when history exceeds destination budget" do
      source = large_selection()
      prefix = candidate(String.duplicate("x", 400))
      {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)

      {:ok, request, active} =
        Continuation.begin_request(initial, "big", 1, String.duplicate("y", 400))

      # credo:disable-for-lines:2 Credo.Check.Refactor.AppendSingleItem
      outcome =
        Outcome.new(request, request.messages ++ [Context.assistant(String.duplicate("z", 400))])

      {:ok, big} = Continuation.complete(active, outcome, 2)

      assert {:error, :budget_exceeded} =
               ModelSwitch.validate(source, small_selection(), big)
    end

    test "rejects switch when destination lacks tools and conversation uses them" do
      source =
        ModelSelectionFixture.selection(
          capabilities: %{tools: true, images: true, streaming: true}
        )

      history = continuation_with_tools()

      assert {:error, {:capability_gap, gaps}} =
               ModelSwitch.validate(source, no_tools_selection(), history)

      assert :tools in gaps
    end

    test "allows switch when destination lacks tools but conversation has no tool use" do
      source =
        ModelSelectionFixture.selection(
          capabilities: %{tools: true, images: true, streaming: true}
        )

      assert {:ok, _compat} =
               ModelSwitch.validate(source, no_tools_selection(), continuation_with_history())
    end

    test "allows switch from nil source" do
      dest = ModelSelectionFixture.selection()

      assert {:ok, {:handoff, :reject}} =
               ModelSwitch.validate(nil, dest, empty_continuation())
    end
  end

  # -- Message formatting -----------------------------------------------------

  describe "budget_exceeded_message/1" do
    test "includes estimated tokens and available context" do
      detail = %{
        estimated_tokens: 150_000,
        destination_context: 100_000,
        destination_reserve: 8_000,
        available: 92_000
      }

      message = ModelSwitch.budget_exceeded_message(detail)
      assert message =~ "150.0K"
      assert message =~ "92.0K"
      assert message =~ "100.0K"
    end
  end

  describe "capability_gap_message/1" do
    test "formats single gap" do
      message = ModelSwitch.capability_gap_message([:tools])
      assert message =~ "tool use"
    end

    test "formats multiple gaps" do
      message = ModelSwitch.capability_gap_message([:tools, :images])
      assert message =~ "tool use"
      assert message =~ "image input"
    end
  end
end
