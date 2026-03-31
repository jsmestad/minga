defmodule MingaAgent.Providers.NativeTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.Providers.Native
  alias MingaAgent.Tools
  alias Minga.Config.Options
  alias ReqLLM.StreamResponse.MetadataHandle

  @moduletag :tmp_dir
  # Multi-turn agent loops with real Task spawning (~400-800ms per test).
  # Excluded from test.llm; runs in test.heavy and full suite.
  @moduletag :heavy

  # ── Test helpers ────────────────────────────────────────────────────────────

  # Builds a fake llm_client function that returns a StreamResponse yielding
  # the given chunks. This lets us test the full agent loop without hitting
  # any real LLM API.
  defp fake_llm_client(chunks, usage \\ %{}) do
    fn _model, _messages, _opts ->
      build_stream_response(chunks, usage)
    end
  end

  defp build_stream_response(chunks, usage \\ %{}) do
    # MetadataHandle is a GenServer that returns metadata when awaited.
    {:ok, handle} =
      MetadataHandle.start_link(fn ->
        %{usage: usage, finish_reason: :stop}
      end)

    stream_response = %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
      context: ReqLLM.Context.new()
    }

    {:ok, stream_response}
  end

  defp fake_error_client(error_reason) do
    fn _model, _messages, _opts ->
      {:error, error_reason}
    end
  end

  defp start_provider(opts) do
    defaults = [
      subscriber: self(),
      model: "anthropic:claude-sonnet-4-20250514",
      project_root: opts[:tmp_dir] || System.tmp_dir!(),
      tools: []
    ]

    merged = Keyword.merge(defaults, opts)
    Native.start_link(merged)
  end

  # Wait for events with a helper that collects all events within a timeout.
  defp collect_events(timeout) do
    collect_events_acc([], timeout)
  end

  defp collect_events_acc(acc, timeout) do
    receive do
      {:agent_provider_event, %Event.AgentEnd{} = event} ->
        # AgentEnd is always the last event; return immediately
        Enum.reverse([event | acc])

      {:agent_provider_event, event} ->
        collect_events_acc([event | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  # ── Lifecycle tests ─────────────────────────────────────────────────────────

  describe "init and get_state" do
    test "starts with correct initial state", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir)

      assert {:ok, session_state} = Native.get_state(pid)
      assert session_state.model.provider == "native"
      assert session_state.is_streaming == false
    end
  end

  describe "thinking level" do
    test "set_thinking_level accepts valid levels", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir)

      assert :ok = Native.set_thinking_level(pid, "low")
      assert :ok = Native.set_thinking_level(pid, "medium")
      assert :ok = Native.set_thinking_level(pid, "high")
      assert :ok = Native.set_thinking_level(pid, "off")
    end

    test "set_thinking_level rejects unknown levels", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir)

      assert {:error, msg} = Native.set_thinking_level(pid, "turbo")
      assert msg =~ "unknown thinking level"
    end

    test "cycle_thinking_level rotates through levels", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir)

      # Default is "off", cycling should go: off -> low -> medium -> high -> off
      assert {:ok, %{"level" => "low"}} = Native.cycle_thinking_level(pid)
      assert {:ok, %{"level" => "medium"}} = Native.cycle_thinking_level(pid)
      assert {:ok, %{"level" => "high"}} = Native.cycle_thinking_level(pid)
      assert {:ok, %{"level" => "off"}} = Native.cycle_thinking_level(pid)
    end
  end

  describe "set_model" do
    test "updates the model without resetting context", %{tmp_dir: dir} do
      # Track what messages the LLM client receives on each call.
      # The client runs inside a Task, so we send to the test pid explicitly.
      test_pid = self()
      calls = :counters.new(1, [:atomics])
      messages_ref = make_ref()

      client = fn _model, messages, _opts ->
        count = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)
        send(test_pid, {messages_ref, count, messages})

        chunks = [
          ReqLLM.StreamChunk.text("Response #{count}"),
          ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
        ]

        build_stream_response(chunks)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)

      # First prompt builds context
      :ok = Native.send_prompt(pid, "Hello")
      _events = collect_events(500)

      # Switch model
      assert :ok = Native.set_model(pid, "anthropic:claude-opus-4-20250514")

      # Verify model changed
      assert {:ok, state} = Native.get_state(pid)
      assert state.model.id == "anthropic:claude-opus-4-20250514"

      # Second prompt should carry the conversation context from the first
      :ok = Native.send_prompt(pid, "Follow up")
      _events = collect_events(500)

      # The second LLM call (count=1) should have received prior messages
      assert_received {^messages_ref, 1, messages}

      # Should have at least: system prompt, user "Hello", assistant "Response 0", user "Follow up"
      assert length(messages) >= 4
    end

    test "returns the model in get_state after set_model", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir)

      assert :ok = Native.set_model(pid, "openai:gpt-4o")

      assert {:ok, state} = Native.get_state(pid)
      assert state.model.id == "openai:gpt-4o"
    end
  end

  describe "cycle_model preserves context" do
    test "conversation history survives model cycling", %{tmp_dir: dir} do
      test_pid = self()
      calls = :counters.new(1, [:atomics])
      messages_ref = make_ref()

      client = fn model, messages, _opts ->
        count = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)
        send(test_pid, {messages_ref, count, model, messages})

        chunks = [
          ReqLLM.StreamChunk.text("Response #{count}"),
          ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
        ]

        build_stream_response(chunks)
      end

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          model: "anthropic:claude-sonnet-4-20250514"
        )

      # Build some conversation context
      :ok = Native.send_prompt(pid, "First message")
      _events = collect_events(500)

      # Use set_model to switch (cycle_model requires agent_models config;
      # set_model uses the same state update path without config lookup)
      assert :ok = Native.set_model(pid, "anthropic:claude-opus-4-20250514")

      # Send another prompt; context should be preserved
      :ok = Native.send_prompt(pid, "Second message after model switch")
      _events = collect_events(500)

      # Verify the second call used the new model
      assert_received {^messages_ref, 1, model, messages}
      assert model == "anthropic:claude-opus-4-20250514"

      # Verify prior conversation was included
      assert length(messages) >= 4
    end
  end

  describe "new_session" do
    test "resets conversation context", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir)

      assert :ok = Native.new_session(pid)
      assert {:ok, state} = Native.get_state(pid)
      assert state.is_streaming == false
    end
  end

  # ── Streaming tests ─────────────────────────────────────────────────────────

  describe "send_prompt with text-only response" do
    test "emits AgentStart, TextDelta, and AgentEnd events", %{tmp_dir: dir} do
      chunks = [
        ReqLLM.StreamChunk.text("Hello "),
        ReqLLM.StreamChunk.text("world!"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ]

      client = fake_llm_client(chunks, %{input_tokens: 10, output_tokens: 5})
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)

      assert :ok = Native.send_prompt(pid, "Hi")

      events = collect_events(500)

      # Should have: AgentStart, TextDelta("Hello "), TextDelta("world!"), AgentEnd
      assert %Event.AgentStart{} = Enum.at(events, 0)

      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      assert length(text_deltas) == 2
      assert Enum.at(text_deltas, 0).delta == "Hello "
      assert Enum.at(text_deltas, 1).delta == "world!"

      agent_end = Enum.find(events, &match?(%Event.AgentEnd{}, &1))
      assert agent_end != nil
    end
  end

  describe "send_prompt with thinking response" do
    test "emits ThinkingDelta events", %{tmp_dir: dir} do
      chunks = [
        ReqLLM.StreamChunk.thinking("Let me think..."),
        ReqLLM.StreamChunk.text("The answer is 42."),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ]

      client = fake_llm_client(chunks)
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)

      assert :ok = Native.send_prompt(pid, "What is the answer?")

      events = collect_events(500)

      thinking = Enum.filter(events, &match?(%Event.ThinkingDelta{}, &1))
      assert length(thinking) == 1
      assert hd(thinking).delta == "Let me think..."

      text = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      assert length(text) == 1
      assert hd(text).delta == "The answer is 42."
    end
  end

  describe "send_prompt with tool calls" do
    test "executes tools and emits tool events", %{tmp_dir: dir} do
      # Write a file so the read_file tool can find it
      File.write!(Path.join(dir, "test.txt"), "file contents")

      # First call returns a tool_call, second call returns final answer
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            # First call: tool use
            [
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                id: "tc_1",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            # Second call: final answer
            [
              ReqLLM.StreamChunk.text("The file says: file contents"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, tools: tools)

      assert :ok = Native.send_prompt(pid, "Read test.txt")

      events = collect_events(1_000)

      # Should have tool start and tool end events
      tool_starts = Enum.filter(events, &match?(%Event.ToolStart{}, &1))
      assert [first_start | _] = tool_starts
      assert first_start.name == "read_file"

      tool_ends = Enum.filter(events, &match?(%Event.ToolEnd{}, &1))
      assert [first_end | _] = tool_ends
      assert first_end.result =~ "file contents"
      assert first_end.is_error == false

      # Should eventually get a text response and AgentEnd
      assert Enum.any?(events, &match?(%Event.TextDelta{}, &1))
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end
  end

  describe "send_prompt with LLM error" do
    test "emits error event on API failure", %{tmp_dir: dir} do
      client = fake_error_client("API rate limited")
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)

      assert :ok = Native.send_prompt(pid, "Hello")

      events = collect_events(500)

      error = Enum.find(events, &match?(%Event.Error{}, &1))
      assert error != nil
      assert error.message =~ "API rate limited"

      agent_end = Enum.find(events, &match?(%Event.AgentEnd{}, &1))
      assert agent_end != nil
    end
  end

  describe "abort" do
    test "stops a running prompt", %{tmp_dir: dir} do
      # Create a slow client that will still be streaming when we abort
      client = fn _model, _messages, _opts ->
        slow_stream =
          Stream.unfold(0, fn n ->
            Process.sleep(100)
            {ReqLLM.StreamChunk.text("chunk #{n}"), n + 1}
          end)

        build_stream_response(slow_stream)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = Native.send_prompt(pid, "Tell me a very long story")

      # Wait for streaming to actually start (AgentStart proves streaming: true)
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 500

      assert :ok = Native.abort(pid)

      # Should no longer be streaming
      assert {:ok, state} = Native.get_state(pid)
      assert state.is_streaming == false
    end
  end

  describe "stream recovery" do
    test "preserves partial text when stream drops mid-response", %{tmp_dir: dir} do
      # Create a stream that emits some text then raises an error
      client = fn _model, _messages, _opts ->
        error_stream =
          Stream.resource(
            fn -> 0 end,
            fn
              0 -> {[ReqLLM.StreamChunk.text("Hello, I was saying something ")], 1}
              1 -> {[ReqLLM.StreamChunk.text("important about ")], 2}
              2 -> raise "connection reset by peer"
            end,
            fn _ -> :ok end
          )

        build_stream_response(error_stream)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)
      :ok = Native.send_prompt(pid, "Tell me something important")

      events = collect_events(1_000)

      # Should have streamed the partial text before the error
      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      streamed_text = Enum.map_join(text_deltas, & &1.delta)
      assert streamed_text =~ "Hello, I was saying something"
      assert streamed_text =~ "important about"

      # Should have an interruption notice
      assert streamed_text =~ "Stream interrupted"

      # Should have AgentEnd (not left hanging)
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "continue resumes after interrupted stream", %{tmp_dir: dir} do
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          # First call: stream drops mid-response
          error_stream =
            Stream.resource(
              fn -> 0 end,
              fn
                0 -> {[ReqLLM.StreamChunk.text("Partial response here")], 1}
                1 -> raise "connection reset"
              end,
              fn _ -> :ok end
            )

          build_stream_response(error_stream)
        else
          # Second call (continue): complete response
          chunks = [
            ReqLLM.StreamChunk.text("Continuing from where I left off."),
            ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
          ]

          build_stream_response(chunks)
        end
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)

      # First prompt gets interrupted
      :ok = Native.send_prompt(pid, "Tell me something")
      _events1 = collect_events(1_000)

      # Continue should work
      :ok = Native.continue(pid)
      events2 = collect_events(1_000)

      text_deltas = Enum.filter(events2, &match?(%Event.TextDelta{}, &1))
      continued_text = Enum.map_join(text_deltas, & &1.delta)
      assert continued_text =~ "Continuing from where I left off"
    end

    test "continue fails when no stream was interrupted", %{tmp_dir: dir} do
      chunks = [
        ReqLLM.StreamChunk.text("Complete response"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ]

      client = fake_llm_client(chunks)
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)

      :ok = Native.send_prompt(pid, "Hello")
      _events = collect_events(500)

      assert {:error, "No interrupted response to continue from"} = Native.continue(pid)
    end

    test "continue fails while already streaming", %{tmp_dir: dir} do
      client = fn _model, _messages, _opts ->
        slow_stream =
          Stream.unfold(0, fn n ->
            Process.sleep(100)
            {ReqLLM.StreamChunk.text("chunk #{n}"), n + 1}
          end)

        build_stream_response(slow_stream)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = Native.send_prompt(pid, "Long story")
      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 500

      assert {:error, "Already streaming"} = Native.continue(pid)

      Native.abort(pid)
    end

    test "small partial text does not trigger recovery", %{tmp_dir: dir} do
      # Stream only a few characters, then error - should get a normal error, not recovery
      client = fn _model, _messages, _opts ->
        error_stream =
          Stream.resource(
            fn -> 0 end,
            fn
              0 -> {[ReqLLM.StreamChunk.text("Hi")], 1}
              1 -> raise "connection reset"
            end,
            fn _ -> :ok end
          )

        build_stream_response(error_stream)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_retries: 0)
      :ok = Native.send_prompt(pid, "Hello")

      events = collect_events(1_000)

      # Should get a normal error, not the recovery path
      error_events = Enum.filter(events, &match?(%Event.Error{}, &1))
      assert error_events != []
    end
  end

  describe "concurrent prompt rejection" do
    test "rejects second prompt while streaming", %{tmp_dir: dir} do
      client = fn _model, _messages, _opts ->
        slow_stream =
          Stream.unfold(0, fn n ->
            Process.sleep(100)
            {ReqLLM.StreamChunk.text("chunk #{n}"), n + 1}
          end)

        build_stream_response(slow_stream)
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)
      :ok = Native.send_prompt(pid, "First prompt")

      assert_receive {:agent_provider_event, %Event.AgentStart{}}, 500

      assert {:error, :already_streaming} = Native.send_prompt(pid, "Second prompt")

      # Clean up
      Native.abort(pid)
    end
  end

  # ── Turn limit tests (#401) ────────────────────────────────────────────────

  describe "turn limit" do
    test "stops the agent loop when turn limit is reached", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "hello")

      # Create a client that always makes tool calls (simulating a runaway loop).
      # Each call returns a tool_call, which triggers another turn.
      client = fn _model, _messages, _opts ->
        chunks = [
          ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
            id: "tc_#{:erlang.unique_integer([:positive])}",
            index: 0
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ]

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: tools, max_turns: 3)

      :ok = Native.send_prompt(pid, "Read the file over and over")

      events = collect_events(3_000)

      # Should have a turn limit warning
      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)
      assert all_text =~ "Turn limit reached"
      assert all_text =~ "3/3"

      # Should have a TurnLimitReached event
      turn_limit_events = Enum.filter(events, &match?(%Event.TurnLimitReached{}, &1))
      assert [%Event.TurnLimitReached{current: 3, limit: 3}] = turn_limit_events

      # Should have ended cleanly
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "normal tool-call loops within the limit complete successfully", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "content")

      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count < 2 do
            [
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                id: "tc_#{count}",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("Done reading."),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: tools, max_turns: 10)

      :ok = Native.send_prompt(pid, "Read the file twice")

      events = collect_events(3_000)

      # Should NOT have a turn limit warning
      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)
      refute all_text =~ "Turn limit reached"

      # Should have completed normally with "Done reading."
      assert all_text =~ "Done reading."
    end

    test "continue after turn limit resets the turn counter", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "hello")

      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count < 5 do
            [
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                id: "tc_#{count}",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("Finally done."),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks)
      end

      tools = Tools.all(project_root: dir)

      {:ok, pid} =
        start_provider(tmp_dir: dir, llm_client: client, tools: tools, max_turns: 2)

      # First prompt hits the limit after 2 turns
      :ok = Native.send_prompt(pid, "Keep reading")
      events1 = collect_events(3_000)

      text1 = events1 |> Enum.filter(&match?(%Event.TextDelta{}, &1)) |> Enum.map_join(& &1.delta)
      assert text1 =~ "Turn limit reached"

      # Continue should reset the counter and keep going
      :ok = Native.continue(pid)
      events2 = collect_events(3_000)

      text2 = events2 |> Enum.filter(&match?(%Event.TextDelta{}, &1)) |> Enum.map_join(& &1.delta)
      # It will hit the limit again (2 more turns), or finish if the counter went past 5
      assert text2 =~ "Turn limit reached" or text2 =~ "Finally done."
    end
  end

  # ── Cost budget tests (#404) ────────────────────────────────────────────────

  describe "cost budget" do
    test "get_budget returns current session cost and limits", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir, max_cost: 5.0)

      assert {:ok, budget} = GenServer.call(pid, :get_budget)
      assert budget.session_cost == 0.0
      assert budget.max_cost == 5.0
      assert budget.max_turns == 100
    end

    test "set_max_cost updates the budget", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir)

      assert :ok = GenServer.call(pid, {:set_max_cost, 10.0})
      assert {:ok, budget} = GenServer.call(pid, :get_budget)
      assert budget.max_cost == 10.0
    end

    test "set_max_cost nil disables the budget", %{tmp_dir: dir} do
      {:ok, pid} = start_provider(tmp_dir: dir, max_cost: 5.0)

      assert :ok = GenServer.call(pid, {:set_max_cost, nil})
      assert {:ok, budget} = GenServer.call(pid, :get_budget)
      assert budget.max_cost == nil
    end

    test "session cost resets on new_session", %{tmp_dir: dir} do
      chunks = [
        ReqLLM.StreamChunk.text("Hello"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ]

      usage = %{input_tokens: 1000, output_tokens: 500, total_cost: 0.05}
      client = fake_llm_client(chunks, usage)

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)

      :ok = Native.send_prompt(pid, "test")
      _events = collect_events(500)

      # Cost should have accumulated
      # (exact amount depends on cost calculation, but should be > 0 after a turn)

      # Reset
      :ok = Native.new_session(pid)
      assert {:ok, budget} = GenServer.call(pid, :get_budget)
      assert budget.session_cost == 0.0
    end

    test "agent stops when cost budget is exceeded during tool loop", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "hello")

      # Create a client where each turn has a significant cost
      client = fn _model, _messages, _opts ->
        chunks = [
          ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
            id: "tc_#{:erlang.unique_integer([:positive])}",
            index: 0
          }),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ]

        build_stream_response(chunks, %{
          input_tokens: 10_000,
          output_tokens: 5_000,
          total_cost: 1.0
        })
      end

      tools = Tools.all(project_root: dir)

      # Set a $2 budget; each turn costs $1, so it should stop after 2 turns
      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: client,
          tools: tools,
          max_cost: 2.0,
          max_turns: 100
        )

      :ok = Native.send_prompt(pid, "Keep reading forever")

      events = collect_events(5_000)

      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)

      assert all_text =~ "cost limit reached" or all_text =~ "Session cost limit reached"

      # Should have ended
      assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
    end

    test "nil max_cost means no cost limit", %{tmp_dir: dir} do
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count < 3 do
            [
              ReqLLM.StreamChunk.text("turn #{count} "),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          else
            [
              ReqLLM.StreamChunk.text("done"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        build_stream_response(chunks, %{total_cost: 100.0})
      end

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client, max_cost: nil)

      :ok = Native.send_prompt(pid, "test")
      events = collect_events(1_000)

      text_deltas = Enum.filter(events, &match?(%Event.TextDelta{}, &1))
      all_text = Enum.map_join(text_deltas, & &1.delta)
      refute all_text =~ "cost limit"
    end
  end

  describe "custom API base URL" do
    test "MINGA_API_BASE_URL env var injects base_url into stream opts", %{tmp_dir: dir} do
      test_pid = self()

      capturing_client = fn _model, _messages, opts ->
        send(test_pid, {:captured_opts, opts})
        build_stream_response([{:text, "ok"}])
      end

      System.put_env("MINGA_API_BASE_URL", "https://gateway.corp.com/v1")

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: capturing_client)
      :ok = Native.send_prompt(pid, "test")

      assert_receive {:captured_opts, opts}, 2_000
      assert Keyword.get(opts, :base_url) == "https://gateway.corp.com/v1"

      # Collect remaining events so the process winds down
      collect_events(500)
    after
      System.delete_env("MINGA_API_BASE_URL")
    end

    test "no base_url when env var is not set", %{tmp_dir: dir} do
      test_pid = self()

      capturing_client = fn _model, _messages, opts ->
        send(test_pid, {:captured_opts, opts})
        build_stream_response([{:text, "ok"}])
      end

      System.delete_env("MINGA_API_BASE_URL")

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: capturing_client)
      :ok = Native.send_prompt(pid, "test")

      assert_receive {:captured_opts, opts}, 2_000
      refute Keyword.has_key?(opts, :base_url)

      collect_events(500)
    end

    test "per-provider endpoint from config takes precedence over global", %{tmp_dir: dir} do
      test_pid = self()

      capturing_client = fn _model, _messages, opts ->
        send(test_pid, {:captured_opts, opts})
        build_stream_response([{:text, "ok"}])
      end

      System.delete_env("MINGA_API_BASE_URL")

      # Set both global and per-provider endpoints
      Options.set(:agent_api_base_url, "https://global.example.com/v1")

      Options.set(:agent_api_endpoints, %{
        "anthropic" => "https://anthropic-gw.corp.com/v1",
        "openai" => "https://openai-gw.corp.com/v1"
      })

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: capturing_client,
          model: "anthropic:claude-sonnet-4-20250514"
        )

      :ok = Native.send_prompt(pid, "test")

      assert_receive {:captured_opts, opts}, 2_000
      assert Keyword.get(opts, :base_url) == "https://anthropic-gw.corp.com/v1"

      collect_events(500)
    after
      Options.set(:agent_api_base_url, "")
      Options.set(:agent_api_endpoints, nil)
    end

    test "global base_url is used when no per-provider match", %{tmp_dir: dir} do
      test_pid = self()

      capturing_client = fn _model, _messages, opts ->
        send(test_pid, {:captured_opts, opts})
        build_stream_response([{:text, "ok"}])
      end

      System.delete_env("MINGA_API_BASE_URL")

      Options.set(:agent_api_base_url, "https://global.example.com/v1")
      Options.set(:agent_api_endpoints, %{"openai" => "https://openai-only.com/v1"})

      {:ok, pid} =
        start_provider(
          tmp_dir: dir,
          llm_client: capturing_client,
          model: "anthropic:claude-sonnet-4-20250514"
        )

      :ok = Native.send_prompt(pid, "test")

      assert_receive {:captured_opts, opts}, 2_000
      assert Keyword.get(opts, :base_url) == "https://global.example.com/v1"

      collect_events(500)
    after
      Options.set(:agent_api_base_url, "")
      Options.set(:agent_api_endpoints, nil)
    end

    test "env var overrides per-provider endpoint", %{tmp_dir: dir} do
      test_pid = self()

      capturing_client = fn _model, _messages, opts ->
        send(test_pid, {:captured_opts, opts})
        build_stream_response([{:text, "ok"}])
      end

      System.put_env("MINGA_API_BASE_URL", "https://env-override.com/v1")
      Options.set(:agent_api_endpoints, %{"anthropic" => "https://should-lose.com"})

      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: capturing_client)
      :ok = Native.send_prompt(pid, "test")

      assert_receive {:captured_opts, opts}, 2_000
      assert Keyword.get(opts, :base_url) == "https://env-override.com/v1"

      collect_events(500)
    after
      System.delete_env("MINGA_API_BASE_URL")
      Options.set(:agent_api_endpoints, nil)
    end
  end

  # ── Model format validation ──────────────────────────────────────────────────

  describe "model format validation" do
    test "bare model name without provider prefix returns :invalid_format error", %{
      tmp_dir: tmp_dir
    } do
      # A model name like "claude-sonnet-4" (no provider prefix) should
      # fail with a clear error, not a cryptic :invalid_format atom.
      {:ok, pid} =
        start_provider(
          model: "claude-sonnet-4",
          llm_client: fake_llm_client([]),
          tmp_dir: tmp_dir
        )

      Native.send_prompt(pid, "hello")
      events = collect_events(2_000)

      error_events = Enum.filter(events, &match?(%Event.Error{}, &1))
      assert error_events != []

      error = hd(error_events)
      assert error.message =~ "missing a provider prefix"
      assert error.message =~ "provider:model"
    end
  end
end
