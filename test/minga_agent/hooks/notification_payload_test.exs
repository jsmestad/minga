defmodule MingaAgent.Hooks.NotificationPayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.NotificationPayload

  test "new/3 builds a payload with all fields" do
    payload = NotificationPayload.new("sess_1", :complete, "Agent finished")

    assert payload.event == "Notification"
    assert payload.session_id == "sess_1"
    assert payload.kind == "complete"
    assert payload.message == "Agent finished"
  end

  test "to_map/1 produces the expected JSON shape" do
    payload = NotificationPayload.new("sess_2", :approval, "Tool needs approval")
    map = NotificationPayload.to_map(payload)

    assert map == %{
             "event" => "Notification",
             "session_id" => "sess_2",
             "kind" => "approval",
             "message" => "Tool needs approval"
           }
  end

  test "payload is JSON-encodable" do
    payload = NotificationPayload.new("sess_3", :error, "Something failed")
    json = JSON.encode!(payload)
    assert {:ok, decoded} = JSON.decode(json)
    assert decoded["event"] == "Notification"
    assert decoded["kind"] == "error"
  end
end
