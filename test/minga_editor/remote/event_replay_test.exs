defmodule MingaEditor.Remote.EventReplayTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Remote.EventReplay
  alias MingaAgent.EventLog.EventRecord

  test "converts durable remote events into live agent events" do
    assert EventReplay.to_agent_event(record(:assistant_delta, %{"delta" => "hello"})) ==
             {:text_delta, "hello"}

    assert EventReplay.to_agent_event(
             record(:file_edit_proposed, %{
               "path" => "lib/a.ex",
               "before_content" => "old",
               "after_content" => "new",
               "tool_call_id" => "tc1",
               "tool_name" => "write_file"
             })
           ) ==
             {:file_changed, "lib/a.ex", "old", "new", "tc1", "write_file"}

    assert EventReplay.to_agent_event(
             record(:approval_requested, %{
               "tool_call_id" => "tc1",
               "name" => "shell",
               "args" => %{"command" => "mix test"},
               "preview" => %{"kind" => "shell"}
             })
           ) ==
             {:approval_pending,
              %{
                tool_call_id: "tc1",
                name: "shell",
                args: %{"command" => "mix test"},
                preview: %{"kind" => "shell"}
              }}

    assert EventReplay.to_agent_event(record(:waiting_for_input, %{})) == {:status_changed, :idle}

    assert EventReplay.to_agent_event(
             record(:prompt_queued, %{"content" => "next", "queue" => "follow_up"})
           ) == {:prompt_queued, "next", :follow_up}

    assert EventReplay.to_agent_event(record(:message_changed, %{})) == :messages_changed
  end

  test "ignores durable events that have no foreground UI equivalent" do
    assert EventReplay.to_agent_event(record(:session_started, %{})) == nil
    assert EventReplay.to_agent_event(record(:system_message, %{"message" => "connected"})) == nil
  end

  @spec record(MingaAgent.EventLog.EventRecord.event_type(), map()) :: EventRecord.t()
  defp record(event_type, payload) do
    EventRecord.new("session", event_type, payload)
  end
end
