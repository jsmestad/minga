defmodule Minga.Agent.ToolCallTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.ToolCall

  describe "new/3" do
    test "creates a running tool call with monotonic timestamp" do
      tc = ToolCall.new("tc1", "bash", %{"command" => "ls"})

      assert tc.id == "tc1"
      assert tc.name == "bash"
      assert tc.args == %{"command" => "ls"}
      assert tc.status == :running
      assert tc.result == ""
      assert tc.is_error == false
      assert tc.collapsed == true
      assert is_integer(tc.started_at)
      assert tc.duration_ms == nil
    end

    test "defaults args to empty map" do
      tc = ToolCall.new("tc1", "read")
      assert tc.args == %{}
    end
  end

  describe "complete/2" do
    test "marks tool call as complete with result and duration" do
      tc = ToolCall.new("tc1", "bash")
      completed = ToolCall.complete(tc, "file contents")

      assert completed.status == :complete
      assert completed.result == "file contents"
      assert completed.is_error == false
      assert completed.collapsed == true
      assert is_integer(completed.duration_ms)
      assert completed.duration_ms >= 0
    end
  end

  describe "error/2" do
    test "marks tool call as failed with error result" do
      tc = ToolCall.new("tc1", "bash")
      errored = ToolCall.error(tc, "command not found")

      assert errored.status == :error
      assert errored.result == "command not found"
      assert errored.is_error == true
      assert errored.collapsed == true
      assert is_integer(errored.duration_ms)
    end
  end

  describe "abort/1" do
    test "aborts a running tool call" do
      tc = ToolCall.new("tc1", "bash")
      aborted = ToolCall.abort(tc)

      assert aborted.status == :error
      assert aborted.result == "aborted"
      assert aborted.is_error == true
    end

    test "is a no-op on already-completed tool calls" do
      tc = ToolCall.new("tc1", "bash") |> ToolCall.complete("done")
      same = ToolCall.abort(tc)

      assert same.status == :complete
      assert same.result == "done"
    end
  end

  describe "update_partial/2" do
    test "sets partial result and expands the display" do
      tc = ToolCall.new("tc1", "bash")
      assert tc.collapsed == true

      updated = ToolCall.update_partial(tc, "partial output")
      assert updated.result == "partial output"
      assert updated.collapsed == false
    end
  end

  describe "toggle_collapsed/1" do
    test "toggles collapsed state" do
      tc = ToolCall.new("tc1", "bash")
      assert tc.collapsed == true

      toggled = ToolCall.toggle_collapsed(tc)
      assert toggled.collapsed == false

      toggled_back = ToolCall.toggle_collapsed(toggled)
      assert toggled_back.collapsed == true
    end
  end

  describe "set_collapsed/2" do
    test "sets collapsed to specific value" do
      tc = ToolCall.new("tc1", "bash")
      expanded = ToolCall.set_collapsed(tc, false)
      assert expanded.collapsed == false
    end
  end

  describe "finished?/1" do
    test "returns false for running tool calls" do
      tc = ToolCall.new("tc1", "bash")
      refute ToolCall.finished?(tc)
    end

    test "returns true for completed tool calls" do
      tc = ToolCall.new("tc1", "bash") |> ToolCall.complete("done")
      assert ToolCall.finished?(tc)
    end

    test "returns true for errored tool calls" do
      tc = ToolCall.new("tc1", "bash") |> ToolCall.error("fail")
      assert ToolCall.finished?(tc)
    end
  end

  describe "@enforce_keys" do
    test "requires id and name" do
      assert_raise ArgumentError, fn ->
        struct!(ToolCall, %{name: "bash"})
      end

      assert_raise ArgumentError, fn ->
        struct!(ToolCall, %{id: "tc1"})
      end
    end
  end
end
