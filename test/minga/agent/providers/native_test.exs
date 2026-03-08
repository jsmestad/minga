defmodule Minga.Agent.Providers.NativeTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Event
  alias Minga.Agent.Providers.Native
  alias Minga.Agent.Tools
  alias ReqLLM.StreamResponse.MetadataHandle

  @moduletag :tmp_dir

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
      {:ok, pid} = start_provider(tmp_dir: dir, llm_client: client)

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

      # Give it a moment to start streaming
      Process.sleep(50)

      assert :ok = Native.abort(pid)

      # Should no longer be streaming
      assert {:ok, state} = Native.get_state(pid)
      assert state.is_streaming == false
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

      Process.sleep(50)

      assert {:error, :already_streaming} = Native.send_prompt(pid, "Second prompt")

      # Clean up
      Native.abort(pid)
    end
  end
end
