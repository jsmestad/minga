defmodule MingaAgent.Tools.SubagentTest do
  # Uses the global MingaAgent.Supervisor for child sessions, so this file must run serially.
  use ExUnit.Case, async: false

  alias Minga.Events
  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle
  alias MingaAgent.Tools.Subagent

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
    assert Enum.any?(Session.messages(handle.pid), &(&1 == {:system, "Error: boom", :error}))
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
end
