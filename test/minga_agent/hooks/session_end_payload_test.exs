defmodule MingaAgent.Hooks.SessionEndPayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.SessionEndPayload

  test "new/3 normalizes :normal reason" do
    payload = SessionEndPayload.new("sess_1", :normal, :idle)

    assert payload.event == "SessionEnd"
    assert payload.session_id == "sess_1"
    assert payload.reason == "normal"
    assert payload.status == "idle"
  end

  test "new/3 normalizes :shutdown reason" do
    payload = SessionEndPayload.new("sess_2", :shutdown, :thinking)
    assert payload.reason == "shutdown"
  end

  test "new/3 normalizes {:shutdown, _} reason" do
    payload = SessionEndPayload.new("sess_3", {:shutdown, :timeout}, :error)
    assert payload.reason == "shutdown"
  end

  test "new/3 normalizes unexpected reasons as crash" do
    payload = SessionEndPayload.new("sess_4", {:badarg, []}, :thinking)
    assert payload.reason == "crash"
  end

  test "to_map/1 produces the expected JSON shape" do
    payload = SessionEndPayload.new("sess_5", :normal, :idle)
    map = SessionEndPayload.to_map(payload)

    assert map == %{
             "event" => "SessionEnd",
             "session_id" => "sess_5",
             "reason" => "normal",
             "status" => "idle"
           }
  end

  test "payload is JSON-encodable" do
    payload = SessionEndPayload.new("sess_6", :shutdown, :idle)
    json = JSON.encode!(payload)
    assert {:ok, decoded} = JSON.decode(json)
    assert decoded["event"] == "SessionEnd"
    assert decoded["reason"] == "shutdown"
  end
end
