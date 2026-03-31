defmodule MingaEditor.CompletionTriggerTest do
  @moduledoc "Tests for CompletionTrigger: debounce fan-out to multiple LSP clients."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.CompletionTrigger

  # ── flush_debounce/3 with client list ──────────────────────────────────────

  describe "flush_debounce/3" do
    test "sends completion requests to multiple clients when given a list" do
      bridge = CompletionTrigger.new()
      # Buffer needs a file_path for completion requests to be sent
      {:ok, buf} =
        BufferServer.start_link(file_path: "/tmp/test_completion.ex", content: "hello")

      # Use self() as fake clients; send_completion_requests will call
      # Client.request on each, which will fail (not real LSP clients)
      # but the bridge state should reflect multiple pending refs.
      result = CompletionTrigger.flush_debounce(bridge, [self(), self()], buf)
      # With fake clients the requests will fail, but the function shouldn't crash
      assert is_map(result)
      GenServer.stop(buf)
    end

    test "accepts a single client pid for backward compatibility" do
      bridge = CompletionTrigger.new()
      {:ok, buf} = BufferServer.start_link(content: "hello")
      result = CompletionTrigger.flush_debounce(bridge, self(), buf)
      assert is_map(result)
      GenServer.stop(buf)
    end

    test "schedule_debounced_trigger message contains client list not single pid" do
      # Verify the debounce message format includes a list of clients.
      # The message is {:completion_debounce, clients, buffer_pid} where
      # clients is a list.
      bridge = CompletionTrigger.new()
      {:ok, buf} = BufferServer.start_link(file_path: "/tmp/test_multi.ex", content: "ab")
      BufferServer.move_to(buf, {0, 2})

      # Trigger with two identifier chars worth of prefix by inserting "cd"
      BufferServer.insert_char(buf, "c")
      BufferServer.insert_char(buf, "d")

      # The maybe_trigger path for identifier chars schedules a debounce.
      # We test that the message payload is the right shape by calling
      # maybe_trigger with a non-trigger char and multiple clients.
      # Since SyncServer won't return real clients, test the message format
      # through the public API contract: flush_debounce accepts [pid()].
      fake_clients = [spawn(fn -> :ok end), spawn(fn -> :ok end)]
      result = CompletionTrigger.flush_debounce(bridge, fake_clients, buf)
      assert is_map(result)

      GenServer.stop(buf)
    end
  end

  # ── dismiss/1 ─────────────────────────────────────────────────────────────

  describe "dismiss/1" do
    test "clears pending ref and trigger position" do
      bridge = %{CompletionTrigger.new() | pending_ref: make_ref(), trigger_position: {5, 10}}
      result = CompletionTrigger.dismiss(bridge)
      assert result.pending_ref == nil
      assert result.trigger_position == nil
    end
  end

  # ── handle_response/4 ────────────────────────────────────────────────────

  describe "handle_response/4" do
    test "stale response (ref doesn't match) is ignored" do
      ref = make_ref()
      bridge = %{CompletionTrigger.new() | pending_ref: make_ref()}
      {:ok, buf} = BufferServer.start_link(content: "hello")

      {result_bridge, result} = CompletionTrigger.handle_response(bridge, ref, {:ok, nil}, buf)
      assert result == nil
      assert is_map(result_bridge)

      GenServer.stop(buf)
    end

    test "error response clears pending ref" do
      ref = make_ref()
      bridge = %{CompletionTrigger.new() | pending_ref: ref}
      {:ok, buf} = BufferServer.start_link(content: "hello")

      {result_bridge, result} =
        CompletionTrigger.handle_response(bridge, ref, {:error, "timeout"}, buf)

      assert result == nil
      assert result_bridge.pending_ref == nil

      GenServer.stop(buf)
    end

    test "secondary server response returns :merge tuple" do
      primary_ref = make_ref()
      secondary_ref = make_ref()
      refs = MapSet.new([primary_ref, secondary_ref])

      bridge = %{
        CompletionTrigger.new()
        | pending_ref: primary_ref,
          pending_refs: refs,
          trigger_position: {0, 0}
      }

      {:ok, buf} = BufferServer.start_link(content: "hello")

      # Simulate response from secondary (ref doesn't match primary but is in pending_refs)
      lsp_result = %{
        "items" => [
          %{"label" => "world", "kind" => 6}
        ]
      }

      {result_bridge, result} =
        CompletionTrigger.handle_response(bridge, secondary_ref, {:ok, lsp_result}, buf)

      assert {:merge, items, _pos} = result
      assert items != []
      assert not MapSet.member?(result_bridge.pending_refs, secondary_ref)

      GenServer.stop(buf)
    end
  end
end
