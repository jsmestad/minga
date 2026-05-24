defmodule MingaAgent.Hooks.StopPayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.StopPayload

  test "new/3 builds a payload with all fields" do
    payload = StopPayload.new("sess_1", :end_turn, "Here is the result")

    assert payload.event == "Stop"
    assert payload.session_id == "sess_1"
    assert payload.reason == "end_turn"
    assert payload.last_message == "Here is the result"
  end

  test "new/2 defaults last_message to nil" do
    payload = StopPayload.new("sess_2", :end_turn)

    assert payload.last_message == nil
  end

  test "last_message is truncated when it exceeds 1KB" do
    large_msg = String.duplicate("x", 2_000)
    payload = StopPayload.new("sess_3", :end_turn, large_msg)

    assert byte_size(payload.last_message) < 2_000
    assert String.ends_with?(payload.last_message, "\n... (truncated)")
  end

  test "to_map/1 produces the expected JSON shape" do
    payload = StopPayload.new("sess_4", :end_turn, "done")
    map = StopPayload.to_map(payload)

    assert map == %{
             "event" => "Stop",
             "session_id" => "sess_4",
             "reason" => "end_turn",
             "last_message" => "done"
           }
  end

  test "payload is JSON-encodable" do
    payload = StopPayload.new("sess_5", :end_turn, "result text")
    json = JSON.encode!(payload)
    assert {:ok, decoded} = JSON.decode(json)
    assert decoded["event"] == "Stop"
    assert decoded["reason"] == "end_turn"
  end
end
