defmodule MingaAgent.Hooks.PostToolUsePayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.PostToolUsePayload

  test "new/5 builds a payload with all fields" do
    payload =
      PostToolUsePayload.new("tc_1", "read_file", %{"path" => "a.txt"}, "file contents", false)

    assert payload.event == "PostToolUse"
    assert payload.tool_call_id == "tc_1"
    assert payload.tool_name == "read_file"
    assert payload.arguments == %{"path" => "a.txt"}
    assert payload.result == "file contents"
    assert payload.is_error == false
  end

  test "new/1 builds a payload from a map" do
    payload =
      PostToolUsePayload.new(%{
        id: "tc_2",
        name: "shell",
        arguments: %{"command" => "ls"},
        result: "dir listing",
        is_error: false
      })

    assert payload.tool_call_id == "tc_2"
    assert payload.tool_name == "shell"
    assert payload.arguments == %{"command" => "ls"}
    assert payload.result == "dir listing"
    assert payload.is_error == false
  end

  test "to_map/1 produces the expected JSON shape" do
    payload = PostToolUsePayload.new("tc_3", "write_file", %{"path" => "b.txt"}, "ok", false)
    map = PostToolUsePayload.to_map(payload)

    assert map == %{
             "event" => "PostToolUse",
             "tool_call_id" => "tc_3",
             "tool_name" => "write_file",
             "arguments" => %{"path" => "b.txt"},
             "result" => "ok",
             "is_error" => false
           }
  end

  test "result is truncated when it exceeds 10KB" do
    large_result = String.duplicate("x", 20_000)
    payload = PostToolUsePayload.new("tc_4", "shell", %{}, large_result, false)

    assert byte_size(payload.result) < 20_000
    assert String.ends_with?(payload.result, "\n... (truncated)")
  end

  test "new/1 defaults missing id to a generated value" do
    payload =
      PostToolUsePayload.new(%{name: "test", arguments: %{}, result: "ok", is_error: false})

    assert String.starts_with?(payload.tool_call_id, "tool_")
  end

  test "new/1 defaults missing arguments to empty map" do
    payload = PostToolUsePayload.new(%{id: "tc_5", name: "test", result: "ok", is_error: false})
    assert payload.arguments == %{}
  end

  test "is_error true is preserved" do
    payload = PostToolUsePayload.new("tc_6", "shell", %{}, "error msg", true)
    assert payload.is_error == true
  end
end
