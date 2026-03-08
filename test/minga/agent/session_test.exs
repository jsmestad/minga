defmodule Minga.Agent.SessionTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Event
  alias Minga.Agent.Session
  alias Minga.Agent.SessionStore

  # ── Mock provider ──────────────────────────────────────────────────────────

  defmodule MockProvider do
    @behaviour Minga.Agent.Provider

    use GenServer

    @impl Minga.Agent.Provider
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl Minga.Agent.Provider
    def send_prompt(pid, text) do
      GenServer.cast(pid, {:prompt, text})
      :ok
    end

    @impl Minga.Agent.Provider
    def abort(pid) do
      GenServer.cast(pid, :abort)
      :ok
    end

    @impl Minga.Agent.Provider
    def new_session(pid) do
      GenServer.cast(pid, :new_session)
      :ok
    end

    @impl Minga.Agent.Provider
    def get_state(_pid) do
      {:ok, %{model: nil, is_streaming: false, token_usage: nil}}
    end

    @impl GenServer
    def init(opts) do
      subscriber = Keyword.fetch!(opts, :subscriber)
      {:ok, %{subscriber: subscriber}}
    end

    @impl GenServer
    def handle_cast({:prompt, _text}, state) do
      # Simulate: agent_start → text_delta → agent_end
      send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})

      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: "Hello "}})
      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: "world!"}})

      usage = %{input: 100, output: 50, cache_read: 0, cache_write: 0, cost: 0.01}
      send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{usage: usage}})

      {:noreply, state}
    end

    def handle_cast(:abort, state), do: {:noreply, state}
    def handle_cast(:new_session, state), do: {:noreply, state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Waits for all provider events to be processed by the session after
  # send_prompt. The session broadcasts {:status_changed, :idle} as its
  # final action when a turn completes, so receiving that event guarantees
  # all handle_info callbacks have run.
  defp await_turn_complete do
    assert_receive {:agent_event, {:status_changed, :idle}}, 200
  end

  # ── Tests ───────────────────────────────────────────────────────────────────

  setup do
    {:ok, session} =
      Session.start_link(
        provider: MockProvider,
        provider_opts: []
      )

    Session.subscribe(session)

    %{session: session}
  end

  describe "initial state" do
    test "starts with idle status", %{session: session} do
      assert Session.status(session) == :idle
    end

    test "starts with a session-started system message", %{session: session} do
      messages = Session.messages(session)
      assert [{:system, text, :info}] = messages
      assert String.starts_with?(text, "Session started")
    end

    test "starts with zero usage", %{session: session} do
      usage = Session.usage(session)
      assert usage.input == 0
      assert usage.output == 0
      assert usage.cost == 0.0
    end
  end

  describe "send_prompt/2" do
    test "adds user message and streams response", %{session: session} do
      :ok = Session.send_prompt(session, "Hello!")
      await_turn_complete()

      messages = Session.messages(session)

      # Should have system message + user message + assistant message + usage
      assert length(messages) >= 3
      assert {:system, _, :info} = Enum.at(messages, 0)
      assert {:user, "Hello!"} = Enum.at(messages, 1)
      assert {:assistant, "Hello world!"} = Enum.at(messages, 2)
    end

    test "accumulates token usage", %{session: session} do
      :ok = Session.send_prompt(session, "Test")
      await_turn_complete()

      usage = Session.usage(session)
      assert usage.input == 100
      assert usage.output == 50
      assert usage.cost == 0.01
    end

    test "broadcasts status changes", %{session: session} do
      :ok = Session.send_prompt(session, "Test")

      assert_receive {:agent_event, {:status_changed, :thinking}}, 200
      assert_receive {:agent_event, {:status_changed, :idle}}, 200
    end

    test "broadcasts text deltas", %{session: session} do
      :ok = Session.send_prompt(session, "Test")

      assert_receive {:agent_event, {:text_delta, "Hello "}}, 200
      assert_receive {:agent_event, {:text_delta, "world!"}}, 200
    end
  end

  describe "per-turn usage" do
    test "appends usage message after AgentEnd", %{session: session} do
      :ok = Session.send_prompt(session, "Test")
      await_turn_complete()

      messages = Session.messages(session)

      usage_msg =
        Enum.find(messages, fn
          {:usage, _} -> true
          _ -> false
        end)

      assert {:usage, %{input: 100, output: 50, cost: 0.01}} = usage_msg
    end
  end

  describe "abort/1" do
    test "preserves partial response and adds system message", %{session: session} do
      :ok = Session.send_prompt(session, "Test")
      await_turn_complete()

      # Verify we have an assistant message
      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:assistant, _}, &1))

      :ok = Session.abort(session)

      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:assistant, _}, &1))
      assert Enum.any?(messages, &match?({:system, "Aborted", :info}, &1))
      assert Session.status(session) == :idle
    end

    test "marks running tool calls as aborted", %{session: session} do
      # Direct event injection: send + call is sufficient for sync
      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      # Session.messages is a call, so it's processed after the send above
      _ = Session.messages(session)

      :ok = Session.abort(session)

      messages = Session.messages(session)

      tool =
        Enum.find(messages, fn
          {:tool_call, _} -> true
          _ -> false
        end)

      assert {:tool_call, tc} = tool
      assert tc.status == :error
      assert tc.result == "aborted"
      assert tc.is_error
    end
  end

  describe "new_session/1" do
    test "clears messages and resets status", %{session: session} do
      :ok = Session.send_prompt(session, "First")
      await_turn_complete()

      assert length(Session.messages(session)) > 1

      :ok = Session.new_session(session)

      messages = Session.messages(session)
      assert [{:system, text, :info}] = messages
      assert String.starts_with?(text, "Session cleared")
      assert Session.status(session) == :idle
    end

    test "resets usage counters", %{session: session} do
      :ok = Session.send_prompt(session, "Test")
      await_turn_complete()

      :ok = Session.new_session(session)

      usage = Session.usage(session)
      assert usage.input == 0
      assert usage.cost == 0.0
    end
  end

  describe "subscribe/unsubscribe" do
    test "stops receiving events after unsubscribe", %{session: session} do
      :ok = Session.unsubscribe(session)

      :ok = Session.send_prompt(session, "Test")

      refute_receive {:agent_event, _}, 100
    end
  end

  describe "toggle_tool_collapse/2" do
    test "toggles collapsed state of tool call messages", %{session: session} do
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
    test "tool auto-expands on first ToolUpdate", %{session: session} do
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

    test "tool re-collapses on ToolEnd with duration", %{session: session} do
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

  describe "session persistence" do
    test "session has a unique ID", %{session: session} do
      id = Session.session_id(session)
      assert is_binary(id)
      assert String.length(id) > 0
    end

    test "new_session generates a new ID", %{session: session} do
      id1 = Session.session_id(session)
      :ok = Session.new_session(session)
      id2 = Session.session_id(session)
      assert id1 != id2
    end

    test "save is scheduled after user prompt", %{session: session} do
      # The save fires asynchronously via debounced timer
      Session.send_prompt(session, "test prompt")
      # Just verify no crash; actual file I/O tested in SessionStore tests
      assert Session.session_id(session) |> is_binary()
    end

    test "load_session replaces messages", %{session: session} do
      # Save the current session
      _id = Session.session_id(session)

      # Create a fake saved session
      SessionStore.save(%{
        id: "loaded-session",
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        model_name: "test-model",
        messages: [{:user, "loaded message"}, {:assistant, "loaded reply"}],
        usage: %{input: 500, output: 200, cache_read: 0, cache_write: 0, cost: 0.01}
      })

      :ok = Session.load_session(session, "loaded-session")

      assert Session.session_id(session) == "loaded-session"
      messages = Session.messages(session)
      user_msgs = Enum.filter(messages, &match?({:user, _}, &1))
      assert [{:user, "loaded message"}] = user_msgs
    end

    test "load_session returns error for missing session", %{session: session} do
      assert {:error, _} = Session.load_session(session, "nonexistent")
    end
  end

  describe "ToolFileChanged event" do
    test "broadcasts file_changed with before/after content", %{session: session} do
      event = %Event.ToolFileChanged{
        tool_call_id: "tc1",
        path: "lib/foo.ex",
        before_content: "old content",
        after_content: "new content"
      }

      send(session, {:agent_provider_event, event})

      assert_receive {:agent_event, {:file_changed, "lib/foo.ex", "old content", "new content"}},
                     200
    end
  end

  describe "tool approval" do
    test "ToolApproval event stores pending approval and broadcasts", %{session: session} do
      approval = %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "shell",
        args: %{"command" => "rm -rf /"},
        reply_to: self()
      }

      send(session, {:agent_provider_event, approval})

      # Broadcast should arrive
      assert_receive {:agent_event, {:approval_pending, data}}, 200
      assert data.name == "shell"
      assert data.tool_call_id == "tc1"
    end

    test "respond_to_approval sends decision to reply_to pid", %{session: session} do
      # Register ourselves as the reply_to (simulating the Task)
      approval = %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "write_file",
        args: %{"path" => "foo.ex"},
        reply_to: self()
      }

      send(session, {:agent_provider_event, approval})
      assert_receive {:agent_event, {:approval_pending, _}}, 200

      :ok = Session.respond_to_approval(session, :approve)

      # Should receive the response directly
      assert_receive {:tool_approval_response, "tc1", :approve}
      # And the resolution broadcast
      assert_receive {:agent_event, {:approval_resolved, :approve}}, 200
    end

    test "respond_to_approval with :reject sends reject", %{session: session} do
      approval = %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "shell",
        args: %{},
        reply_to: self()
      }

      send(session, {:agent_provider_event, approval})
      assert_receive {:agent_event, {:approval_pending, _}}, 200

      :ok = Session.respond_to_approval(session, :reject)
      assert_receive {:tool_approval_response, "tc1", :reject}
    end

    test "respond_to_approval with no pending returns error", %{session: session} do
      assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)
    end

    test "abort clears pending approval", %{session: session} do
      approval = %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "shell",
        args: %{},
        reply_to: self()
      }

      send(session, {:agent_provider_event, approval})
      assert_receive {:agent_event, {:approval_pending, _}}, 200

      :ok = Session.abort(session)

      # Pending approval should be cleared
      assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)
    end
  end

  describe "thinking block collapse" do
    test "thinking blocks auto-collapse when text delta arrives", %{session: session} do
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

      # TextDelta arrives (thinking is done, response starting) → auto-collapse
      send(session, {:agent_provider_event, %Event.TextDelta{delta: "Here is my answer"}})

      messages = Session.messages(session)

      thinking =
        Enum.find(messages, fn
          {:thinking, _, _} -> true
          _ -> false
        end)

      assert {:thinking, _, true} = thinking
    end

    test "toggle_all_tool_collapses also toggles thinking blocks", %{session: session} do
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
end
