defmodule MingaAgent.Hooks.PreCompactPayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.PreCompactPayload

  test "new/1 builds a payload with message_count" do
    payload = PreCompactPayload.new(42)

    assert payload.event == "PreCompact"
    assert payload.message_count == 42
    assert payload.session_id == nil
  end

  test "new/2 accepts an optional session_id" do
    payload = PreCompactPayload.new(10, "sess_1")

    assert payload.session_id == "sess_1"
    assert payload.message_count == 10
  end

  test "to_map/1 produces the expected JSON shape" do
    payload = PreCompactPayload.new(5, "sess_2")
    map = PreCompactPayload.to_map(payload)

    assert map == %{
             "event" => "PreCompact",
             "session_id" => "sess_2",
             "message_count" => 5
           }
  end

  test "payload is JSON-encodable" do
    payload = PreCompactPayload.new(3)
    json = JSON.encode!(payload)
    assert {:ok, decoded} = JSON.decode(json)
    assert decoded["event"] == "PreCompact"
    assert decoded["message_count"] == 3
  end
end
