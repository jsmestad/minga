defmodule Minga.Agent.Providers.PiRpcTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Event
  alias Minga.Agent.Providers.PiRpc

  @fake_pi Path.expand("../../../support/fake_pi.sh", __DIR__)

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Starts a PiRpc GenServer backed by a fake pi script.
  # The fake script reads stdin forever and never writes to stdout,
  # keeping the port alive so we can exercise handle_call and
  # handle_info clauses without a real pi binary.
  defp start_fake_provider do
    {:ok, pid} = PiRpc.start_link(subscriber: self(), pi_path: @fake_pi)
    pid
  end

  # Returns the OS port from a running PiRpc GenServer.
  defp get_port(pid) do
    %{port: port} = :sys.get_state(pid)
    port
  end

  # Injects a JSON event line into the PiRpc GenServer as if pi wrote it.
  defp inject_event(pid, json) when is_binary(json) do
    port = get_port(pid)
    send(pid, {port, {:data, {:eol, json}}})
    # Give the GenServer time to process
    :sys.get_state(pid)
  end

  # Asserts that the test process received an agent provider event
  # matching the given pattern within 200ms.
  defmacrop assert_event(pattern) do
    quote do
      assert_receive {:agent_provider_event, unquote(pattern)}, 200
    end
  end

  # ── Unsupported command handle_call tests ───────────────────────────────────

  describe "unsupported commands return errors" do
    setup do
      %{pid: start_fake_provider()}
    end

    test "summarize returns error", %{pid: pid} do
      assert {:error, msg} = GenServer.call(pid, :summarize)
      assert msg =~ "not supported"
    end

    test "compact returns error", %{pid: pid} do
      assert {:error, msg} = GenServer.call(pid, :compact)
      assert msg =~ "not supported"
    end

    test "continue returns error", %{pid: pid} do
      assert {:error, msg} = GenServer.call(pid, :continue)
      assert msg =~ "not supported"
    end
  end

  # ── Command handle_call tests (write to port) ──────────────────────────────

  describe "commands that write to the port" do
    setup do
      %{pid: start_fake_provider()}
    end

    test "send_prompt writes JSON to port and returns :ok", %{pid: pid} do
      assert :ok = PiRpc.send_prompt(pid, "hello")
    end

    test "abort writes JSON to port and returns :ok", %{pid: pid} do
      assert :ok = PiRpc.abort(pid)
    end

    test "new_session writes JSON to port and returns :ok", %{pid: pid} do
      assert :ok = PiRpc.new_session(pid)
    end

    test "set_thinking_level writes JSON to port and returns :ok", %{pid: pid} do
      assert :ok = PiRpc.set_thinking_level(pid, "high")
    end
  end

  # ── Async request handle_call tests ─────────────────────────────────────────

  describe "async requests (get_state, get_available_models, etc.)" do
    setup do
      %{pid: start_fake_provider()}
    end

    test "get_state resolves when pi responds", %{pid: pid} do
      # Call get_state in a task so it doesn't block us
      task = Task.async(fn -> PiRpc.get_state(pid) end)

      # Wait for the pending request to appear.
      # The Task needs time to enter GenServer.call before we can inspect state.
      req_id = poll_pending(pid)

      # Simulate pi responding
      response =
        JSON.encode!(%{
          "id" => req_id,
          "type" => "response",
          "command" => "get_state",
          "success" => true,
          "data" => %{"model" => %{"id" => "test-model"}}
        })

      inject_event(pid, response)

      assert {:ok, %{"model" => %{"id" => "test-model"}}} = Task.await(task, 1000)

      # Pending map should be empty now
      assert %{pending: pending} = :sys.get_state(pid)
      assert pending == %{}
    end

    test "get_available_models resolves when pi responds", %{pid: pid} do
      task = Task.async(fn -> PiRpc.get_available_models(pid) end)
      req_id = poll_pending(pid)

      response =
        JSON.encode!(%{
          "id" => req_id,
          "type" => "response",
          "success" => true,
          "data" => [%{"id" => "model-1"}, %{"id" => "model-2"}]
        })

      inject_event(pid, response)
      assert {:ok, [%{"id" => "model-1"}, %{"id" => "model-2"}]} = Task.await(task, 1000)
    end

    test "failed response returns error tuple", %{pid: pid} do
      task = Task.async(fn -> PiRpc.get_state(pid) end)
      req_id = poll_pending(pid)

      response =
        JSON.encode!(%{
          "id" => req_id,
          "type" => "response",
          "success" => false,
          "error" => "something broke"
        })

      inject_event(pid, response)
      assert {:error, "something broke"} = Task.await(task, 1000)
    end
  end

  # Polls :sys.get_state until the pending map has at least one entry.
  # Returns the first pending request id.
  defp poll_pending(pid, attempts \\ 50) do
    state = :sys.get_state(pid)

    case Map.to_list(state.pending) do
      [{req_id, _from} | _] ->
        req_id

      [] when attempts > 0 ->
        Process.sleep(5)
        poll_pending(pid, attempts - 1)

      [] ->
        flunk("pending map never populated after polling")
    end
  end

  # ── Event handling (handle_info → handle_event) ─────────────────────────────

  describe "event handling via port messages" do
    setup do
      %{pid: start_fake_provider()}
    end

    test "agent_start event notifies subscriber", %{pid: pid} do
      inject_event(pid, ~s({"type": "agent_start"}))
      assert_event(%Event.AgentStart{})
    end

    test "agent_end event with usage notifies subscriber", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "agent_end",
          "messages" => [
            %{
              "role" => "assistant",
              "usage" => %{
                "input" => 100,
                "output" => 50,
                "cacheRead" => 10,
                "cacheWrite" => 5,
                "cost" => %{"total" => 0.02}
              }
            }
          ]
        })

      inject_event(pid, json)
      assert_event(%Event.AgentEnd{usage: usage})
      assert usage.input == 100
      assert usage.output == 50
      assert usage.cache_read == 10
      assert usage.cache_write == 5
      assert usage.cost == 0.02
    end

    test "agent_end event without usage", %{pid: pid} do
      inject_event(pid, ~s({"type": "agent_end", "messages": []}))
      assert_event(%Event.AgentEnd{usage: nil})
    end

    test "agent_end aggregates usage across multiple assistant messages", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "agent_end",
          "messages" => [
            %{
              "role" => "assistant",
              "usage" => %{
                "input" => 100,
                "output" => 50,
                "cacheRead" => 0,
                "cacheWrite" => 0,
                "cost" => %{"total" => 0.01}
              }
            },
            %{
              "role" => "assistant",
              "usage" => %{
                "input" => 200,
                "output" => 100,
                "cacheRead" => 0,
                "cacheWrite" => 0,
                "cost" => %{"total" => 0.03}
              }
            }
          ]
        })

      inject_event(pid, json)
      assert_event(%Event.AgentEnd{usage: usage})
      assert usage.input == 300
      assert usage.output == 150
      assert usage.cost == 0.04
    end

    test "text_delta event notifies subscriber", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hello world"}
        })

      inject_event(pid, json)
      assert_event(%Event.TextDelta{delta: "Hello world"})
    end

    test "thinking_delta event notifies subscriber", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "thinking_delta", "delta" => "reasoning..."}
        })

      inject_event(pid, json)
      assert_event(%Event.ThinkingDelta{delta: "reasoning..."})
    end

    test "unknown delta type is silently ignored", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "message_update",
          "assistantMessageEvent" => %{"type" => "some_new_delta", "delta" => "data"}
        })

      inject_event(pid, json)
      refute_receive {:agent_provider_event, _}, 50
    end

    test "tool_execution_start event notifies subscriber", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "tool_execution_start",
          "toolCallId" => "call_1",
          "toolName" => "bash",
          "args" => %{"command" => "ls"}
        })

      inject_event(pid, json)
      assert_event(%Event.ToolStart{tool_call_id: "call_1", name: "bash"})
    end

    test "tool_execution_start with missing fields uses defaults", %{pid: pid} do
      json = JSON.encode!(%{"type" => "tool_execution_start"})
      inject_event(pid, json)
      assert_event(%Event.ToolStart{tool_call_id: "", name: "unknown", args: %{}})
    end

    test "tool_execution_update event notifies subscriber", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "tool_execution_update",
          "toolCallId" => "call_1",
          "toolName" => "bash",
          "partialResult" => %{"content" => [%{"text" => "file1.ex"}]}
        })

      inject_event(pid, json)
      assert_event(%Event.ToolUpdate{tool_call_id: "call_1", partial_result: "file1.ex"})
    end

    test "tool_execution_end event notifies subscriber", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "tool_execution_end",
          "toolCallId" => "call_1",
          "toolName" => "bash",
          "result" => %{"content" => [%{"text" => "done"}]},
          "isError" => false
        })

      inject_event(pid, json)
      assert_event(%Event.ToolEnd{tool_call_id: "call_1", result: "done", is_error: false})
    end

    test "tool_execution_end error event sets is_error", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "tool_execution_end",
          "toolCallId" => "call_1",
          "toolName" => "bash",
          "result" => %{"content" => [%{"text" => "failed"}]},
          "isError" => true
        })

      inject_event(pid, json)
      assert_event(%Event.ToolEnd{is_error: true})
    end

    test "extension_ui_request dialog auto-cancels", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "extension_ui_request",
          "method" => "confirm",
          "id" => "dialog-1"
        })

      inject_event(pid, json)

      # Should not crash; the auto-cancel response is written to the port.
      assert Process.alive?(pid)
    end

    test "extension_ui_request fire-and-forget methods are ignored", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "extension_ui_request",
          "method" => "setStatus",
          "id" => "status-1"
        })

      inject_event(pid, json)
      assert Process.alive?(pid)
    end

    test "extension_error is logged but does not crash", %{pid: pid} do
      json =
        JSON.encode!(%{
          "type" => "extension_error",
          "error" => "something went wrong"
        })

      inject_event(pid, json)
      assert Process.alive?(pid)
    end

    test "unknown event type is silently ignored", %{pid: pid} do
      inject_event(pid, ~s({"type": "some_future_event", "data": "whatever"}))
      assert Process.alive?(pid)
      refute_receive {:agent_provider_event, _}, 50
    end

    test "malformed JSON is silently ignored", %{pid: pid} do
      inject_event(pid, "this is not json")
      assert Process.alive?(pid)
      refute_receive {:agent_provider_event, _}, 50
    end

    test "response without matching pending request is ignored", %{pid: pid} do
      json =
        JSON.encode!(%{
          "id" => "req-999",
          "type" => "response",
          "success" => true,
          "data" => %{}
        })

      inject_event(pid, json)
      assert Process.alive?(pid)
    end

    test "response without id is ignored", %{pid: pid} do
      json = JSON.encode!(%{"type" => "response", "command" => "prompt", "success" => true})
      inject_event(pid, json)
      assert Process.alive?(pid)
    end
  end

  # ── Port data framing ──────────────────────────────────────────────────────

  describe "port data framing" do
    setup do
      %{pid: start_fake_provider()}
    end

    test "noeol chunks are buffered until eol arrives", %{pid: pid} do
      port = get_port(pid)

      # Send partial line
      send(pid, {port, {:data, {:noeol, ~s({"type":)}}})
      :sys.get_state(pid)

      # No event yet
      refute_receive {:agent_provider_event, _}, 50

      # Complete the line
      send(pid, {port, {:data, {:eol, ~s( "agent_start"})}}})
      :sys.get_state(pid)

      assert_event(%Event.AgentStart{})
    end

    test "OSC prefix before JSON is stripped", %{pid: pid} do
      osc_prefixed = ~s(]777;notify;something{"type": "agent_start"})
      inject_event(pid, osc_prefixed)
      assert_event(%Event.AgentStart{})
    end
  end

  # ── Port exit ───────────────────────────────────────────────────────────────

  describe "port exit" do
    test "port exit sends Error event and stops GenServer" do
      pid = start_fake_provider()
      # Trap exits so the linked GenServer dying doesn't kill the test
      Process.flag(:trap_exit, true)
      ref = Process.monitor(pid)
      port = get_port(pid)

      # Simulate port exit
      send(pid, {port, {:exit_status, 1}})

      assert_event(%Event.Error{message: msg})
      assert msg =~ "pi process exited"
      assert_receive {:DOWN, ^ref, :process, ^pid, {:pi_exited, 1}}, 500
    end
  end

  # ── Init failures ───────────────────────────────────────────────────────────

  describe "init" do
    test "fails when pi binary path does not exist" do
      # Trap exits so the linked GenServer dying doesn't kill the test
      Process.flag(:trap_exit, true)
      result = PiRpc.start_link(subscriber: self(), pi_path: "/nonexistent/pi")
      assert {:error, {:spawn_failed, _}} = result
    end
  end

  # ── Protocol probe (requires real pi) ───────────────────────────────────────

  describe "protocol probe against live pi" do
    @describetag :pi
    @describetag timeout: 15_000

    setup do
      pi_path = System.find_executable("pi")

      if pi_path do
        {:ok, pid} = PiRpc.start_link(subscriber: self(), pi_path: pi_path)
        %{pid: pid}
      else
        :skip
      end
    end

    test "get_state returns expected response shape", %{pid: pid} do
      assert {:ok, data} = PiRpc.get_state(pid)

      # Core fields that must exist in the response
      assert is_map(data["model"]), "get_state must return a model map"
      assert is_binary(data["model"]["id"]), "model must have an id"
      assert is_binary(data["model"]["name"]), "model must have a name"
      assert is_binary(data["model"]["provider"]), "model must have a provider"
      assert is_boolean(data["isStreaming"]), "must report isStreaming"
      assert is_binary(data["sessionId"]), "must report sessionId"

      # Fields we depend on for display
      assert Map.has_key?(data, "thinkingLevel"),
             "get_state response missing thinkingLevel (pi protocol changed?)"

      assert Map.has_key?(data, "messageCount"),
             "get_state response missing messageCount (pi protocol changed?)"
    end
  end
end
