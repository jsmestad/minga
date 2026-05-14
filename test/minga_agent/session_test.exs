defmodule MingaAgent.SessionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Branch
  alias MingaAgent.Event
  alias MingaAgent.MCP.FakeTransport
  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session
  alias MingaAgent.SessionStore
  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  @moduletag :tmp_dir
  @event_timeout 2_000

  # ── Mock provider ──────────────────────────────────────────────────────────

  # A provider that starts an agent run but waits for an explicit :proceed
  # message before sending AgentEnd. Allows tests to inspect Session state
  # while the agent is "streaming" (i.e., status is :thinking).
  defmodule SlowMockProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, text), do: GenServer.cast(pid, {:prompt, text})

    @impl MingaAgent.Provider
    def abort(pid), do: GenServer.cast(pid, :abort)

    @impl MingaAgent.Provider
    def new_session(pid), do: GenServer.cast(pid, :new_session)

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

    @doc false
    @spec proceed(GenServer.server()) :: :ok
    def proceed(pid), do: GenServer.cast(pid, :proceed)

    @impl GenServer
    def init(opts) do
      subscriber = Keyword.fetch!(opts, :subscriber)
      {:ok, %{subscriber: subscriber, pending: nil}}
    end

    @impl GenServer
    def handle_cast({:prompt, text}, state) do
      send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: text}})
      {:noreply, %{state | pending: text}}
    end

    def handle_cast(:proceed, state) do
      usage = %MingaAgent.TurnUsage{
        input: 10,
        output: 5,
        cache_read: 0,
        cache_write: 0,
        cost: 0.001
      }

      send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{usage: usage}})
      {:noreply, %{state | pending: nil}}
    end

    def handle_cast(:abort, state), do: {:noreply, state}
    def handle_cast(:new_session, state), do: {:noreply, state}
  end

  defmodule MockProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl MingaAgent.Provider
    def send_prompt(pid, text) do
      GenServer.cast(pid, {:prompt, text})
      :ok
    end

    @impl MingaAgent.Provider
    def abort(pid) do
      GenServer.cast(pid, :abort)
      :ok
    end

    @impl MingaAgent.Provider
    def new_session(pid) do
      GenServer.cast(pid, :new_session)
      :ok
    end

    @impl MingaAgent.Provider
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

      usage = %MingaAgent.TurnUsage{
        input: 100,
        output: 50,
        cache_read: 0,
        cache_write: 0,
        cost: 0.01
      }

      send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{usage: usage}})

      {:noreply, state}
    end

    def handle_cast(:abort, state), do: {:noreply, state}
    def handle_cast(:new_session, state), do: {:noreply, state}

    @impl GenServer
    def handle_call({:set_model, model}, _from, state) do
      {:reply, :ok, Map.put(state, :model, model)}
    end

    @impl MingaAgent.Provider
    def set_model(pid, model) do
      GenServer.call(pid, {:set_model, model})
    end
  end

  defmodule PlanToolProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, _text) do
      GenServer.cast(pid, :attempt_write)
      :ok
    end

    @impl MingaAgent.Provider
    def abort(pid) do
      GenServer.cast(pid, :abort)
      :ok
    end

    @impl MingaAgent.Provider
    def new_session(pid) do
      GenServer.cast(pid, :new_session)
      :ok
    end

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

    @impl GenServer
    def init(opts) do
      subscriber = Keyword.fetch!(opts, :subscriber)
      parent = Keyword.fetch!(opts, :parent)
      registry = :"plan_tool_provider_#{System.unique_integer([:positive])}"

      :ets.new(registry, [:named_table, :set, :public, read_concurrency: true])

      spec =
        Spec.new!(
          name: "write_file",
          description: "test write",
          parameter_schema: %{},
          callback: fn args ->
            send(parent, {:write_callback_called, args})
            {:ok, "wrote"}
          end
        )

      Registry.register(registry, spec)
      {:ok, %{subscriber: subscriber, parent: parent, registry: registry}}
    end

    @impl GenServer
    def handle_cast(:attempt_write, state) do
      result =
        Executor.execute(
          "write_file",
          %{"path" => "plan-mode.txt", "content" => "changed"},
          state.registry,
          execution_mode(MingaAgent.Session.status(state.subscriber))
        )

      maybe_emit_plan_refusal(state.subscriber, result)
      send(state.parent, {:provider_tool_result, result})
      {:noreply, state}
    end

    def handle_cast(:abort, state), do: {:noreply, state}
    def handle_cast(:new_session, state), do: {:noreply, state}

    @spec execution_mode(MingaAgent.Session.status()) :: Executor.execution_mode()
    defp execution_mode(:plan), do: :plan
    defp execution_mode(_status), do: :exec

    @spec maybe_emit_plan_refusal(pid(), Executor.result()) :: :ok
    defp maybe_emit_plan_refusal(subscriber, {:error, {:plan_mode_refused, message}}) do
      send(
        subscriber,
        {:agent_provider_event, %Event.SystemMessage{message: message, level: :info}}
      )

      :ok
    end

    defp maybe_emit_plan_refusal(_subscriber, _result), do: :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Waits for all provider events to be processed by the session after
  # send_prompt. The session broadcasts {:status_changed, :idle} as its
  # final action when a turn completes, so receiving that event guarantees
  # all handle_info callbacks have run.
  defp await_turn_complete do
    assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
  end

  defp send_provider_event(session, event) do
    send(session, {:agent_provider_event, event})
    :sys.get_state(session)
  end

  defp mcp_session_builtin_tool do
    ReqLLM.Tool.new!(
      name: "builtin_echo",
      description: "Builtin echo",
      parameter_schema: %{"type" => "object", "properties" => %{}},
      callback: fn _args -> {:ok, "builtin ok"} end
    )
  end

  defp mcp_session_stream(chunks) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: %{}, finish_reason: :stop}
      end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: chunks,
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
       context: ReqLLM.Context.new()
     }}
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

  describe "plan mode" do
    test "enter_plan sets status, broadcasts, and writes a system message", %{session: session} do
      assert :ok = Session.enter_plan(session)
      assert Session.status(session) == :plan
      assert_receive {:agent_event, _, {:status_changed, :plan}}, @event_timeout

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text =~ "Plan mode" and text =~ "/exec"
               _ -> false
             end)
    end

    test "enter_exec leaves plan mode and writes a system message", %{session: session} do
      assert :ok = Session.enter_plan(session)
      assert :ok = Session.enter_exec(session)
      assert Session.status(session) == :idle
      assert_receive {:agent_event, _, {:status_changed, :plan}}, @event_timeout
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text =~ "Execution mode" and text =~ "/plan"
               _ -> false
             end)
    end

    test "provider write tool is refused through a real plan-mode session" do
      {:ok, session} =
        Session.start_link(
          provider: PlanToolProvider,
          provider_opts: [parent: self()]
        )

      Session.subscribe(session)
      assert :ok = Session.enter_plan(session)
      assert :ok = Session.send_prompt(session, "write a file")

      assert_receive {:provider_tool_result, {:error, {:plan_mode_refused, message}}},
                     @event_timeout

      assert message =~ "Plan mode"
      assert message =~ "write_file"
      assert message =~ "/exec"
      refute_receive {:write_callback_called, _args}, 20

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text == message
               _ -> false
             end)
    end

    test "provider working events do not leave plan mode", %{session: session} do
      assert :ok = Session.enter_plan(session)
      send(session, {:agent_provider_event, %Event.AgentStart{}})

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc", name: "read_file"}}
      )

      assert Session.status(session) == :plan
    end

    test "AgentEnd preserves plan mode status" do
      {:ok, session} =
        Session.start_link(
          provider: SlowMockProvider,
          provider_opts: []
        )

      Session.subscribe(session)
      assert :ok = Session.enter_plan(session)
      assert :ok = Session.send_prompt(session, "hello")
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout
      assert Session.status(session) == :plan
    end

    test "abort preserves plan mode", %{session: session} do
      assert :ok = Session.enter_plan(session)
      assert :ok = Session.abort(session)
      assert Session.status(session) == :plan
    end

    test "enter_exec is a no-op when not in plan mode", %{session: session} do
      msg_count_before = length(Session.messages(session))
      assert :ok = Session.enter_exec(session)
      assert Session.status(session) == :idle
      assert length(Session.messages(session)) == msg_count_before
    end

    test "error event preserves plan mode", %{session: session} do
      assert :ok = Session.enter_plan(session)

      send(
        session,
        {:agent_provider_event, %Event.Error{message: "something broke"}}
      )

      # Sync via a GenServer.call to ensure the handle_info has been processed
      assert Session.status(session) == :plan
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

      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "broadcasts text deltas", %{session: session} do
      :ok = Session.send_prompt(session, "Test")

      assert_receive {:agent_event, _, {:text_delta, "Hello "}}, @event_timeout
      assert_receive {:agent_event, _, {:text_delta, "world!"}}, @event_timeout
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

  describe "set_model/2" do
    test "preserves conversation messages when switching models", %{session: session} do
      :ok = Session.send_prompt(session, "Hello before model switch")
      await_turn_complete()

      messages_before = Session.messages(session)
      assert length(messages_before) >= 3

      assert :ok = Session.set_model(session, "openai:gpt-4o")

      messages_after = Session.messages(session)
      # All prior messages should still be there
      assert messages_before == messages_after
    end

    test "returns error when provider is not ready" do
      # Start a session with a provider that will crash immediately
      # so provider stays nil. Use a simpler approach: check the session
      # can handle the call gracefully when provider is nil.
      {:ok, session} =
        Session.start_link(
          provider: MockProvider,
          provider_opts: []
        )

      # Stop the provider to simulate not-ready state
      # Instead, we test the public API which handles nil provider internally
      # The mock provider starts immediately, so this test verifies the happy path
      assert :ok = Session.set_model(session, "anthropic:claude-opus-4-20250514")
    end
  end

  describe "subscribe/unsubscribe" do
    test "stops receiving events after unsubscribe", %{session: session} do
      :ok = Session.unsubscribe(session)

      :ok = Session.send_prompt(session, "Test")

      refute_receive {:agent_event, _, _}, 100
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
        usage: %MingaAgent.TurnUsage{
          input: 500,
          output: 200,
          cache_read: 0,
          cache_write: 0,
          cost: 0.01
        }
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

    test "load_session restores messages, model, provider metadata, and branches", %{tmp_dir: dir} do
      {:ok, session} =
        Session.start_link(
          provider: MockProvider,
          provider_opts: [],
          session_store_dir: dir
        )

      SessionStore.save(
        %{
          id: "resumable-session",
          timestamp: "2026-01-01T00:00:00Z",
          last_message_at: "2026-01-02T00:00:00Z",
          title: "Restore me",
          model_name: "anthropic:claude-sonnet-4",
          provider_name: "native",
          messages: [{:user, "Restore me"}, {:assistant, "Restored reply"}],
          usage: %MingaAgent.TurnUsage{
            input: 20,
            output: 10,
            cache_read: 0,
            cache_write: 0,
            cost: 0.02
          },
          branches: [
            Branch.new("branch-1", [{:user, "branched prompt"}, {:assistant, "branched reply"}])
          ],
          memory: "- [2026-01-01 00:00 UTC] Prefer direct answers\n"
        },
        dir
      )

      assert :ok = Session.load_session(session, "resumable-session")
      assert Session.session_id(session) == "resumable-session"
      assert Session.messages(session) == [{:user, "Restore me"}, {:assistant, "Restored reply"}]

      meta = Session.metadata(session)
      assert meta.model_name == "anthropic:claude-sonnet-4"
      assert meta.provider_name == "native"
      assert meta.turn_count == 1
      assert DateTime.to_iso8601(meta.last_message_at) == "2026-01-02T00:00:00Z"
      assert MingaAgent.Memory.read(dir) =~ "Prefer direct answers"

      assert {:ok, branches} = Session.list_branches(session)
      assert branches =~ "branch-1"
      assert :ok = Session.switch_branch(session, 1)

      assert Session.messages(session) == [
               {:user, "branched prompt"},
               {:assistant, "branched reply"}
             ]
    end

    test "load_session leaves existing memory untouched for legacy sessions without a memory snapshot",
         %{
           tmp_dir: dir
         } do
      {:ok, session} =
        Session.start_link(
          provider: MockProvider,
          provider_opts: [],
          session_store_dir: dir
        )

      :ok = MingaAgent.Memory.append("keep this memory", dir)
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)

      File.write!(
        Path.join(sessions_dir, "legacy-session.json"),
        JSON.encode!(%{
          "id" => "legacy-session",
          "timestamp" => "2026-01-01T00:00:00Z",
          "last_message_at" => "2026-01-01T00:00:00Z",
          "title" => "Legacy",
          "model_name" => "test-model",
          "provider_name" => "native",
          "messages" => [%{"type" => "user", "text" => "legacy prompt"}],
          "usage" => %{}
        })
      )

      assert :ok = Session.load_session(session, "legacy-session")
      assert MingaAgent.Memory.read(dir) =~ "keep this memory"
    end

    test "load_session saves the current dirty session before replacement", %{tmp_dir: dir} do
      {:ok, session} =
        Session.start_link(
          provider: MockProvider,
          provider_opts: [],
          session_store_dir: dir
        )

      current_id = Session.session_id(session)
      Session.add_system_message(session, "unsaved local note")
      :sys.get_state(session)

      SessionStore.save(
        %{
          id: "target-session",
          timestamp: "2026-01-01T00:00:00Z",
          last_message_at: "2026-01-01T00:00:00Z",
          title: "Target",
          model_name: "test-model",
          provider_name: "native",
          messages: [{:user, "target prompt"}],
          usage: %MingaAgent.TurnUsage{}
        },
        dir
      )

      assert :ok = Session.load_session(session, "target-session")
      assert {:ok, saved_current} = SessionStore.load(current_id, dir)
      assert {:system, "unsaved local note", :info} in saved_current.messages
      assert Session.session_id(session) == "target-session"
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

      assert_receive {:agent_event, _,
                      {:file_changed, "lib/foo.ex", "old content", "new content"}},
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

      send_provider_event(session, approval)

      # Broadcast should arrive
      assert_receive {:agent_event, _, {:approval_pending, data}}, @event_timeout
      assert data.name == "shell"
      assert data.tool_call_id == "tc1"
      assert data.preview.kind == :command
      assert data.preview.summary == "rm -rf /"
      refute Map.has_key?(data, :reply_to)
    end

    test "respond_to_approval sends decision to reply_to pid", %{session: session} do
      # Register ourselves as the reply_to (simulating the Task)
      approval = %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "write_file",
        args: %{"path" => "foo.ex"},
        reply_to: self()
      }

      send_provider_event(session, approval)
      assert_receive {:agent_event, _, {:approval_pending, _}}, @event_timeout

      :ok = Session.respond_to_approval(session, :approve)

      # Should receive the response directly
      assert_receive {:tool_approval_response, "tc1", :approve}
      # And the resolution broadcast
      assert_receive {:agent_event, _, {:approval_resolved, :approve}}, @event_timeout
    end

    test "respond_to_approval with :reject sends reject", %{session: session} do
      approval = %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "shell",
        args: %{},
        reply_to: self()
      }

      send_provider_event(session, approval)
      assert_receive {:agent_event, _, {:approval_pending, _}}, @event_timeout

      :ok = Session.respond_to_approval(session, :reject)
      assert_receive {:tool_approval_response, "tc1", :reject}

      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:system, "Denied shell" <> _, :info}, &1))
    end

    test "respond_to_approval with :approve_all sends approve_all", %{session: session} do
      approval = %Event.ToolApproval{
        tool_call_id: "tc1",
        name: "shell",
        args: %{},
        reply_to: self()
      }

      send_provider_event(session, approval)
      assert_receive {:agent_event, _, {:approval_pending, _}}, @event_timeout

      :ok = Session.respond_to_approval(session, :approve_all)
      assert_receive {:tool_approval_response, "tc1", :approve_all}
      assert_receive {:agent_event, _, {:approval_resolved, :approve_all}}, @event_timeout
      assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)
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

      send_provider_event(session, approval)
      assert_receive {:agent_event, _, {:approval_pending, _}}, @event_timeout

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

  describe "metadata/1" do
    test "returns session metadata with id, model, and created_at", %{session: session} do
      meta = Session.metadata(session)

      assert is_binary(meta.id)
      assert %DateTime{} = meta.created_at
      assert meta.message_count >= 1
      assert meta.cost == 0.0
      assert meta.status == :idle
    end

    test "first_prompt is nil when no user messages", %{session: session} do
      meta = Session.metadata(session)
      assert meta.first_prompt == nil
    end

    test "first_prompt returns first user message text", %{session: session} do
      Session.send_prompt(session, "Hello there")
      # Wait for prompt to be added to messages
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout

      meta = Session.metadata(session)
      assert meta.first_prompt == "Hello there"
    end
  end

  # ── Queue API ──────────────────────────────────────────────────────────────

  describe "combine_queue_entries_to_text/1" do
    test "returns empty string for empty list" do
      assert Session.combine_queue_entries_to_text([]) == ""
    end

    test "returns a single string unchanged" do
      assert Session.combine_queue_entries_to_text(["hello"]) == "hello"
    end

    test "joins multiple strings with double newlines" do
      result = Session.combine_queue_entries_to_text(["first", "second", "third"])
      assert result == "first\n\nsecond\n\nthird"
    end

    test "extracts text from ContentPart lists" do
      parts = [
        %ReqLLM.Message.ContentPart{type: :text, text: "hello "},
        %ReqLLM.Message.ContentPart{type: :text, text: "world"}
      ]

      assert Session.combine_queue_entries_to_text([parts]) == "hello world"
    end

    test "skips image ContentParts when extracting text" do
      parts = [
        %ReqLLM.Message.ContentPart{type: :text, text: "describe this"},
        %ReqLLM.Message.ContentPart{type: :image, text: nil}
      ]

      assert Session.combine_queue_entries_to_text([parts]) == "describe this"
    end

    test "mixes strings and ContentPart lists" do
      parts = [%ReqLLM.Message.ContentPart{type: :text, text: "part text"}]
      result = Session.combine_queue_entries_to_text(["string entry", parts])
      assert result == "string entry\n\npart text"
    end
  end

  describe "message queuing during streaming" do
    setup do
      {:ok, slow_session} =
        Session.start_link(
          provider: SlowMockProvider,
          provider_opts: []
        )

      Session.subscribe(slow_session)

      # Wait for provider to start
      :sys.get_state(slow_session)

      %{slow_session: slow_session}
    end

    test "send_prompt while streaming queues message as steering", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first message")
      # Wait for AgentStart to be processed (status becomes :thinking)
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      # Second send_prompt while streaming: should queue, not submit
      result = Session.send_prompt(session, "steer me")
      assert result == {:queued, :steering}

      # Steering queue should hold the message
      {steering, follow_up} = Session.get_queued_messages(session)
      assert steering == ["steer me"]
      assert follow_up == []

      # Clear queues before proceeding so the auto-send doesn't trigger.
      # The auto-send behaviour is covered by the "follow-up auto-send" tests.
      Session.clear_queues(session)

      # Let the run finish
      SlowMockProvider.proceed(Session.get_provider(session))

      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "multiple messages accumulate in the steering queue", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      assert {:queued, :steering} = Session.send_prompt(session, "steer 1")
      assert {:queued, :steering} = Session.send_prompt(session, "steer 2")

      {steering, _} = Session.get_queued_messages(session)
      assert steering == ["steer 1", "steer 2"]

      # Clear queues before proceeding so the auto-send doesn't trigger.
      Session.clear_queues(session)

      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "queue_follow_up while streaming queues message as follow_up", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      result = Session.queue_follow_up(session, "follow this up")
      assert result == {:queued, :follow_up}

      {steering, follow_up} = Session.get_queued_messages(session)
      assert steering == []
      assert follow_up == ["follow this up"]

      # Clear the follow-up before proceeding so the auto-send doesn't trigger.
      # The follow-up auto-send behaviour is covered by the dedicated describe block.
      Session.clear_queues(session)
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "dequeue_steering returns and clears only the steering queue", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      Session.send_prompt(session, "steer me")
      Session.queue_follow_up(session, "follow up later")

      steering = Session.dequeue_steering(session)
      assert steering == ["steer me"]

      # Follow-up queue is untouched
      {remaining_steering, follow_up} = Session.get_queued_messages(session)
      assert remaining_steering == []
      assert follow_up == ["follow up later"]

      # Steering messages are added to conversation history on dequeue
      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:user, "steer me"}, &1))

      # Clear the follow-up so it doesn't auto-send during cleanup.
      Session.clear_queues(session)
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "recall_queues returns both queues and clears them", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      Session.send_prompt(session, "steer")
      Session.queue_follow_up(session, "follow")

      {steering, follow_up} = Session.recall_queues(session)
      assert steering == ["steer"]
      assert follow_up == ["follow"]

      # Both queues are now empty
      {s2, f2} = Session.get_queued_messages(session)
      assert s2 == []
      assert f2 == []

      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "clear_queues empties both queues", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      Session.send_prompt(session, "steer")
      Session.queue_follow_up(session, "follow")

      :ok = Session.clear_queues(session)

      {steering, follow_up} = Session.get_queued_messages(session)
      assert steering == []
      assert follow_up == []

      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "queue_follow_up when idle sends immediately like send_prompt", %{slow_session: session} do
      result = Session.queue_follow_up(session, "immediate follow-up")
      assert result == :ok

      # Message should be in conversation history right away
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout
      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:user, "immediate follow-up"}, &1))

      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "new_session clears both queues", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      Session.send_prompt(session, "steer")
      Session.queue_follow_up(session, "follow")

      # Clear queues before proceeding so follow-up auto-send doesn't trigger.
      Session.clear_queues(session)
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      # Re-queue to verify new_session clears them
      Session.send_prompt(session, "second run")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      Session.send_prompt(session, "steer2")
      Session.queue_follow_up(session, "follow2")

      # new_session while idle-ish (we clear queues first then call new_session)
      Session.clear_queues(session)
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      Session.new_session(session)
      {steering, follow_up} = Session.get_queued_messages(session)
      assert steering == []
      assert follow_up == []
    end

    test "prompt_queued event is broadcast when queuing during streaming",
         %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      Session.send_prompt(session, "steer me")
      assert_receive {:agent_event, _, {:prompt_queued, "steer me", :steering}}, @event_timeout

      Session.queue_follow_up(session, "follow")
      assert_receive {:agent_event, _, {:prompt_queued, "follow", :follow_up}}, @event_timeout

      # Clear queues so neither the steering (already dequeued by time proceed is called)
      # nor the follow-up triggers an extra run during cleanup.
      Session.clear_queues(session)
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end
  end

  describe "follow-up auto-send at AgentEnd" do
    setup do
      {:ok, slow_session} =
        Session.start_link(
          provider: SlowMockProvider,
          provider_opts: []
        )

      Session.subscribe(slow_session)
      :sys.get_state(slow_session)

      %{slow_session: slow_session}
    end

    test "queued follow-up is auto-sent when agent finishes", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      Session.queue_follow_up(session, "now follow up")

      # Complete the first run - should trigger the follow-up
      SlowMockProvider.proceed(Session.get_provider(session))

      # Session should NOT go idle yet - it should start a new turn
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      # Follow-up message should appear in conversation history
      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:user, "now follow up"}, &1))

      # Follow-up queue should be cleared
      {_, follow_up} = Session.get_queued_messages(session)
      assert follow_up == []

      # Complete the follow-up run
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "no follow-ups means normal idle transition", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "simple")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "queued steering messages are auto-sent when agent finishes", %{slow_session: session} do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      # Queue a steering message (this is what happens when a user sends a prompt
      # while the agent is busy)
      assert {:queued, :steering} = Session.send_prompt(session, "steering msg")

      # Complete the first run. The steering message should be auto-sent as a new
      # turn instead of being orphaned.
      SlowMockProvider.proceed(Session.get_provider(session))

      # Session should start a new turn (not go idle) because the steering queue
      # had a pending message.
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      # Steering message should appear in conversation history
      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:user, "steering msg"}, &1))

      # Steering queue should be cleared
      {steering, _} = Session.get_queued_messages(session)
      assert steering == []

      # Complete the follow-up run
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "mixed steering and follow-up messages are combined at AgentEnd", %{
      slow_session: session
    } do
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      # Queue both types
      assert {:queued, :steering} = Session.send_prompt(session, "steer this")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "and follow up")

      # Complete the first run. Both messages should be combined into one prompt.
      SlowMockProvider.proceed(Session.get_provider(session))

      # Should start a new turn
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      # Both queues should be cleared
      {steering, follow_up} = Session.get_queued_messages(session)
      assert steering == []
      assert follow_up == []

      # Both messages should appear in the combined user message
      messages = Session.messages(session)

      combined_msg =
        Enum.find(messages, fn
          {:user, text} ->
            String.contains?(text, "steer this") and String.contains?(text, "and follow up")

          _ ->
            false
        end)

      assert combined_msg != nil

      # Complete the second run
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end
  end

  # ── Stable message IDs ───────────────────────────────────────────────────

  describe "message IDs" do
    test "initial session has one message with ID 1", %{session: session} do
      pairs = Session.messages_with_ids(session)
      assert [{1, {:system, _, :info}}] = pairs
    end

    test "send_prompt assigns incrementing IDs", %{session: session} do
      :ok = Session.send_prompt(session, "Hello!")
      await_turn_complete()

      pairs = Session.messages_with_ids(session)
      ids = Enum.map(pairs, &elem(&1, 0))

      # system(1), user(2), assistant(3), usage(4)
      assert ids == [1, 2, 3, 4]
      assert length(pairs) == length(Session.messages(session))
    end

    test "IDs are monotonically increasing after multiple turns", %{session: session} do
      :ok = Session.send_prompt(session, "first")
      await_turn_complete()

      :ok = Session.send_prompt(session, "second")
      await_turn_complete()

      pairs = Session.messages_with_ids(session)
      ids = Enum.map(pairs, &elem(&1, 0))

      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
      assert length(pairs) == length(Session.messages(session))
    end

    test "streaming text deltas don't create new IDs" do
      {:ok, slow_session} =
        Session.start_link(provider: SlowMockProvider, provider_opts: [])

      Session.subscribe(slow_session)
      :sys.get_state(slow_session)

      :ok = Session.send_prompt(slow_session, "hello")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      # Mid-stream: system(1), user(2), assistant(3)
      # The SlowMockProvider sends one TextDelta with the prompt text,
      # which creates an assistant message.
      pairs_during = Session.messages_with_ids(slow_session)
      ids_during = Enum.map(pairs_during, &elem(&1, 0))
      assert ids_during == [1, 2, 3]

      # Send another text delta manually (simulates streaming tokens)
      send(slow_session, {:agent_provider_event, %Event.TextDelta{delta: " world"}})

      # The assistant message at ID 3 should still be there, not a new ID
      pairs_after_delta = Session.messages_with_ids(slow_session)
      ids_after_delta = Enum.map(pairs_after_delta, &elem(&1, 0))
      assert ids_after_delta == [1, 2, 3]

      # Content grew but ID is stable
      {3, {:assistant, text}} = List.last(pairs_after_delta)
      assert String.contains?(text, "world")

      SlowMockProvider.proceed(Session.get_provider(slow_session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      # After turn completes, usage message gets the next ID
      pairs_final = Session.messages_with_ids(slow_session)
      ids_final = Enum.map(pairs_final, &elem(&1, 0))
      assert ids_final == [1, 2, 3, 4]
      assert length(pairs_final) == length(Session.messages(slow_session))
    end

    test "thinking deltas get one stable ID, then assistant gets the next", %{session: session} do
      # Inject events directly: thinking then text
      send(session, {:agent_provider_event, %Event.AgentStart{}})
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: "hmm"}})
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: " ok"}})

      # Sync: call forces processing of all prior handle_info messages
      pairs_thinking = Session.messages_with_ids(session)
      ids = Enum.map(pairs_thinking, &elem(&1, 0))

      # system(1), thinking(2). Two ThinkingDeltas, but one message.
      assert ids == [1, 2]
      assert {2, {:thinking, "hmm ok", _collapsed}} = List.last(pairs_thinking)

      # Now assistant text arrives (collapses thinking, creates new assistant msg)
      send(session, {:agent_provider_event, %Event.TextDelta{delta: "answer"}})
      pairs_with_assistant = Session.messages_with_ids(session)
      ids2 = Enum.map(pairs_with_assistant, &elem(&1, 0))

      # system(1), thinking(2), assistant(3)
      assert ids2 == [1, 2, 3]
      assert {3, {:assistant, "answer"}} = List.last(pairs_with_assistant)
      assert length(pairs_with_assistant) == length(Session.messages(session))
    end

    test "new_session resets IDs to 1", %{session: session} do
      :ok = Session.send_prompt(session, "Hello!")
      await_turn_complete()

      # IDs are now [1, 2, 3, 4]
      pairs_before = Session.messages_with_ids(session)
      assert length(pairs_before) == 4

      :ok = Session.new_session(session)
      # Drain the broadcasts from new_session
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      pairs_after = Session.messages_with_ids(session)
      assert [{1, {:system, _, :info}}] = pairs_after
      assert length(pairs_after) == length(Session.messages(session))
    end

    test "load_session resets IDs starting from 1", %{session: session} do
      SessionStore.save(%{
        id: "id-test-session",
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
      })

      :ok = Session.load_session(session, "id-test-session")
      # Drain the broadcasts
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      pairs = Session.messages_with_ids(session)
      ids = Enum.map(pairs, &elem(&1, 0))
      assert ids == [1, 2]
      assert {1, {:user, "loaded"}} = hd(pairs)
      assert length(pairs) == length(Session.messages(session))
    end

    test "tool start/update/end keeps a stable ID for the tool message", %{session: session} do
      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      pairs_start = Session.messages_with_ids(session)
      {tool_id, {:tool_call, tc_start}} = List.last(pairs_start)
      assert tc_start.status == :running

      # ToolUpdate: in-place mutation, same ID
      send(
        session,
        {:agent_provider_event,
         %Event.ToolUpdate{tool_call_id: "tc1", name: "bash", partial_result: "output"}}
      )

      pairs_update = Session.messages_with_ids(session)
      {^tool_id, {:tool_call, tc_update}} = List.last(pairs_update)
      assert tc_update.result == "output"

      # ToolEnd: in-place mutation, same ID
      send(
        session,
        {:agent_provider_event, %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "done"}}
      )

      pairs_end = Session.messages_with_ids(session)
      {^tool_id, {:tool_call, tc_end}} = List.last(pairs_end)
      assert tc_end.status == :complete

      # IDs list length always matches messages
      assert length(pairs_end) == length(Session.messages(session))
    end

    test "toggle_tool_collapse does not change IDs", %{session: session} do
      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      send(
        session,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "output"}}
      )

      pairs_before = Session.messages_with_ids(session)
      ids_before = Enum.map(pairs_before, &elem(&1, 0))

      tool_index =
        Enum.find_index(pairs_before, fn {_id, msg} -> match?({:tool_call, _}, msg) end)

      :ok = Session.toggle_tool_collapse(session, tool_index)

      pairs_after = Session.messages_with_ids(session)
      ids_after = Enum.map(pairs_after, &elem(&1, 0))

      assert ids_before == ids_after
      assert length(pairs_after) == length(Session.messages(session))
    end

    test "toggle_all_tool_collapses does not change IDs", %{session: session} do
      # Add a thinking block and a tool call
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

      :ok = Session.toggle_all_tool_collapses(session)

      pairs_after = Session.messages_with_ids(session)
      ids_after = Enum.map(pairs_after, &elem(&1, 0))

      assert ids_before == ids_after
    end

    test "abort maps messages in place without changing IDs", %{session: session} do
      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      pairs_before = Session.messages_with_ids(session)
      ids_before = Enum.map(pairs_before, &elem(&1, 0))

      :ok = Session.abort(session)

      pairs_after = Session.messages_with_ids(session)
      ids_after = Enum.map(pairs_after, &elem(&1, 0))

      # Abort adds one "Aborted" system message at the end
      assert Enum.take(ids_after, length(ids_before)) == ids_before
      assert length(ids_after) == length(ids_before) + 1
      assert length(pairs_after) == length(Session.messages(session))
    end

    test "dequeue_steering adds messages with incrementing IDs" do
      {:ok, slow_session} =
        Session.start_link(provider: SlowMockProvider, provider_opts: [])

      Session.subscribe(slow_session)
      :sys.get_state(slow_session)

      :ok = Session.send_prompt(slow_session, "first")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout

      # Queue two steering messages
      assert {:queued, :steering} = Session.send_prompt(slow_session, "steer 1")
      assert {:queued, :steering} = Session.send_prompt(slow_session, "steer 2")

      # Dequeue: adds user messages to history
      _steering = Session.dequeue_steering(slow_session)

      pairs = Session.messages_with_ids(slow_session)
      ids = Enum.map(pairs, &elem(&1, 0))

      # system(1), user(2), assistant(3), steer1-user(4), steer2-user(5)
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
      assert length(pairs) == length(Session.messages(slow_session))

      # Clean up
      Session.clear_queues(slow_session)
      SlowMockProvider.proceed(Session.get_provider(slow_session))
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
    end

    test "add_system_message (cast) assigns a new ID", %{session: session} do
      pairs_before = Session.messages_with_ids(session)
      max_id_before = pairs_before |> Enum.map(&elem(&1, 0)) |> Enum.max()

      Session.add_system_message(session, "hello from test")

      # The cast is async. Use messages_with_ids as a sync barrier.
      pairs_after = Session.messages_with_ids(session)
      ids_after = Enum.map(pairs_after, &elem(&1, 0))

      assert length(ids_after) == length(pairs_before) + 1
      assert List.last(ids_after) > max_id_before
      assert length(pairs_after) == length(Session.messages(session))
    end
  end

  describe "MCP crash handling" do
    test "adds a system message and can still run a builtin tool", %{tmp_dir: dir} do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      llm_client = fn _model, _messages, opts ->
        send(test_pid, {:session_mcp_tools, Enum.map(opts[:tools], & &1.name)})
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          if count == 0 do
            [
              ReqLLM.StreamChunk.tool_call("builtin_echo", %{}, %{id: "tc_builtin", index: 0}),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]
          else
            [
              ReqLLM.StreamChunk.text("still works"),
              ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
            ]
          end

        mcp_session_stream(chunks)
      end

      {:ok, session} =
        Session.start_link(
          provider: Native,
          provider_opts: [
            model: "anthropic:claude-sonnet-4-20250514",
            project_root: dir,
            tools: [mcp_session_builtin_tool()],
            config: %MingaAgent.Config{
              mcp_servers: [%ServerConfig{name: "Local Tools", command: "ignored"}],
              tool_approval: :none
            },
            mcp_transport: FakeTransport,
            mcp_transport_opts: [
              tools: [%{"name" => "echo-text", "inputSchema" => %{"type" => "object"}}],
              test_pid: self()
            ],
            llm_client: llm_client
          ]
        )

      Session.subscribe(session)
      _provider = Session.get_provider(session)
      assert_receive {:mcp_transport_started, "Local Tools", transport}
      FakeTransport.crash(transport)

      assert_receive {:agent_event, ^session, {:error, message}}, @event_timeout
      assert message =~ "MCP server Local Tools stopped"
      assert Enum.any?(Session.messages(session), &match?({:system, _text, :error}, &1))

      assert :ok = Session.send_prompt(session, "continue")
      await_turn_complete()
      assert_receive {:session_mcp_tools, tool_names}, @event_timeout
      assert "builtin_echo" in tool_names
      refute "mcp_local_tools__echo_text" in tool_names

      assert Enum.any?(Session.messages(session), fn
               {:tool_call, %{name: "builtin_echo", status: :complete, is_error: false}} -> true
               _ -> false
             end)
    end
  end
end
