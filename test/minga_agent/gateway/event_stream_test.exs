defmodule MingaAgent.Gateway.EventStreamTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Gateway.EventStream

  describe "format_notification/1" do
    test "formats agent_session_stopped event" do
      event =
        {:minga_event, :agent_session_stopped, %{session_id: "session-1", reason: :normal}}

      {:ok, json} = EventStream.format_notification(event)
      decoded = JSON.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "event.agent_session_stopped"
      assert decoded["params"]["session_id"] == "session-1"
      assert decoded["params"]["reason"] == ":normal"
      refute Map.has_key?(decoded, "id")
    end

    test "formats log_message event" do
      event =
        {:minga_event, :log_message, %{text: "LSP connected", level: :info}}

      {:ok, json} = EventStream.format_notification(event)
      decoded = JSON.decode!(json)

      assert decoded["method"] == "event.log_message"
      assert decoded["params"]["text"] == "LSP connected"
      assert decoded["params"]["level"] == "info"
    end

    test "formats buffer_saved event" do
      event =
        {:minga_event, :buffer_saved, %{path: "/tmp/foo.ex"}}

      {:ok, json} = EventStream.format_notification(event)
      decoded = JSON.decode!(json)

      assert decoded["method"] == "event.buffer_saved"
      assert decoded["params"]["path"] == "/tmp/foo.ex"
    end

    test "formats buffer_changed event" do
      event =
        {:minga_event, :buffer_changed, %{path: "/tmp/bar.ex", source: :user}}

      {:ok, json} = EventStream.format_notification(event)
      decoded = JSON.decode!(json)

      assert decoded["method"] == "event.buffer_changed"
      assert decoded["params"]["path"] == "/tmp/bar.ex"
    end

    test "skips unknown event topics" do
      event = {:minga_event, :unknown_topic, %{data: "stuff"}}
      assert :skip == EventStream.format_notification(event)
    end
  end

  describe "subscribe_all/0" do
    test "returns :ok" do
      assert :ok == EventStream.subscribe_all()
    end
  end
end
