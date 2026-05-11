defmodule MingaAgent.Hooks.SessionStartPayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.SessionStartPayload

  test "new/3 builds a payload with all fields" do
    payload = SessionStartPayload.new("sess_1", "claude-sonnet", "anthropic")

    assert payload.event == "SessionStart"
    assert payload.session_id == "sess_1"
    assert payload.model == "claude-sonnet"
    assert payload.provider == "anthropic"
    assert is_binary(payload.project_root)
  end

  test "to_map/1 produces the expected JSON shape" do
    payload = SessionStartPayload.new("sess_2", "gpt-4", "openai")
    map = SessionStartPayload.to_map(payload)

    assert map["event"] == "SessionStart"
    assert map["session_id"] == "sess_2"
    assert map["model"] == "gpt-4"
    assert map["provider"] == "openai"
    assert is_binary(map["project_root"])
  end

  test "payload is Jason-encodable" do
    payload = SessionStartPayload.new("sess_3", "claude-opus", "anthropic")
    assert {:ok, json} = Jason.encode(payload)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["event"] == "SessionStart"
    assert decoded["session_id"] == "sess_3"
  end
end
