defmodule MingaEditor.Remote.EventReplayTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Events, as: AgentEvents
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.Viewport
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.TodoItem

  test "converts durable remote events into live agent events" do
    assert EventReplay.to_agent_event(record(:assistant_delta, %{"delta" => "hello"})) ==
             {:text_delta, "hello"}

    assert EventReplay.to_agent_event(
             record(:tool_call_started, %{
               "tool_call_id" => "tc1",
               "name" => "read_file",
               "args" => %{"path" => "lib/a.ex"}
             })
           ) == {:tool_started, "tc1", "read_file", %{"path" => "lib/a.ex"}}

    assert EventReplay.to_agent_event(
             record(:tool_call_finished, %{
               "tool_call_id" => "tc1",
               "name" => "read_file",
               "result" => "ok",
               "status" => "done"
             })
           ) == {:tool_ended, "tc1", "read_file", "ok", :done}

    assert EventReplay.to_agent_event(record(:tool_call_interrupted, %{"tool_call_id" => "tc2"})) ==
             {:tool_interrupted, "tc2"}

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
               "preview" => %{
                 "kind" => "command",
                 "summary" => "mix test",
                 "lines" => ["$ mix test", "cwd: /tmp"]
               }
             })
           ) ==
             {:approval_pending,
              %{
                tool_call_id: "tc1",
                name: "shell",
                args: %{"command" => "mix test"},
                preview: %Preview{
                  kind: :command,
                  summary: "mix test",
                  lines: ["$ mix test", "cwd: /tmp"]
                }
              }}

    assert {:approval_pending, approval} =
             EventReplay.to_agent_event(
               record(:approval_requested, %{
                 "tool_call_id" => "tc2",
                 "name" => "shell",
                 "args" => %{"command" => "mix test"},
                 "preview" => %{"kind" => "nope", "summary" => "bad", "lines" => ["x"]}
               })
             )

    assert approval.tool_call_id == "tc2"
    assert approval.name == "shell"
    assert approval.args == %{"command" => "mix test"}
    refute Map.has_key?(approval, :preview)

    assert {:approval_pending, approval} =
             EventReplay.to_agent_event(
               record(:approval_requested, %{
                 "tool_call_id" => "tc3",
                 "name" => "shell",
                 "args" => %{"command" => "mix test"},
                 "preview" => %{"kind" => "shell"}
               })
             )

    assert approval.tool_call_id == "tc3"
    assert approval.name == "shell"
    assert approval.args == %{"command" => "mix test"}
    refute Map.has_key?(approval, :preview)

    assert EventReplay.to_agent_event(record(:waiting_for_input, %{})) == {:status_changed, :idle}

    assert EventReplay.to_agent_event(
             record(:prompt_queued, %{"content" => "next", "queue" => "follow_up"})
           ) == {:prompt_queued, "next", :follow_up}

    assert EventReplay.to_agent_event(record(:message_changed, %{})) == :messages_changed

    assert EventReplay.to_agent_event(
             record(:todo_plan_updated, %{
               "todos" => [
                 %{"id" => "1", "description" => "Inspect files", "status" => "done"}
               ]
             })
           ) ==
             {:todo_plan_updated,
              [%TodoItem{id: "1", description: "Inspect files", status: :done}]}
  end

  test "replays durable todo plans into editor activity on catch-up" do
    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %WorkspaceState{viewport: Viewport.new(24, 80)}
    }

    updated =
      AgentEvents.replay_catchup(state, [
        record(:todo_plan_updated, %{
          "todos" => [
            %{"id" => "1", "description" => "Inspect files", "status" => "in_progress"}
          ]
        })
      ])

    assert updated.workspace.agent_ui.view.activity.todos == [
             %TodoItem{id: "1", description: "Inspect files", status: :in_progress}
           ]
  end

  test "replays durable shell tool lifecycle records into editor activity on catch-up" do
    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %WorkspaceState{viewport: Viewport.new(24, 80)}
    }

    updated =
      AgentEvents.replay_catchup(state, [
        record(:tool_call_started, %{
          "tool_call_id" => "tc1",
          "name" => "shell",
          "args" => %{"command" => "mix test"}
        }),
        record(:tool_call_finished, %{
          "tool_call_id" => "tc1",
          "name" => "shell",
          "result" => "ok",
          "status" => "done"
        })
      ])

    assert updated.workspace.agent_ui.view.activity.active_action == "Thinking"

    assert MingaEditor.Shell.Traditional.State.agent(updated.shell_runtime.state).runtime.active_tool_name ==
             nil

    assert updated.workspace.agent_ui.view.preview.content == {:shell, "mix test", "ok", :done}
  end

  test "replays durable tool interruptions into editor activity on catch-up" do
    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %WorkspaceState{viewport: Viewport.new(24, 80)}
    }

    updated =
      AgentEvents.replay_catchup(state, [
        record(:tool_call_started, %{
          "tool_call_id" => "tc2",
          "name" => "shell",
          "args" => %{"command" => "mix test"}
        }),
        record(:tool_call_interrupted, %{"tool_call_id" => "tc2"})
      ])

    assert updated.workspace.agent_ui.view.activity.active_action == "Thinking"

    assert MingaEditor.Shell.Traditional.State.agent(updated.shell_runtime.state).runtime.active_tool_name ==
             nil

    assert updated.workspace.agent_ui.view.preview.content == :empty
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
