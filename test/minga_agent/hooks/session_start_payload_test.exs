defmodule MingaAgent.Hooks.SessionStartPayloadTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.SessionStartPayload

  test "new/4 builds a payload with the session's folder" do
    payload = SessionStartPayload.new("sess_1", "claude-sonnet", "anthropic", "/work/project")

    assert payload.event == "SessionStart"
    assert payload.session_id == "sess_1"
    assert payload.model == "claude-sonnet"
    assert payload.provider == "anthropic"
    assert payload.project_root == "/work/project"
  end

  test "a session without a folder reports an empty root, not the process directory" do
    payload = SessionStartPayload.new("sess_1", "claude-sonnet", "anthropic", nil)

    assert payload.project_root == ""
  end

  test "to_map/1 produces the expected JSON shape" do
    payload = SessionStartPayload.new("sess_2", "gpt-4", "openai", "/work/project")
    map = SessionStartPayload.to_map(payload)

    assert map["event"] == "SessionStart"
    assert map["session_id"] == "sess_2"
    assert map["model"] == "gpt-4"
    assert map["provider"] == "openai"
    assert map["project_root"] == "/work/project"
  end

  test "payload is JSON-encodable" do
    payload = SessionStartPayload.new("sess_3", "claude-opus", "anthropic", "/work/project")
    json = JSON.encode!(payload)
    assert {:ok, decoded} = JSON.decode(json)
    assert decoded["event"] == "SessionStart"
    assert decoded["session_id"] == "sess_3"
  end
end
