defmodule MingaEditor.Remote.EventReplayTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Taxonomy
  alias MingaAgent.TodoItem
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.Tool.Output
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaAgent.Tool.Output.Codec, as: OutputCodec
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference

  test "tool completion replay carries typed retained output facts" do
    {:ok, range} = Range.new(:full, :bytes, 0, 2, 2)
    {:ok, output} = Output.new("ok", :complete, range)

    assert {:tool_ended,
            %MingaAgent.Event.ToolEnd{
              tool_call_id: "tc-output",
              name: "read_file",
              result: "ok",
              outcome: :complete,
              output: ^output
            }} =
             EventReplay.to_agent_event(
               record(:tool_call_finished, %{
                 "tool_call_id" => "tc-output",
                 "name" => "read_file",
                 "result" => "ok",
                 "status" => "done",
                 "output" => OutputCodec.encode(output)
               })
             )
  end

  test "replay preserves explicit terminal outcomes and approval expiry without text inference" do
    for {encoded, outcome, encoded_reason, reason} <- [
          {"complete", :complete, nil, nil},
          {"denied", :denied, nil, nil},
          {"cancelled", :cancelled, nil, nil},
          {"error", :error, nil, nil},
          {"error", :error, "approval_timeout", :approval_timeout}
        ] do
      assert {:tool_ended, %MingaAgent.Event.ToolEnd{outcome: ^outcome, reason: ^reason} = event} =
               EventReplay.to_agent_event(
                 record(:tool_call_finished, %{
                   "tool_call_id" => "replayed",
                   "name" => "shell",
                   "result" => "The original explanation",
                   "status" => encoded,
                   "reason" => encoded_reason
                 })
               )

      assert event.result == "The original explanation"
      assert event.is_error == (outcome != :complete)
    end
  end

  test "invalid retained output reports replay failure instead of an output-free completion" do
    assert {:error, message} =
             EventReplay.to_agent_event(
               record(:tool_call_finished, %{
                 "tool_call_id" => "corrupt-output",
                 "name" => "shell",
                 "result" => "original text",
                 "status" => "complete",
                 "output" => %{"invalid" => true}
               })
             )

    assert message =~ "could not be replayed"
  end

  test "canonical conversion contract covers every persisted event family" do
    expected_events =
      Enum.map(event_examples(), fn {event_type, payload, expected} ->
        assert EventReplay.to_agent_event(record(event_type, payload)) == expected
        event_type
      end)

    assert MapSet.new(expected_events) == MapSet.new(Taxonomy.events())
  end

  test "canonical conversion normalizes malformed replay payloads without crashing" do
    assert {:error, message} =
             EventReplay.to_agent_event(
               record(:tool_call_finished, %{
                 "tool_call_id" => "tc1",
                 "name" => "shell",
                 "result" => "failed",
                 "status" => "failed"
               })
             )

    assert message =~ "invalid_tool_outcome"

    assert EventReplay.to_agent_event(record(:status_changed, %{"status" => "not_existing"})) ==
             {:status_changed, :unknown}

    assert EventReplay.to_agent_event(
             record(:context_usage, %{"estimated_tokens" => "bad", "context_limit" => nil})
           ) == {:context_usage, 0, 0, nil, :unknown}

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

  test "todo replay skips only the row with an invalid result reference" do
    {:ok, token} = Reference.token("session", String.duplicate("a", 32))

    {:ok, reference} =
      Reference.new(
        token: token,
        media_type: "text/plain",
        bytes: 2,
        sha256: Reference.digest("ok")
      )

    record =
      record(:todo_plan_updated, %{
        "todos" => [
          %{id: 1, description: "Inspect files", status: :unknown},
          %{"id" => "2", "description" => "Broken output", "result_ref" => %{"token" => "bad"}},
          %{
            "id" => "3",
            "description" => "Run build",
            "status" => "done",
            "note" => "Build passed",
            "result_ref" => OutputCodec.encode_reference(reference)
          }
        ]
      })

    assert EventReplay.to_agent_event(record) ==
             {:todo_plan_updated,
              [
                %TodoItem{id: "1", description: "Inspect files", status: :pending},
                %TodoItem{
                  id: "3",
                  description: "Run build",
                  status: :done,
                  note: "Build passed",
                  result_ref: reference
                }
              ]}
  end

  test "durable approval previews cannot recreate live controls, even when complete" do
    previews = [
      %{"kind" => "command", "summary" => "mix test", "lines" => ["$ mix test", "cwd: /tmp"]},
      %{"kind" => "diff", "summary" => "lib/a.ex", "lines" => ["-old", "+new"]},
      %{"kind" => "target", "summary" => "lib/a.ex", "lines" => ["lib/a.ex"]},
      %{"kind" => "args", "summary" => "custom tool", "lines" => []},
      %{"kind" => "nope", "summary" => "bad", "lines" => ["x"]},
      %{"kind" => "command", "summary" => "bad", "lines" => [:not_string]},
      %{"kind" => "command", "summary" => 12, "lines" => ["x"]},
      %{"kind" => "command", "summary" => "incomplete"},
      nil
    ]

    for preview <- previews do
      # This legacy Session payload has a tool ID, but no admitted request ID.
      payload = %{
        "approval_id" => "tc1",
        "tool_call_id" => "tc1",
        "name" => "shell",
        "args" => %{"command" => "mix test"},
        "preview" => preview
      }

      assert EventReplay.to_agent_event(record(:approval_requested, payload)) == nil

      assert EventReplay.replay_active(editor_state(), self(), [
               record(:approval_requested, payload)
             ]) ==
               editor_state()
    end
  end

  test "approval history cannot install or resolve a live snapshot attachment" do
    source = self()
    target = ApprovalTarget.new("session", "current-admitted-request", "reused-tool-id")
    preview = Preview.new(:command, "echo current", ["echo current"])
    approval = PublicApproval.new(target, "shell", %{"command" => "echo current"}, preview)
    binding = PendingApproval.new(source, approval)
    agent = AgentState.set_pending_approval(%AgentState{}, binding)

    state = %{
      editor_state()
      | shell_runtime:
          Runtime.new(
            Runtime.default_entry(),
            TraditionalState.replace_agent(%TraditionalState{}, agent)
          )
    }

    public_payload = approval |> JSON.encode!() |> JSON.decode!()

    stale_payload =
      Map.put(public_payload, "target", %{
        "session_id" => "session",
        "request_id" => "old-admitted-request",
        "tool_call_id" => "reused-tool-id"
      })

    legacy_payload = %{
      "approval_id" => "reused-tool-id",
      "tool_call_id" => "reused-tool-id",
      "name" => "shell",
      "args" => %{"command" => "echo historical"},
      "preview" => %{"kind" => "command", "summary" => "echo historical", "lines" => []}
    }

    records = [
      record(:approval_requested, legacy_payload),
      record(:approval_requested, stale_payload),
      record(:approval_requested, public_payload),
      record(:approval_requested, %{"target" => %{"tool_call_id" => "reused-tool-id"}}),
      record(:approval_resolved, %{
        "approval_id" => "reused-tool-id",
        "tool_call_id" => "reused-tool-id",
        "name" => "shell",
        "decision" => "approve"
      }),
      record(:approval_resolved, %{"target" => public_payload["target"], "decision" => "reject"})
    ]

    # Durable history is not a live Session event and cannot replace the snapshot attachment.
    assert EventReplay.replay_active(state, source, records) == state

    # Nor may replay fill missing identities from an editor's active state.
    assert EventReplay.replay_active(editor_state(), source, records) == editor_state()
  end

  test "replay_active applies mapped durable events in storage order and skips ignored families" do
    updated =
      EventReplay.replay_active(editor_state(), self(), [
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
        record(:approval_requested, %{
          "approval_id" => "tc1",
          "tool_call_id" => "tc1",
          "name" => "shell",
          "args" => %{"command" => "mix test"},
          "preview" => %{"kind" => "command", "summary" => "mix test", "lines" => ["mix test"]}
        }),
        record(:approval_resolved, %{
          "approval_id" => "tc1",
          "tool_call_id" => "tc1",
          "name" => "shell",
          "decision" => "approve"
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
       {:tool_ended,
        %MingaAgent.Event.ToolEnd{
          tool_call_id: "tc1",
          name: "read_file",
          result: "ok",
          outcome: :complete
        }}},
      {:tool_call_interrupted, %{"tool_call_id" => "tc2"}, {:tool_interrupted, "tc2"}},
      {:file_edit_proposed,
       %{
         "path" => "lib/a.ex",
         "before_content" => "old",
         "after_content" => "new",
         "tool_call_id" => "tc1",
         "tool_name" => "write_file"
       }, {:file_changed, "lib/a.ex", "old", "new", "tc1", "write_file"}},
      {:file_edit_proposed,
       %{
         "path" => "lib/gone.ex",
         "before_content" => "absent",
         "before_exists" => true,
         "after_content" => "",
         "after_exists" => false,
         "tool_call_id" => "tc2",
         "tool_name" => "delete_file"
       }, {:file_changed, "lib/gone.ex", "absent", :absent, "tc2", "delete_file"}},
      {:todo_plan_updated,
       %{"todos" => [%{"id" => "1", "description" => "Inspect files", "status" => "done"}]},
       {:todo_plan_updated, [%TodoItem{id: "1", description: "Inspect files", status: :done}]}},
      {:approval_requested,
       %{
         "approval_id" => "tc1",
         "tool_call_id" => "tc1",
         "name" => "shell",
         "args" => %{"command" => "mix test"}
       }, nil},
      {:approval_resolved,
       %{
         "approval_id" => "tc1",
         "tool_call_id" => "tc1",
         "name" => "shell",
         "decision" => "approve"
       }, nil},
      {:approval_interrupted, %{}, nil},
      {:question_requested, %{"tool_call_id" => "q1", "prompt" => "Which output?"}, nil},
      {:question_answered, %{"tool_call_id" => "q1"}, nil},
      {:question_cancelled, %{"tool_call_id" => "q1"}, nil},
      {:question_interrupted, %{"tool_call_id" => "q1"}, nil},
      {:system_message, %{"message" => "connected"}, nil},
      {:status_changed, %{status: :thinking}, {:status_changed, :thinking}},
      {:waiting_for_input, %{}, {:status_changed, :idle}},
      {:prompt_queued, %{"content" => "next", "queue" => "follow_up"},
       {:prompt_queued, "next", :follow_up}},
      {:message_changed, %{}, :messages_changed},
      {:error, %{"message" => "provider failed"}, {:error, "provider failed"}},
      {:context_usage, %{"estimated_tokens" => "12", "context_limit" => 100},
       {:context_usage, 12, 100, nil, :unknown}},
      {:turn_limit_reached, %{"current" => 3, "limit" => "5"}, {:turn_limit_reached, 3, 5}},
      {:driver_changed, %{}, nil}
    ]
  end

  @spec editor_state() :: EditorState.t()
  defp editor_state do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %WorkspaceState{}
    }
  end

  @spec record(MingaAgent.EventLog.EventRecord.event_type(), map()) :: EventRecord.t()
  defp record(event_type, payload), do: EventRecord.new("session", event_type, payload)
end
