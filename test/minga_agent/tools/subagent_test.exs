defmodule MingaAgent.Tools.SubagentTest do
  # Uses the global MingaAgent.Supervisor for child sessions, so this file must run serially.
  use ExUnit.Case, async: false

  alias Minga.Events
  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle
  alias MingaAgent.Tools.Subagent

  @moduletag :tmp_dir

  # ── Test providers ────────────────────────────────────────────────────────

  defmodule GatedProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, text), do: GenServer.call(pid, {:prompt, text})

    @impl MingaAgent.Provider
    def abort(pid), do: GenServer.call(pid, :abort)

    @impl MingaAgent.Provider
    def new_session(pid), do: GenServer.call(pid, :new_session)

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

    @spec proceed(GenServer.server(), String.t()) :: :ok
    def proceed(pid, text \\ "child done"), do: GenServer.call(pid, {:proceed, text})

    @impl GenServer
    def init(opts) do
      {:ok,
       %{subscriber: Keyword.fetch!(opts, :subscriber), test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl GenServer
    def handle_call({:prompt, text}, _from, state) do
      send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
      send(state.test_pid, {:provider_prompt, self(), text})
      {:reply, :ok, state}
    end

    def handle_call({:proceed, text}, _from, state) do
      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: text}})
      send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{}})
      {:reply, :ok, state}
    end

    def handle_call(:abort, _from, state), do: {:reply, :ok, state}
    def handle_call(:new_session, _from, state), do: {:reply, :ok, state}
  end

  defmodule ErrorProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, text), do: GenServer.call(pid, {:prompt, text})

    @impl MingaAgent.Provider
    def abort(pid), do: GenServer.call(pid, :abort)

    @impl MingaAgent.Provider
    def new_session(pid), do: GenServer.call(pid, :new_session)

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

    @impl GenServer
    def init(opts) do
      {:ok,
       %{subscriber: Keyword.fetch!(opts, :subscriber), test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    @impl GenServer
    def handle_call({:prompt, text}, _from, state) do
      send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
      send(state.test_pid, {:provider_prompt, self(), text})
      send(state.subscriber, {:agent_provider_event, %Event.Error{message: "boom"}})
      {:reply, :ok, state}
    end

    def handle_call(:abort, _from, state), do: {:reply, :ok, state}
    def handle_call(:new_session, _from, state), do: {:reply, :ok, state}
  end

  defmodule TestNotifier do
    @spec notify(atom(), String.t(), pid()) :: :ok
    def notify(trigger, message, test_pid) do
      send(test_pid, {:notified, trigger, message})
      :ok
    end
  end

  defmodule RecordingProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl MingaAgent.Provider
    def send_prompt(pid, text) do
      GenServer.call(pid, {:send_prompt, text})
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
    def get_state(pid) do
      GenServer.call(pid, :get_state)
    end

    @impl GenServer
    def init(opts) do
      notify_test(opts, {:provider_started, self(), opts})

      state = %{
        subscriber: Keyword.fetch!(opts, :subscriber),
        model: Keyword.get(opts, :model),
        provider: Keyword.get(opts, :provider, "recording"),
        thinking_level: Keyword.get(opts, :thinking_level),
        active_skill_names: Keyword.get(opts, :active_skill_names, []),
        project_root: Keyword.get(opts, :project_root),
        blocking: Keyword.get(opts, :blocking, false),
        test_pid: Keyword.get(opts, :test_pid),
        test_ref: Keyword.get(opts, :test_ref)
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_call({:send_prompt, text}, _from, state) do
      notify_test(state, {:prompt_received, self(), state.subscriber, text})
      notify_session(state, %Event.AgentStart{})

      if state.blocking do
        {:reply, :ok, state}
      else
        notify_session(state, %Event.TextDelta{delta: "child response"})
        notify_session(state, %Event.AgentEnd{usage: nil})
        {:reply, :ok, state}
      end
    end

    def handle_call(:get_state, _from, state) do
      provider_state = %{
        model: %{id: state.model, name: state.model, provider: state.provider},
        is_streaming: false,
        token_usage: nil,
        thinking_level: state.thinking_level,
        active_skill_names: state.active_skill_names,
        project_root: state.project_root
      }

      {:reply, {:ok, provider_state}, state}
    end

    @impl GenServer
    def handle_cast(:finish, state) do
      notify_session(state, %Event.TextDelta{delta: "blocked child response"})
      notify_session(state, %Event.AgentEnd{usage: nil})
      {:noreply, state}
    end

    def handle_cast(_message, state), do: {:noreply, state}

    @spec finish(GenServer.server()) :: :ok
    def finish(pid) do
      GenServer.cast(pid, :finish)
    end

    @spec notify_session(map(), Event.t()) :: :ok
    defp notify_session(state, event) do
      send(state.subscriber, {:agent_provider_event, event})
      :ok
    end

    @spec notify_test(keyword() | map(), tuple()) :: :ok
    defp notify_test(opts_or_state, message) do
      test_pid = get_opt(opts_or_state, :test_pid)
      test_ref = get_opt(opts_or_state, :test_ref)

      if is_pid(test_pid) and test_ref != nil do
        send(test_pid, {test_ref, message})
      end

      :ok
    end

    @spec get_opt(keyword() | map(), atom()) :: term()
    defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
    defp get_opt(state, key) when is_map(state), do: Map.get(state, key)
  end

  defmodule OverrideProvider do
    @behaviour MingaAgent.Provider

    @impl MingaAgent.Provider
    def start_link(opts), do: RecordingProvider.start_link(opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, text), do: RecordingProvider.send_prompt(pid, text)

    @impl MingaAgent.Provider
    def abort(pid), do: RecordingProvider.abort(pid)

    @impl MingaAgent.Provider
    def new_session(pid), do: RecordingProvider.new_session(pid)

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(pid), do: RecordingProvider.get_state(pid)
  end

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup do
    name = :"subagent_manager_#{System.unique_integer([:positive])}"
    {:ok, manager} = GenServer.start(SessionManager, [], name: name)

    on_exit(fn ->
      manager
      |> GenServer.call(:list_sessions)
      |> Enum.each(fn {session_id, _pid, _meta} ->
        GenServer.call(manager, {:stop_session, session_id})
      end)

      GenServer.stop(manager)
    end)

    %{manager: manager}
  end

  # ── Background subagent tests ──────────────────────────────────────────────

  test "background subagent returns a stable handle before the child finishes", %{
    manager: manager
  } do
    test_pid = self()

    Events.subscribe(:background_subagent_started)

    task =
      Task.async(fn ->
        Subagent.execute("long task",
          background: true,
          session_manager: manager,
          provider: GatedProvider,
          provider_opts: [test_pid: test_pid]
        )
      end)

    assert {:ok, result} = Task.await(task)
    assert result =~ "Handle: session-1"

    assert_receive {:minga_event, :background_subagent_started,
                    %Handle{session_id: "session-1", task: "long task"}},
                   1_000

    [handle] = SessionManager.list_background_subagents(manager, nil)
    assert %Handle{session_id: "session-1", pid: child_pid} = handle
    assert Session.status(child_pid) in [:idle, :thinking]

    assert_receive {:provider_prompt, provider_pid, "long task"}, 1_000
    assert Session.status(child_pid) == :thinking

    assert :ok = GatedProvider.proceed(provider_pid)
    assert_eventually_idle(child_pid)
  end

  test "parent session remains usable while background child is running", %{manager: manager} do
    {:ok, _parent_id, parent_pid} =
      SessionManager.start_session(manager,
        provider: GatedProvider,
        provider_opts: [test_pid: self()]
      )

    {:ok, _result} =
      Subagent.execute("child work",
        background: true,
        session_manager: manager,
        parent_session: parent_pid,
        provider: GatedProvider,
        provider_opts: [test_pid: self()]
      )

    assert_receive {:provider_prompt, _provider_pid, "child work"}, 1_000
    [handle] = SessionManager.list_background_subagents(manager, parent_pid)
    assert handle.parent_pid == parent_pid

    :ok = Session.add_system_message(parent_pid, "parent still responsive")

    assert Enum.any?(
             Session.messages(parent_pid),
             &(&1 == {:system, "parent still responsive", :info})
           )
  end

  test "background child result remains available in child chat", %{manager: manager} do
    {:ok, _result} =
      Subagent.execute("write result",
        background: true,
        session_manager: manager,
        provider: GatedProvider,
        provider_opts: [test_pid: self()]
      )

    [handle] = SessionManager.list_background_subagents(manager, nil)
    Session.subscribe(handle.pid)
    assert_receive {:provider_prompt, provider_pid, "write result"}, 1_000
    :ok = GatedProvider.proceed(provider_pid, "saved answer")
    assert_receive {:agent_event, _pid, {:status_changed, :idle}}, 1_000

    assert Enum.any?(Session.messages(handle.pid), &(&1 == {:assistant, "saved answer"}))
  end

  test "background child error remains available in child chat and notifies once", %{
    manager: manager
  } do
    {:ok, _result} =
      Subagent.execute("fail",
        background: true,
        session_manager: manager,
        provider: ErrorProvider,
        provider_opts: [test_pid: self()],
        notifier: {TestNotifier, self()}
      )

    [handle] = SessionManager.list_background_subagents(manager, nil)
    Session.subscribe(handle.pid)
    assert_receive {:provider_prompt, _provider_pid, "fail"}, 1_000
    assert Session.status(handle.pid) == :error
    assert_receive {:notified, :error, "boom"}, 1_000
    refute_receive {:notified, :error, _}, 50

    assert Session.status(handle.pid) == :error
    assert Enum.any?(Session.messages(handle.pid), &(&1 == {:system, "boom", :error}))
  end

  test "background child completion notifies once", %{manager: manager} do
    {:ok, _result} =
      Subagent.execute("notify",
        background: true,
        session_manager: manager,
        provider: GatedProvider,
        provider_opts: [test_pid: self()],
        notifier: {TestNotifier, self()}
      )

    [handle] = SessionManager.list_background_subagents(manager, nil)
    Session.subscribe(handle.pid)
    assert_receive {:provider_prompt, provider_pid, "notify"}, 1_000
    :ok = GatedProvider.proceed(provider_pid)
    assert_receive {:agent_event, _pid, {:status_changed, :idle}}, 1_000
    assert_receive {:notified, :complete, "Sub-agent session-1 finished"}, 1_000
    refute_receive {:notified, :complete, _}, 50
  end

  # ── Foreground subagent tests ──────────────────────────────────────────────

  test "foreground subagent still blocks and returns final text" do
    test_pid = self()

    task =
      Task.async(fn ->
        Subagent.execute("foreground",
          provider: GatedProvider,
          provider_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:provider_prompt, provider_pid, "foreground"}, 1_000
    :ok = GatedProvider.proceed(provider_pid, "foreground done")
    assert {:ok, "foreground done"} = Task.await(task)
  end

  # ── Context inheritance tests ──────────────────────────────────────────────

  describe "execute/2 context inheritance" do
    test "inherits parent provider model thinking level and active skills by default", %{
      tmp_dir: dir
    } do
      ref = make_ref()
      parent = start_parent_session(dir, ref)

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 parent_session: parent,
                 project_root: dir,
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_child_started(ref, fn opts ->
        assert Keyword.fetch!(opts, :model) == "parent-model"
        assert Keyword.fetch!(opts, :provider) == "recording"
        assert Keyword.fetch!(opts, :thinking_level) == "high"
        assert Keyword.fetch!(opts, :active_skill_names) == ["plan", "review"]
        assert Keyword.fetch!(opts, :project_root) == dir
      end)
    end

    test "explicit model override wins while other parent context is inherited", %{tmp_dir: dir} do
      ref = make_ref()
      parent = start_parent_session(dir, ref)

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 parent_session: parent,
                 project_root: dir,
                 model: "override-model",
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_child_started(ref, fn opts ->
        assert Keyword.fetch!(opts, :model) == "override-model"
        assert Keyword.fetch!(opts, :provider) == "recording"
        assert Keyword.fetch!(opts, :thinking_level) == "high"
        assert Keyword.fetch!(opts, :active_skill_names) == ["plan", "review"]
      end)
    end

    test "explicit provider override wins over the parent provider", %{tmp_dir: dir} do
      ref = make_ref()
      parent = start_parent_session(dir, ref)

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 parent_session: parent,
                 project_root: dir,
                 provider: OverrideProvider,
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_child_started(ref, fn opts ->
        assert Keyword.fetch!(opts, :provider) == inspect(OverrideProvider)
        assert Keyword.fetch!(opts, :model) == "parent-model"
        assert Keyword.fetch!(opts, :thinking_level) == "high"
        assert Keyword.fetch!(opts, :active_skill_names) == ["plan", "review"]
      end)
    end

    test "explicit provider and model overrides are visible in the child first system message", %{
      tmp_dir: dir
    } do
      ref = make_ref()
      test_pid = self()

      task =
        Task.async(fn ->
          Subagent.execute("do child task",
            project_root: dir,
            provider: OverrideProvider,
            model: "override-model",
            provider_opts: [test_pid: test_pid, test_ref: ref, blocking: true]
          )
        end)

      assert_receive {^ref, {:prompt_received, provider_pid, child_session, "do child task"}},
                     1_000

      [{:system, first_system_message, :info} | _rest] = Session.messages(child_session)
      assert first_system_message =~ "Subagent overrides"
      assert first_system_message =~ "provider override: #{inspect(OverrideProvider)}"
      assert first_system_message =~ "model override: override-model"

      RecordingProvider.finish(provider_pid)
      assert {:ok, "blocked child response"} = Task.await(task, 1_000)
    end

    test "falls back to default context when parent session is already dead", %{tmp_dir: dir} do
      ref = make_ref()
      parent = start_parent_session(dir, ref)
      monitor_ref = Process.monitor(parent)
      assert :ok = MingaAgent.Supervisor.stop_session(parent)
      assert_receive {:DOWN, ^monitor_ref, :process, ^parent, _reason}, 1_000

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 project_root: dir,
                 parent_session: parent,
                 provider: RecordingProvider,
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_child_started(ref, fn opts ->
        refute Keyword.has_key?(opts, :thinking_level)
        assert Keyword.get(opts, :active_skill_names, []) == []
      end)
    end

    test "stops the child session after success", %{tmp_dir: dir} do
      ref = make_ref()
      parent = start_parent_session(dir, ref)

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 parent_session: parent,
                 project_root: dir,
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_receive {^ref, {:prompt_received, _provider_pid, child_session, "do child task"}},
                     1_000

      monitor_ref = Process.monitor(child_session)
      assert_receive {:DOWN, ^monitor_ref, :process, ^child_session, _reason}, 1_000
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp assert_eventually_idle(session_pid) do
    Session.subscribe(session_pid)

    if Session.status(session_pid) == :idle do
      :ok
    else
      receive do
        {:agent_event, ^session_pid, {:status_changed, :idle}} -> :ok
      after
        1_000 -> flunk("session did not become idle")
      end
    end
  end

  @spec start_parent_session(String.t(), reference()) :: pid()
  defp start_parent_session(dir, ref) do
    {:ok, parent} =
      MingaAgent.Supervisor.start_session(
        provider: RecordingProvider,
        model_name: "parent-model",
        provider_opts: [
          provider: "recording",
          model: "parent-model",
          thinking_level: "high",
          active_skill_names: ["plan", "review"],
          project_root: dir,
          test_pid: self(),
          test_ref: ref
        ]
      )

    assert_receive {^ref, {:provider_started, _provider_pid, opts}}, 1_000
    assert Keyword.fetch!(opts, :subscriber) == parent
    on_exit(fn -> MingaAgent.Supervisor.stop_session(parent) end)
    parent
  end

  @spec assert_child_started(reference(), (keyword() -> any())) :: :ok
  defp assert_child_started(ref, assertions) do
    assert_receive {^ref, {:provider_started, _provider_pid, opts}}, 1_000
    assertions.(opts)
    :ok
  end
end
