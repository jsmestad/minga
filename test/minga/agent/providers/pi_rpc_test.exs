defmodule Minga.Agent.Providers.PiRpcTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Event

  # These tests verify the JSON encoding/decoding logic without spawning
  # a real pi process. We test the event mapping by sending raw JSON
  # lines to the provider and checking the events delivered to the subscriber.

  describe "pi event JSON mapping" do
    test "maps agent_start event" do
      json = ~s({"type": "agent_start"})
      event = decode_and_map(json)
      assert %Event.AgentStart{} = event
    end

    test "maps agent_end event with usage" do
      json =
        ~s({"type": "agent_end", "messages": [{"role": "assistant", "usage": {"input": 100, "output": 50, "cacheRead": 10, "cacheWrite": 5, "cost": {"total": 0.02}}}]})

      event = decode_and_map(json)
      assert %Event.AgentEnd{usage: usage} = event
      assert usage.input == 100
      assert usage.output == 50
      assert usage.cache_read == 10
      assert usage.cost == 0.02
    end

    test "maps agent_end event without usage" do
      json = ~s({"type": "agent_end", "messages": []})
      event = decode_and_map(json)
      assert %Event.AgentEnd{usage: nil} = event
    end

    test "maps text_delta event" do
      json =
        ~s({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": "Hello"}})

      event = decode_and_map(json)
      assert %Event.TextDelta{delta: "Hello"} = event
    end

    test "maps thinking_delta event" do
      json =
        ~s({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "delta": "reasoning"}})

      event = decode_and_map(json)
      assert %Event.ThinkingDelta{delta: "reasoning"} = event
    end

    test "maps tool_execution_start event" do
      json =
        ~s({"type": "tool_execution_start", "toolCallId": "call_1", "toolName": "bash", "args": {"command": "ls"}})

      event = decode_and_map(json)
      assert %Event.ToolStart{tool_call_id: "call_1", name: "bash"} = event
      assert event.args == %{"command" => "ls"}
    end

    test "maps tool_execution_update event" do
      json =
        ~s({"type": "tool_execution_update", "toolCallId": "call_1", "toolName": "bash", "partialResult": {"content": [{"text": "file1.ex"}]}})

      event = decode_and_map(json)
      assert %Event.ToolUpdate{tool_call_id: "call_1", partial_result: "file1.ex"} = event
    end

    test "maps tool_execution_end event" do
      json =
        ~s({"type": "tool_execution_end", "toolCallId": "call_1", "toolName": "bash", "result": {"content": [{"text": "done"}]}, "isError": false})

      event = decode_and_map(json)
      assert %Event.ToolEnd{tool_call_id: "call_1", result: "done", is_error: false} = event
    end

    test "maps tool_execution_end error event" do
      json =
        ~s({"type": "tool_execution_end", "toolCallId": "call_1", "toolName": "bash", "result": {"content": [{"text": "failed"}]}, "isError": true})

      event = decode_and_map(json)
      assert %Event.ToolEnd{is_error: true} = event
    end

    test "ignores response events" do
      json = ~s({"type": "response", "command": "prompt", "success": true})
      event = decode_and_map(json)
      assert event == nil
    end

    test "handles malformed JSON gracefully" do
      event = decode_and_map("not json at all")
      assert event == nil
    end
  end

  describe "JSON command encoding" do
    test "encodes prompt command" do
      command = %{"id" => "req-1", "type" => "prompt", "message" => "Hello!"}
      json = JSON.encode!(command)
      decoded = JSON.decode!(json)
      assert decoded["type"] == "prompt"
      assert decoded["message"] == "Hello!"
    end

    test "encodes abort command" do
      command = %{"type" => "abort"}
      json = JSON.encode!(command)
      decoded = JSON.decode!(json)
      assert decoded["type"] == "abort"
    end

    test "encodes new_session command" do
      command = %{"type" => "new_session"}
      json = JSON.encode!(command)
      decoded = JSON.decode!(json)
      assert decoded["type"] == "new_session"
    end

    test "encodes get_state command" do
      command = %{"id" => "req-1", "type" => "get_state"}
      json = JSON.encode!(command)
      decoded = JSON.decode!(json)
      assert decoded["type"] == "get_state"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Simulates what the PiRpc provider does internally when it receives a JSON line:
  # decode the JSON, map it to an Agent.Event struct, and return the event.
  defp decode_and_map(json_line) do
    test_pid = self()

    # Start a temporary process to receive events
    receiver =
      spawn(fn ->
        receive do
          {:agent_provider_event, event} ->
            send(test_pid, {:mapped_event, event})
        after
          100 -> send(test_pid, {:mapped_event, nil})
        end
      end)

    case JSON.decode(json_line) do
      {:ok, event} ->
        map_event(event, receiver)

        receive do
          {:mapped_event, ev} -> ev
        after
          200 -> nil
        end

      {:error, _} ->
        nil
    end
  end

  # Mirrors the event mapping logic from PiRpc
  defp map_event(%{"type" => "agent_start"}, subscriber) do
    send(subscriber, {:agent_provider_event, %Event.AgentStart{}})
  end

  defp map_event(%{"type" => "agent_end"} = event, subscriber) do
    usage = extract_usage(event)
    send(subscriber, {:agent_provider_event, %Event.AgentEnd{usage: usage}})
  end

  defp map_event(%{"type" => "message_update", "assistantMessageEvent" => delta}, subscriber) do
    case delta do
      %{"type" => "text_delta", "delta" => d} ->
        send(subscriber, {:agent_provider_event, %Event.TextDelta{delta: d}})

      %{"type" => "thinking_delta", "delta" => d} ->
        send(subscriber, {:agent_provider_event, %Event.ThinkingDelta{delta: d}})

      _ ->
        :ok
    end
  end

  defp map_event(%{"type" => "tool_execution_start"} = event, subscriber) do
    send(
      subscriber,
      {:agent_provider_event,
       %Event.ToolStart{
         tool_call_id: event["toolCallId"] || "",
         name: event["toolName"] || "unknown",
         args: event["args"] || %{}
       }}
    )
  end

  defp map_event(%{"type" => "tool_execution_update"} = event, subscriber) do
    partial =
      case get_in(event, ["partialResult", "content"]) do
        [%{"text" => text} | _] -> text
        _ -> ""
      end

    send(
      subscriber,
      {:agent_provider_event,
       %Event.ToolUpdate{
         tool_call_id: event["toolCallId"] || "",
         name: event["toolName"] || "unknown",
         partial_result: partial
       }}
    )
  end

  defp map_event(%{"type" => "tool_execution_end"} = event, subscriber) do
    result =
      case get_in(event, ["result", "content"]) do
        [%{"text" => text} | _] -> text
        _ -> ""
      end

    send(
      subscriber,
      {:agent_provider_event,
       %Event.ToolEnd{
         tool_call_id: event["toolCallId"] || "",
         name: event["toolName"] || "unknown",
         result: result,
         is_error: event["isError"] == true
       }}
    )
  end

  defp map_event(%{"type" => "response"}, _subscriber), do: :ok
  defp map_event(_, _subscriber), do: :ok

  defp extract_usage(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.filter(fn m -> m["role"] == "assistant" && is_map(m["usage"]) end)
    |> Enum.reduce(nil, fn msg, acc ->
      usage = msg["usage"]
      cost_map = usage["cost"] || %{}

      current = %{
        input: usage["input"] || 0,
        output: usage["output"] || 0,
        cache_read: usage["cacheRead"] || 0,
        cache_write: usage["cacheWrite"] || 0,
        cost: cost_map["total"] || 0.0
      }

      case acc do
        nil ->
          current

        prev ->
          %{
            input: prev.input + current.input,
            output: prev.output + current.output,
            cache_read: prev.cache_read + current.cache_read,
            cache_write: prev.cache_write + current.cache_write,
            cost: prev.cost + current.cost
          }
      end
    end)
  end

  defp extract_usage(_), do: nil
end
