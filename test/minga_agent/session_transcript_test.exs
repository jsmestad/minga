defmodule MingaAgent.SessionTranscriptTest do
  use Minga.Test.SessionCase, async: true

  describe "toggle_tool_collapse/2" do
    test "toggles collapsed state of tool call messages" do
      session = start_subscribed_session()

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      send(
        session,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "output"}}
      )

      # GenServer.call after send ensures all handle_info have run
      messages = Session.messages(session)

      tool_index =
        Enum.find_index(messages, fn
          {:tool_call, _} -> true
          _ -> false
        end)

      assert tool_index != nil

      {:tool_call, tc} = Enum.at(messages, tool_index)
      assert tc.collapsed == true

      :ok = Session.toggle_tool_collapse(session, tool_index)

      messages = Session.messages(session)
      {:tool_call, tc} = Enum.at(messages, tool_index)
      assert tc.collapsed == false
    end
  end

  describe "tool execution timing" do
    test "tool auto-expands on first ToolUpdate" do
      session = start_subscribed_session()

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      # Tool starts collapsed
      messages = Session.messages(session)
      {:tool_call, tc} = Enum.find(messages, &match?({:tool_call, _}, &1))
      assert tc.collapsed == true

      # ToolUpdate auto-expands
      send(
        session,
        {:agent_provider_event,
         %Event.ToolUpdate{tool_call_id: "tc1", name: "bash", partial_result: "line 1\n"}}
      )

      messages = Session.messages(session)
      {:tool_call, tc} = Enum.find(messages, &match?({:tool_call, _}, &1))
      assert tc.collapsed == false
      assert tc.result == "line 1\n"
    end

    test "tool re-collapses on ToolEnd with duration" do
      session = start_subscribed_session()

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      send(
        session,
        {:agent_provider_event, %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "done"}}
      )

      messages = Session.messages(session)
      {:tool_call, tc} = Enum.find(messages, &match?({:tool_call, _}, &1))
      assert tc.collapsed == true
      assert tc.status == :complete
      assert is_integer(tc.duration_ms)
      assert tc.duration_ms >= 0
    end
  end

  describe "ToolFileChanged event" do
    test "broadcasts file_changed with before/after content" do
      session = start_subscribed_session()

      event = %Event.ToolFileChanged{
        tool_call_id: "tc1",
        path: "lib/foo.ex",
        before_content: "old content",
        after_content: "new content"
      }

      send(session, {:agent_provider_event, event})

      assert_receive {:agent_event, _,
                      {:file_changed, "lib/foo.ex", "old content", "new content", "tc1",
                       _tool_name}},
                     200
    end

    test "captures file diff preview on the matching tool call" do
      session = start_subscribed_session()

      send(
        session,
        {:agent_provider_event,
         %Event.ToolStart{
           tool_call_id: "tc1",
           name: "write_file",
           args: %{"path" => "lib/foo.ex", "content" => "new content"}
         }}
      )

      send(
        session,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tc1", name: "write_file", result: "wrote file"}}
      )

      send(
        session,
        {:agent_provider_event,
         %Event.ToolFileChanged{
           tool_call_id: "tc1",
           path: "lib/foo.ex",
           before_content: "old content",
           after_content: "new content"
         }}
      )

      :sys.get_state(session)

      assert_receive {:agent_event, _,
                      {:file_changed, "lib/foo.ex", "old content", "new content", "tc1",
                       _tool_name}},
                     200

      tool_call =
        Session.messages(session)
        |> Enum.find_value(fn
          {:tool_call, tool_call} -> tool_call
          _ -> nil
        end)

      assert tool_call.preview.kind == :diff
      assert tool_call.preview.summary == "lib/foo.ex"
      assert "file: lib/foo.ex" in tool_call.preview.lines
      assert "-old content" in tool_call.preview.lines
      assert "+new content" in tool_call.preview.lines
    end
  end

  describe "thinking block collapse" do
    test "thinking blocks stay expanded during streaming and collapse on AgentEnd" do
      session = start_subscribed_session()
      send(session, {:agent_provider_event, %Event.AgentStart{}})
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: "Let me think..."}})

      # While thinking, the block should be expanded
      messages = Session.messages(session)

      thinking =
        Enum.find(messages, fn
          {:thinking, _, _} -> true
          _ -> false
        end)

      assert {:thinking, _, false} = thinking

      # TextDelta arrives: thinking should remain expanded during the turn
      send(session, {:agent_provider_event, %Event.TextDelta{delta: "Here is my answer"}})

      messages = Session.messages(session)

      thinking =
        Enum.find(messages, fn
          {:thinking, _, _} -> true
          _ -> false
        end)

      assert {:thinking, _, false} = thinking

      # AgentEnd: thinking collapses now that the turn is complete
      send(session, {:agent_provider_event, %Event.AgentEnd{usage: nil}})

      messages = Session.messages(session)

      thinking =
        Enum.find(messages, fn
          {:thinking, _, _} -> true
          _ -> false
        end)

      assert {:thinking, _, true} = thinking
    end

    test "toggle_all_tool_collapses also toggles thinking blocks" do
      session = start_subscribed_session()
      send(session, {:agent_provider_event, %Event.AgentStart{}})
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: "hmm"}})
      send(session, {:agent_provider_event, %Event.TextDelta{delta: "answer"}})

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      send(
        session,
        {:agent_provider_event, %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "ok"}}
      )

      # End the turn so thinking blocks collapse
      send(session, {:agent_provider_event, %Event.AgentEnd{usage: nil}})

      # Both should be collapsed
      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:thinking, _, true}, &1))
      assert Enum.any?(messages, &match?({:tool_call, %{collapsed: true}}, &1))

      # Toggle all should expand both
      :ok = Session.toggle_all_tool_collapses(session)

      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:thinking, _, false}, &1))
      assert Enum.any?(messages, &match?({:tool_call, %{collapsed: false}}, &1))
    end
  end

  describe "message IDs" do
    @tag :tmp_dir
    test "IDs increment across turns and reset for new or loaded sessions", %{tmp_dir: dir} do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          session_store_dir: dir
        )

      Session.subscribe(session)
      assert [{1, {:system, _, :info}}] = Session.messages_with_ids(session)

      :ok = Session.send_prompt(session, "first")
      await_turn_complete()
      pairs_after_first = Session.messages_with_ids(session)
      assert Enum.map(pairs_after_first, &elem(&1, 0)) == [1, 2, 3, 4]

      :ok = Session.send_prompt(session, "second")
      await_turn_complete()
      pairs_after_second = Session.messages_with_ids(session)
      ids_after_second = Enum.map(pairs_after_second, &elem(&1, 0))
      assert ids_after_second == Enum.sort(ids_after_second)
      assert ids_after_second == Enum.uniq(ids_after_second)
      assert length(pairs_after_second) == length(Session.messages(session))

      :ok = Session.new_session(session)
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
      assert [{1, {:system, _, :info}}] = Session.messages_with_ids(session)

      loaded_id = "id-test-session-#{System.unique_integer([:positive])}"

      SessionStore.save(
        %{
          id: loaded_id,
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          model_name: "test-model",
          messages: [{:user, "loaded"}, {:assistant, "reply"}],
          usage: %MingaAgent.TurnUsage{
            input: 10,
            output: 5,
            cache_read: 0,
            cache_write: 0,
            cost: 0.001
          }
        },
        dir
      )

      :ok = Session.load_session(session, loaded_id)
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      assert [{1, {:user, "loaded"}}, {2, {:assistant, "reply"}}] =
               Session.messages_with_ids(session)
    end

    test "streaming text deltas keep one assistant ID" do
      slow_session = start_slow_turn("hello")

      pairs_during = Session.messages_with_ids(slow_session)
      assert Enum.map(pairs_during, &elem(&1, 0)) == [1, 2, 3]

      send(slow_session, {:agent_provider_event, %Event.TextDelta{delta: " world"}})

      pairs_after_delta = Session.messages_with_ids(slow_session)
      assert Enum.map(pairs_after_delta, &elem(&1, 0)) == [1, 2, 3]
      assert {3, {:assistant, text}} = Enum.at(pairs_after_delta, -1)
      assert String.contains?(text, "world")

      finish_slow_turn(slow_session)

      pairs_final = Session.messages_with_ids(slow_session)
      assert Enum.map(pairs_final, &elem(&1, 0)) == [1, 2, 3, 4]
      assert length(pairs_final) == length(Session.messages(slow_session))
    end

    test "thinking deltas get one stable ID, then assistant gets the next" do
      session = start_subscribed_session()
      send(session, {:agent_provider_event, %Event.AgentStart{}})
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: "hmm"}})
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: " ok"}})

      pairs_thinking = Session.messages_with_ids(session)
      assert Enum.map(pairs_thinking, &elem(&1, 0)) == [1, 2]
      assert {2, {:thinking, "hmm ok", _collapsed}} = Enum.at(pairs_thinking, -1)

      send(session, {:agent_provider_event, %Event.TextDelta{delta: "answer"}})
      pairs_with_assistant = Session.messages_with_ids(session)

      assert Enum.map(pairs_with_assistant, &elem(&1, 0)) == [1, 2, 3]
      assert {3, {:assistant, "answer"}} = Enum.at(pairs_with_assistant, -1)
      assert length(pairs_with_assistant) == length(Session.messages(session))
    end

    test "tool updates keep a stable tool message ID" do
      session = start_subscribed_session()

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      pairs_start = Session.messages_with_ids(session)
      {tool_id, {:tool_call, tc_start}} = Enum.at(pairs_start, -1)
      assert tc_start.status == :running

      send(
        session,
        {:agent_provider_event,
         %Event.ToolUpdate{tool_call_id: "tc1", name: "bash", partial_result: "output"}}
      )

      pairs_update = Session.messages_with_ids(session)
      assert {^tool_id, {:tool_call, %{result: "output"}}} = Enum.at(pairs_update, -1)

      send(
        session,
        {:agent_provider_event, %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "done"}}
      )

      pairs_end = Session.messages_with_ids(session)
      assert {^tool_id, {:tool_call, %{status: :complete}}} = Enum.at(pairs_end, -1)
      assert length(pairs_end) == length(Session.messages(session))
    end

    test "message mutations preserve existing IDs" do
      session = start_subscribed_session()
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: "thinking..."}})

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      send(
        session,
        {:agent_provider_event, %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "ok"}}
      )

      pairs_before = Session.messages_with_ids(session)
      ids_before = Enum.map(pairs_before, &elem(&1, 0))

      tool_index =
        Enum.find_index(pairs_before, fn {_id, msg} -> match?({:tool_call, _}, msg) end)

      :ok = Session.toggle_tool_collapse(session, tool_index)
      assert Enum.map(Session.messages_with_ids(session), &elem(&1, 0)) == ids_before

      :ok = Session.toggle_all_tool_collapses(session)
      assert Enum.map(Session.messages_with_ids(session), &elem(&1, 0)) == ids_before

      :ok = Session.abort(session)
      ids_after_abort = Session.messages_with_ids(session) |> Enum.map(&elem(&1, 0))
      assert Enum.take(ids_after_abort, length(ids_before)) == ids_before
      assert length(ids_after_abort) == length(ids_before) + 1
      assert length(Session.messages_with_ids(session)) == length(Session.messages(session))
    end

    test "dequeue_steering and system messages assign later IDs" do
      session = start_subscribed_session()
      slow_session = start_slow_turn()
      assert {:queued, :steering} = Session.send_prompt(slow_session, "steer 1")
      assert {:queued, :steering} = Session.send_prompt(slow_session, "steer 2")

      _steering = Session.dequeue_steering(slow_session)
      pairs = Session.messages_with_ids(slow_session)
      ids = Enum.map(pairs, &elem(&1, 0))
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
      assert length(pairs) == length(Session.messages(slow_session))

      Session.clear_queues(slow_session)
      finish_slow_turn(slow_session)

      pairs_before = Session.messages_with_ids(session)
      max_id_before = pairs_before |> Enum.map(&elem(&1, 0)) |> Enum.max()

      Session.add_system_message(session, "hello from test")
      pairs_after = Session.messages_with_ids(session)
      ids_after = Enum.map(pairs_after, &elem(&1, 0))

      assert length(ids_after) == length(pairs_before) + 1
      assert Enum.at(ids_after, -1) > max_id_before
      assert length(pairs_after) == length(Session.messages(session))
    end
  end
end
