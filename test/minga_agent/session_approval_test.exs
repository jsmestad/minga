defmodule MingaAgent.SessionApprovalTest do
  use Minga.Test.SessionCase, async: true

  describe "tool approval" do
    test "ToolApproval event stores pending approval and broadcasts" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)

      approval = %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "shell",
        args: %{"command" => "rm -rf /"},
        reply_to: self()
      }

      send_provider_event(session, approval)

      # Broadcast should arrive
      assert_receive {:agent_event, _, {:approval_pending, data}}, @event_timeout
      assert data.name == "shell"
      assert data.tool_call_id == "tc1"
      assert data.preview.kind == :command
      assert data.preview.summary == "rm -rf /"
      refute Map.has_key?(data, :reply_to)
    end

    test "stale approval requests cannot reactivate an idle session" do
      session = start_subscribed_session()

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc-stale",
        name: "shell",
        args: %{"command" => "pwd"},
        reply_to: self()
      })

      assert_receive {:tool_approval_response, "tc-stale", :reject}, @event_timeout
      assert :ok = Session.set_tool_trust(session, "shell", :session)

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc-trusted-stale",
        name: "shell",
        args: %{"command" => "pwd"},
        reply_to: self()
      })

      assert_receive {:tool_approval_response, "tc-trusted-stale", :reject}, @event_timeout
      refute_received {:agent_event, _, {:tool_auto_approved, "tc-trusted-stale", _, _}}
      assert Session.status(session) == :idle
      assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)
    end

    test "respond_to_approval resolves each supported decision" do
      for {decision, execution_decision} <- [
            {:approve, :approve},
            {:approve_session, :approve},
            {:approve_turn, :approve},
            {:reject, :reject}
          ] do
        session = start_subscribed_session()
        send_approval(session)

        assert :ok = Session.respond_to_approval(session, decision)
        assert_receive {:tool_approval_response, "tc1", ^execution_decision}, @event_timeout
        assert_receive {:agent_event, _, {:approval_resolved, ^decision}}, @event_timeout
        assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)

        if decision == :reject do
          messages = Session.messages(session)
          assert Enum.any?(messages, &match?({:system, "Denied shell" <> _, :info}, &1))
        end
      end
    end

    test "remote driver can resolve a pending approval by stable id" do
      session = start_subscribed_session()
      driver = self()
      assert :ok = Session.subscribe(session, driver, role: :driver)
      send_approval(session)

      assert {:error, :approval_not_found} =
               Session.respond_to_approval_as(session, driver, "other-tc", :approve)

      assert :ok = Session.respond_to_approval_as(session, driver, "tc1", :approve)
      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
      assert_receive {:agent_event, _, {:approval_resolved, :approve}}, @event_timeout
    end

    test "approve_session and approve_turn set the matching tool trust scope" do
      session = start_subscribed_session()
      send_approval(session)
      assert :ok = Session.respond_to_approval(session, :approve_session)
      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
      assert Session.list_tool_trust(session) == %{"shell:rm -rf /" => :session}

      session = start_subscribed_session()
      send_approval(session)
      assert :ok = Session.respond_to_approval(session, :approve_turn)
      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
      assert Session.list_tool_trust(session) == %{"shell:rm -rf /" => :turn}
    end

    test "approval session trust for shell is scoped to the approved command" do
      session = start_subscribed_session()
      send_approval(session)
      assert :ok = Session.respond_to_approval(session, :approve_session)
      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc_same",
        name: "shell",
        args: %{"command" => "rm -rf /"},
        reply_to: self()
      })

      assert_receive {:tool_approval_response, "tc_same", :approve}, @event_timeout

      assert_receive {:agent_event, _, {:tool_auto_approved, "tc_same", "shell", :session}},
                     @event_timeout

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc_other",
        name: "shell",
        args: %{"command" => "pwd"},
        reply_to: self()
      })

      assert_receive {:agent_event, _, {:approval_pending, pending}}, @event_timeout
      assert pending.tool_call_id == "tc_other"
      refute_received {:tool_approval_response, "tc_other", :approve}
    end

    test "approval session trust for MCP tools is scoped to the approved arguments" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc_mcp",
        name: "mcp_files__delete",
        args: %{"path" => "tmp/a.txt"},
        reply_to: self()
      })

      assert_receive {:agent_event, _, {:approval_pending, _}}, @event_timeout
      assert :ok = Session.respond_to_approval(session, :approve_session)
      assert_receive {:tool_approval_response, "tc_mcp", :approve}, @event_timeout

      trust = Session.list_tool_trust(session)
      assert [key] = Map.keys(trust)
      assert key =~ ~r/^mcp_files__delete:[0-9a-f]{64}$/
      assert trust[key] == :session

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc_mcp_same",
        name: "mcp_files__delete",
        args: %{"path" => "tmp/a.txt"},
        reply_to: self()
      })

      assert_receive {:tool_approval_response, "tc_mcp_same", :approve}, @event_timeout

      assert_receive {:agent_event, _,
                      {:tool_auto_approved, "tc_mcp_same", "mcp_files__delete", :session}},
                     @event_timeout

      refute_received {:agent_event, _, {:approval_pending, _}}

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc_mcp_other",
        name: "mcp_files__delete",
        args: %{"path" => "tmp/b.txt"},
        reply_to: self()
      })

      assert_receive {:agent_event, _, {:approval_pending, pending}}, @event_timeout
      assert pending.tool_call_id == "tc_mcp_other"
      refute_received {:tool_approval_response, "tc_mcp_other", :approve}
    end

    test "bare approve sets no tool trust" do
      session = start_subscribed_session()
      send_approval(session)
      assert :ok = Session.respond_to_approval(session, :approve)
      assert_receive {:tool_approval_response, "tc1", :approve}, @event_timeout
      assert Session.list_tool_trust(session) == %{}
    end

    test "trusted tool approvals are auto-approved without pending approval" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)
      assert :ok = Session.set_tool_trust(session, "shell", :session)

      approval = %Event.ToolApproval{
        tool_call_id: "tc_auto",
        name: "shell",
        args: %{"command" => "pwd"},
        reply_to: self()
      }

      send_provider_event(session, approval)

      assert_receive {:tool_approval_response, "tc_auto", :approve}, @event_timeout

      assert_receive {:agent_event, _, {:tool_auto_approved, "tc_auto", "shell", :session}},
                     @event_timeout

      refute_received {:agent_event, _, {:tool_auto_approved, "tc_auto", "shell", :session}}

      refute_received {:agent_event, _, {:approval_pending, _}}
      assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)
    end

    test "trusted approval remains safe while another approval is pending" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)
      assert :ok = Session.set_tool_trust(session, "shell", :session)

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc_pending",
        name: "read_file",
        args: %{"path" => "README.md"},
        reply_to: self()
      })

      assert_receive {:agent_event, _, {:approval_pending, %{tool_call_id: "tc_pending"}}},
                     @event_timeout

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc_auto",
        name: "shell",
        args: %{"command" => "pwd"},
        reply_to: self()
      })

      assert_receive {:tool_approval_response, "tc_auto", :approve}, @event_timeout

      assert_receive {:agent_event, _, {:tool_auto_approved, "tc_auto", "shell", :session}},
                     @event_timeout

      assert :ok = Session.respond_to_approval(session, :reject)
      assert_receive {:tool_approval_response, "tc_pending", :reject}, @event_timeout
    end

    test "auto-approved scope survives active updates and completion" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)
      assert :ok = Session.set_tool_trust(session, "shell", :turn)

      approval = %Event.ToolApproval{
        tool_call_id: "tc_auto",
        name: "shell",
        args: %{"command" => "pwd"},
        reply_to: self()
      }

      send_provider_event(session, approval)
      assert_receive {:tool_approval_response, "tc_auto", :approve}, @event_timeout

      send_provider_event(session, %Event.ToolStart{
        tool_call_id: "tc_auto",
        name: "shell",
        args: %{"command" => "pwd"}
      })

      assert {:tool_call, %{auto_approved_scope: :turn}} =
               Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

      send_provider_event(session, %Event.ToolUpdate{
        tool_call_id: "tc_auto",
        name: "shell",
        partial_result: "out"
      })

      assert {:tool_call, %{auto_approved_scope: :turn, result: "out"}} =
               Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

      send_provider_event(session, %Event.ToolEnd{
        tool_call_id: "tc_auto",
        name: "shell",
        result: "done",
        is_error: false
      })

      assert {:tool_call, %{auto_approved_scope: :turn, result: "done"}} =
               Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))
    end

    test "turn trust clears when the session returns to idle while session trust persists" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)
      assert :ok = Session.set_tool_trust(session, "shell", :turn)
      assert :ok = Session.set_tool_trust(session, "read_file", :session)

      send_provider_event(session, %Event.AgentStart{})
      send_provider_event(session, %Event.AgentEnd{})

      assert Session.list_tool_trust(session) == %{"read_file" => :session}
    end

    @tag :tmp_dir
    test "turn trust clears before automatically queued follow-up turns", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "file contents")
      call_count = :counters.new(1, [:atomics])

      client = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                  id: "tc_1",
                  index: 0
                }),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            1 ->
              [
                ReqLLM.StreamChunk.text("first turn done"),
                ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
              ]

            2 ->
              [
                ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                  id: "tc_2",
                  index: 0
                }),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _ ->
              [
                ReqLLM.StreamChunk.text("follow-up done"),
                ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
              ]
          end

        build_stream_response(chunks)
      end

      tools = MingaAgent.Tools.all(project_root: dir)

      session =
        start_subscribed_session(Native,
          project_root: dir,
          llm_client: client,
          tools: tools,
          config: agent_config(tool_approval: :all),
          skip_api_key_env: true
        )

      assert :ok = Session.set_tool_trust(session, "read_file", :turn)
      assert :ok = Session.send_prompt(session, "Read test.txt")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "next turn")

      assert_receive {:agent_event, _, {:tool_auto_approved, _, "read_file", :turn}},
                     @event_timeout

      assert_receive {:agent_event, _, {:approval_pending, pending}}, @event_timeout
      assert pending.name == "read_file"
      assert Session.list_tool_trust(session) == %{}

      assert :ok = Session.respond_to_approval(session, :approve)
      assert_receive {:agent_event, _, {:tool_started, "read_file", _}}, @event_timeout
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "turn trust clears on errors" do
      session = start_subscribed_session()
      assert :ok = Session.set_tool_trust(session, "shell", :turn)

      send_provider_event(session, %Event.Error{message: "boom"})

      assert Session.list_tool_trust(session) == %{}
    end

    test "duplicate provider errors are not appended twice" do
      session = start_subscribed_session()

      send_provider_event(session, %Event.Error{message: "boom"})
      send_provider_event(session, %Event.Error{message: "boom"})

      errors =
        Session.messages(session)
        |> Enum.filter(&match?({:system, "boom", :error}, &1))

      assert Enum.count(errors) == 1
    end

    test "revoke_tool_trust removes one or all entries" do
      session = start_subscribed_session()
      assert :ok = Session.set_tool_trust(session, "shell", :session)
      assert :ok = Session.set_tool_trust(session, "read_file", :turn)

      assert :ok = Session.revoke_tool_trust(session, "shell")
      assert Session.list_tool_trust(session) == %{"read_file" => :turn}

      assert :ok = Session.revoke_tool_trust(session, :all)
      assert Session.list_tool_trust(session) == %{}
    end

    test "new_session clears session trust" do
      session = start_subscribed_session()
      assert :ok = Session.set_tool_trust(session, "shell", :session)

      assert :ok = Session.new_session(session)

      assert Session.list_tool_trust(session) == %{}
    end

    test "respond_to_approval with no pending returns error" do
      session = start_subscribed_session()
      assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)
    end

    test "abort clears pending approval" do
      session = start_subscribed_session()
      send_approval(session)

      :ok = Session.abort(session)

      assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)
    end
  end
end
