defmodule MingaEditor.Remote.EventReplayTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Taxonomy
  alias MingaAgent.TodoItem
  alias MingaAgent.ToolApproval.Preview

  test "canonical conversion contract covers every persisted event family" do
    expected_events =
      Enum.map(event_examples(), fn {event_type, payload, expected} ->
        assert EventReplay.to_agent_event(record(event_type, payload)) == expected
        event_type
      end)

    assert MapSet.new(expected_events) == MapSet.new(Taxonomy.events())
  end

  test "canonical conversion normalizes malformed replay payloads without crashing" do
    assert EventReplay.to_agent_event(
             record(:tool_call_finished, %{
               "tool_call_id" => "tc1",
               "name" => "shell",
               "result" => "failed",
               "status" => "failed"
             })
           ) == {:tool_ended, "tc1", "shell", "failed", :error}

    assert EventReplay.to_agent_event(record(:status_changed, %{"status" => "not_existing"})) ==
             {:status_changed, :unknown}

    assert EventReplay.to_agent_event(
             record(:context_usage, %{"estimated_tokens" => "bad", "context_limit" => nil})
           ) == {:context_usage, 0, 0}

    assert EventReplay.to_agent_event(
             record(:todo_plan_updated, %{
               "todos" => [
                 %{"id" => "1", "description" => "Inspect files", "status" => "in_progress"},
                 %{"id" => "", "description" => "Missing id", "status" => "done"},
                 %{"id" => "2", "description" => "", "status" => "done"},
                 :invalid
               ]
             })
           ) ==
             {:todo_plan_updated,
              [%TodoItem{id: "1", description: "Inspect files", status: :in_progress}]}
  end

  test "approval previews accept only complete known preview payloads" do
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

    assert {:approval_pending, invalid_kind} =
             EventReplay.to_agent_event(
               record(:approval_requested, %{
                 "tool_call_id" => "tc2",
                 "name" => "shell",
                 "args" => %{"command" => "mix test"},
                 "preview" => %{"kind" => "nope", "summary" => "bad", "lines" => ["x"]}
               })
             )

    assert invalid_kind.tool_call_id == "tc2"
    refute Map.has_key?(invalid_kind, :preview)

    assert {:approval_pending, malformed} =
             EventReplay.to_agent_event(
               record(:approval_requested, %{
                 "tool_call_id" => "tc3",
                 "name" => "shell",
                 "args" => %{"command" => "mix test"},
                 "preview" => %{"kind" => "command", "summary" => "bad", "lines" => [:not_string]}
               })
             )

    assert malformed.tool_call_id == "tc3"
    refute Map.has_key?(malformed, :preview)
  end

  test "replay_active applies mapped durable events in storage order and skips ignored families" do
    updated =
      EventReplay.replay_active(editor_state(), [
        record(:session_started, %{}),
        record(:todo_plan_updated, %{
          "todos" => [
            %{"id" => "1", "description" => "Inspect files", "status" => "in_progress"}
          ]
        }),
        record(:file_edit_proposed, %{
          "path" => "/tmp/a.ex",
          "before_content" => "before",
          "after_content" => "after",
          "tool_call_id" => "tc2",
          "tool_name" => "edit"
        }),
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
        }),
        record(:driver_changed, %{})
      ])

    assert updated.workspace.agent_ui.view.activity.todos == [
             %TodoItem{id: "1", description: "Inspect files", status: :in_progress}
           ]

    assert [entry] =
             EditTimeline.entries_for(updated.workspace.agent_ui.view.edit_timeline, "/tmp/a.ex")

    assert entry.tool_call_id == "tc2"

    assert {:ok, "after"} =
             EditTimeline.content_at(
               updated.workspace.agent_ui.view.edit_timeline,
               "/tmp/a.ex",
               0
             )

    assert updated.workspace.agent_ui.view.preview.content == {:shell, "mix test", "ok", :done}
    assert updated.workspace.agent_ui.view.activity.active_action == "Thinking"
    assert TraditionalState.agent(updated.shell_runtime.state).runtime.active_tool_name == nil
  end

  @spec event_examples() :: [{MingaAgent.EventLog.EventRecord.event_type(), map(), term()}]
  defp event_examples do
    [
      {:session_started, %{}, nil},
      {:session_stopped, %{}, nil},
      {:user_disconnected, %{}, nil},
      {:user_message, %{"content" => "hello"}, nil},
      {:assistant_delta, %{"delta" => "hello"}, {:text_delta, "hello"}},
      {:thinking_delta, %{"delta" => "think"}, {:thinking_delta, "think"}},
      {:tool_call_started,
       %{"tool_call_id" => "tc1", "name" => "read_file", "args" => %{"path" => "lib/a.ex"}},
       {:tool_started, "tc1", "read_file", %{"path" => "lib/a.ex"}}},
      {:tool_call_updated,
       %{"tool_call_id" => "tc1", "name" => "shell", "partial_result" => "out"},
       {:tool_update, "tc1", "shell", "out"}},
      {:tool_call_finished,
       %{"tool_call_id" => "tc1", "name" => "read_file", "result" => "ok", "status" => "done"},
       {:tool_ended, "tc1", "read_file", "ok", :done}},
      {:tool_call_interrupted, %{"tool_call_id" => "tc2"}, {:tool_interrupted, "tc2"}},
      {:file_edit_proposed,
       %{
         "path" => "lib/a.ex",
         "before_content" => "old",
         "after_content" => "new",
         "tool_call_id" => "tc1",
         "tool_name" => "write_file"
       }, {:file_changed, "lib/a.ex", "old", "new", "tc1", "write_file"}},
      {:todo_plan_updated,
       %{"todos" => [%{"id" => "1", "description" => "Inspect files", "status" => "done"}]},
       {:todo_plan_updated, [%TodoItem{id: "1", description: "Inspect files", status: :done}]}},
      {:approval_requested,
       %{"tool_call_id" => "tc1", "name" => "shell", "args" => %{"command" => "mix test"}},
       {:approval_pending,
        %{tool_call_id: "tc1", name: "shell", args: %{"command" => "mix test"}}}},
      {:approval_resolved, %{"decision" => "approved"}, {:approval_resolved, :approved}},
      {:approval_interrupted, %{}, nil},
      {:system_message, %{"message" => "connected"}, nil},
      {:status_changed, %{status: :thinking}, {:status_changed, :thinking}},
      {:waiting_for_input, %{}, {:status_changed, :idle}},
      {:prompt_queued, %{"content" => "next", "queue" => "follow_up"},
       {:prompt_queued, "next", :follow_up}},
      {:message_changed, %{}, :messages_changed},
      {:error, %{"message" => "provider failed"}, {:error, "provider failed"}},
      {:context_usage, %{"estimated_tokens" => "12", "context_limit" => 100},
       {:context_usage, 12, 100}},
      {:turn_limit_reached, %{"current" => 3, "limit" => "5"}, {:turn_limit_reached, 3, 5}},
      {:driver_changed, %{}, nil}
    ]
  end

  @spec editor_state() :: EditorState.t()
  defp editor_state do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %WorkspaceState{viewport: Viewport.new(24, 80)}
    }
  end

  @spec record(MingaAgent.EventLog.EventRecord.event_type(), map()) :: EventRecord.t()
  defp record(event_type, payload), do: EventRecord.new("session", event_type, payload)
end
