defmodule MingaEditor.UI.Picker.AgentSessionSourceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.RemoteAPI.SessionInfo
  alias MingaAgent.SessionListing
  alias MingaAgent.SessionMetadata
  alias MingaEditor.UI.Picker.AgentSessionSource

  test "renders unavailable remote metadata without invented session details" do
    info =
      "session-7"
      |> SessionListing.unavailable(self(), :timeout)
      |> SessionInfo.from_listing("token")

    item = AgentSessionSource.remote_session_item("build-host", info)

    assert item.label == "[build-host] session-7"
    assert item.description == "Metadata unavailable (timed out)"
    assert item.annotation == "unavailable"
    assert item.search_text == "session-7"
    refute item.description =~ "unknown"
  end

  test "preserves healthy remote session presentation" do
    now = ~U[2026-09-14 17:30:00Z]

    metadata = %SessionMetadata{
      id: "session-8",
      title: "Fix parser",
      model_name: "gpt-real",
      provider_name: "openai",
      created_at: now,
      last_message_at: now,
      message_count: 4,
      status: :thinking
    }

    info = SessionInfo.new("session-8", self(), "token", metadata)
    item = AgentSessionSource.remote_session_item("build-host", info)

    assert item.label == "[build-host] Fix parser"
    assert item.description == "openai/gpt-real · 4 msgs · Sep 14 17:30"
    assert item.annotation == "thinking"
  end
end
