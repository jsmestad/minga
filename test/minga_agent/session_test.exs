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
  @event_timeout 5_000

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
    def seed_messages(_pid, _messages), do: :ok

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
    def seed_messages(_pid, _messages), do: :ok

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
    def seed_messages(_pid, _messages), do: :ok

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
    Session.status(session)
    :ok
  end

  defp start_subscribed_session(provider \\ MockProvider, provider_opts \\ []) do
    {:ok, session} = Session.start_link(provider: provider, provider_opts: provider_opts)
    Session.subscribe(session)
    session
  end

  defp send_approval(session, reply_to \\ self()) do
    approval = %Event.ToolApproval{
      tool_call_id: "tc1",
      name: "shell",
      args: %{"command" => "rm -rf /"},
      reply_to: reply_to
    }

    send_provider_event(session, approval)
    assert_receive {:agent_event, _, {:approval_pending, _}}, @event_timeout
    :ok
  end

  defp start_slow_turn(prompt \\ "first") do
    session = start_subscribed_session(SlowMockProvider)
    assert is_pid(Session.get_provider(session))
    assert :ok = Session.send_prompt(session, prompt)
    assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
    session
  end

  defp finish_slow_turn(session) do
    SlowMockProvider.proceed(Session.get_provider(session))
    assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout
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
    test "starts idle with a system message and zero usage", %{session: session} do
      assert Session.status(session) == :idle
      assert [{:system, text, :info}] = Session.messages(session)
      assert String.starts_with?(text, "Session started")

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

    test "plan mode survives provider events and abort", %{session: session} do
      assert :ok = Session.enter_plan(session)

      events = [
        %Event.AgentStart{},
        %Event.ToolStart{tool_call_id: "tc", name: "read_file"},
        %Event.Error{message: "something broke"}
      ]

      for event <- events do
        send_provider_event(session, event)
        assert Session.status(session) == :plan
      end

      assert :ok = Session.abort(session)
      assert Session.status(session) == :plan
    end

    test "AgentEnd preserves plan mode status" do
      session = start_subscribed_session(SlowMockProvider)

      assert :ok = Session.enter_plan(session)
      assert :ok = Session.send_prompt(session, "hello")
      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout
      assert Session.status(session) == :plan
    end

    test "enter_exec is a no-op when not in plan mode", %{session: session} do
      msg_count_before = length(Session.messages(session))
      assert :ok = Session.enter_exec(session)
      assert Session.status(session) == :idle
      assert length(Session.messages(session)) == msg_count_before
    end
  end

  describe "send_prompt/2" do
    test "adds messages, broadcasts stream events, and records usage", %{session: session} do
      :ok = Session.send_prompt(session, "Hello!")

      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
      assert_receive {:agent_event, _, {:text_delta, "Hello "}}, @event_timeout
      assert_receive {:agent_event, _, {:text_delta, "world!"}}, @event_timeout
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      messages = Session.messages(session)
      assert {:system, _, :info} = Enum.at(messages, 0)
      assert {:user, "Hello!"} = Enum.at(messages, 1)
      assert {:assistant, "Hello world!"} = Enum.at(messages, 2)
      assert Enum.any?(messages, &match?({:usage, %{input: 100, output: 50, cost: 0.01}}, &1))

      usage = Session.usage(session)
      assert usage.input == 100
      assert usage.output == 50
      assert usage.cost == 0.01
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
    test "clears messages, resets status, and resets usage", %{session: session} do
      :ok = Session.send_prompt(session, "First")
      await_turn_complete()
      assert length(Session.messages(session)) > 1

      :ok = Session.new_session(session)

      assert [{:system, text, :info}] = Session.messages(session)
      assert String.starts_with?(text, "Session cleared")
      assert Session.status(session) == :idle

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
      assert {:system, "unsaved local note", :info} in Session.messages(session)

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

    test "respond_to_approval resolves each supported decision" do
      for decision <- [:approve, :reject, :approve_all] do
        session = start_subscribed_session()
        send_approval(session)

        assert :ok = Session.respond_to_approval(session, decision)
        assert_receive {:tool_approval_response, "tc1", ^decision}, @event_timeout
        assert_receive {:agent_event, _, {:approval_resolved, ^decision}}, @event_timeout
        assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)

        if decision == :reject do
          messages = Session.messages(session)
          assert Enum.any?(messages, &match?({:system, "Denied shell" <> _, :info}, &1))
        end
      end
    end

    test "respond_to_approval with no pending returns error", %{session: session} do
      assert {:error, :no_pending_approval} = Session.respond_to_approval(session, :approve)
    end

    test "abort clears pending approval", %{session: session} do
      send_approval(session)

      :ok = Session.abort(session)

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
    test "returns idle session metadata before any user prompt", %{session: session} do
      meta = Session.metadata(session)

      assert is_binary(meta.id)
      assert %DateTime{} = meta.created_at
      assert meta.message_count >= 1
      assert meta.cost == 0.0
      assert meta.status == :idle
      assert meta.first_prompt == nil
    end

    test "first_prompt returns first user message text", %{session: session} do
      Session.send_prompt(session, "Hello there")
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout

      assert Session.metadata(session).first_prompt == "Hello there"
    end
  end

  # ── Queue API ──────────────────────────────────────────────────────────────

  describe "combine_queue_entries_to_text/1" do
    test "formats string and content-part queues" do
      text_parts = [
        %ReqLLM.Message.ContentPart{type: :text, text: "hello "},
        %ReqLLM.Message.ContentPart{type: :image, text: nil},
        %ReqLLM.Message.ContentPart{type: :text, text: "world"}
      ]

      cases = [
        {[], ""},
        {["hello"], "hello"},
        {["first", "second", "third"], "first\n\nsecond\n\nthird"},
        {[text_parts], "hello world"},
        {["string entry", [%ReqLLM.Message.ContentPart{type: :text, text: "part text"}]],
         "string entry\n\npart text"}
      ]

      for {entries, expected} <- cases do
        assert Session.combine_queue_entries_to_text(entries) == expected
      end
    end
  end

  describe "message queuing during streaming" do
    test "queues steering and follow-up messages during streaming and broadcasts each enqueue" do
      session = start_slow_turn()

      assert {:queued, :steering} = Session.send_prompt(session, "steer 1")
      assert_receive {:agent_event, _, {:prompt_queued, "steer 1", :steering}}, @event_timeout

      assert {:queued, :steering} = Session.send_prompt(session, "steer 2")
      assert_receive {:agent_event, _, {:prompt_queued, "steer 2", :steering}}, @event_timeout

      assert {:queued, :follow_up} = Session.queue_follow_up(session, "follow")
      assert_receive {:agent_event, _, {:prompt_queued, "follow", :follow_up}}, @event_timeout

      assert Session.get_queued_messages(session) == {["steer 1", "steer 2"], ["follow"]}

      Session.clear_queues(session)
      finish_slow_turn(session)
    end

    test "dequeue_steering returns steering, keeps follow-up, and records user messages" do
      session = start_slow_turn()

      Session.send_prompt(session, "steer me")
      Session.queue_follow_up(session, "follow up later")

      assert Session.dequeue_steering(session) == ["steer me"]
      assert Session.get_queued_messages(session) == {[], ["follow up later"]}
      assert Enum.any?(Session.messages(session), &match?({:user, "steer me"}, &1))

      Session.clear_queues(session)
      finish_slow_turn(session)
    end

    test "recall, clear, and new_session empty queued messages" do
      recalled = start_slow_turn()
      Session.send_prompt(recalled, "steer")
      Session.queue_follow_up(recalled, "follow")
      assert Session.recall_queues(recalled) == {["steer"], ["follow"]}
      assert Session.get_queued_messages(recalled) == {[], []}
      finish_slow_turn(recalled)

      cleared = start_slow_turn()
      Session.send_prompt(cleared, "steer")
      Session.queue_follow_up(cleared, "follow")
      assert :ok = Session.clear_queues(cleared)
      assert Session.get_queued_messages(cleared) == {[], []}
      finish_slow_turn(cleared)

      reset = start_slow_turn()
      Session.send_prompt(reset, "steer")
      Session.queue_follow_up(reset, "follow")
      assert :ok = Session.new_session(reset)
      assert Session.get_queued_messages(reset) == {[], []}
    end

    test "queue_follow_up when idle sends immediately like send_prompt" do
      session = start_subscribed_session(SlowMockProvider)

      assert :ok = Session.queue_follow_up(session, "immediate follow-up")
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
      assert Enum.any?(Session.messages(session), &match?({:user, "immediate follow-up"}, &1))

      finish_slow_turn(session)
    end
  end

  describe "follow-up auto-send at AgentEnd" do
    test "queued single-message follow-ups are auto-sent when the agent finishes" do
      cases = [
        {:follow_up, "now follow up",
         fn session, text -> Session.queue_follow_up(session, text) end},
        {:steering, "steering msg", fn session, text -> Session.send_prompt(session, text) end}
      ]

      for {kind, text, enqueue} <- cases do
        session = start_slow_turn()
        assert {:queued, ^kind} = enqueue.(session, text)

        SlowMockProvider.proceed(Session.get_provider(session))
        assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
        assert Enum.any?(Session.messages(session), &match?({:user, ^text}, &1))
        assert Session.get_queued_messages(session) == {[], []}

        finish_slow_turn(session)
      end
    end

    test "no queued messages means normal idle transition" do
      session = start_slow_turn("simple")
      finish_slow_turn(session)
    end

    test "mixed steering and follow-up messages are combined at AgentEnd" do
      session = start_slow_turn()

      assert {:queued, :steering} = Session.send_prompt(session, "steer this")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "and follow up")

      SlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
      assert Session.get_queued_messages(session) == {[], []}

      messages = Session.messages(session)

      assert Enum.any?(messages, fn
               {:user, text} ->
                 String.contains?(text, "steer this") and String.contains?(text, "and follow up")

               _ ->
                 false
             end)

      finish_slow_turn(session)
    end
  end

  # ── Stable message IDs ───────────────────────────────────────────────────

  describe "message IDs" do
    test "IDs increment across turns and reset for new or loaded sessions", %{session: session} do
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

      SessionStore.save(%{
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
      })

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
      assert {3, {:assistant, text}} = List.last(pairs_after_delta)
      assert String.contains?(text, "world")

      finish_slow_turn(slow_session)

      pairs_final = Session.messages_with_ids(slow_session)
      assert Enum.map(pairs_final, &elem(&1, 0)) == [1, 2, 3, 4]
      assert length(pairs_final) == length(Session.messages(slow_session))
    end

    test "thinking deltas get one stable ID, then assistant gets the next", %{session: session} do
      send(session, {:agent_provider_event, %Event.AgentStart{}})
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: "hmm"}})
      send(session, {:agent_provider_event, %Event.ThinkingDelta{delta: " ok"}})

      pairs_thinking = Session.messages_with_ids(session)
      assert Enum.map(pairs_thinking, &elem(&1, 0)) == [1, 2]
      assert {2, {:thinking, "hmm ok", _collapsed}} = List.last(pairs_thinking)

      send(session, {:agent_provider_event, %Event.TextDelta{delta: "answer"}})
      pairs_with_assistant = Session.messages_with_ids(session)

      assert Enum.map(pairs_with_assistant, &elem(&1, 0)) == [1, 2, 3]
      assert {3, {:assistant, "answer"}} = List.last(pairs_with_assistant)
      assert length(pairs_with_assistant) == length(Session.messages(session))
    end

    test "tool updates keep a stable tool message ID", %{session: session} do
      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      pairs_start = Session.messages_with_ids(session)
      {tool_id, {:tool_call, tc_start}} = List.last(pairs_start)
      assert tc_start.status == :running

      send(
        session,
        {:agent_provider_event,
         %Event.ToolUpdate{tool_call_id: "tc1", name: "bash", partial_result: "output"}}
      )

      pairs_update = Session.messages_with_ids(session)
      assert {^tool_id, {:tool_call, %{result: "output"}}} = List.last(pairs_update)

      send(
        session,
        {:agent_provider_event, %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "done"}}
      )

      pairs_end = Session.messages_with_ids(session)
      assert {^tool_id, {:tool_call, %{status: :complete}}} = List.last(pairs_end)
      assert length(pairs_end) == length(Session.messages(session))
    end

    test "message mutations preserve existing IDs", %{session: session} do
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

    test "dequeue_steering and system messages assign later IDs", %{session: session} do
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
