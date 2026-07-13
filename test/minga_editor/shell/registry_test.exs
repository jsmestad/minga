defmodule MingaEditor.Shell.RegistryTest do
  # Serial because the shell registry is backed by global persistent_term state.
  use ExUnit.Case, async: false

  alias Minga.Extension.ContributionCleanup
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionManager.SessionRestartedEvent
  alias MingaEditor.Agent.Events
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Identity
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Test.FakeShell
  alias MingaEditor.Test.FakeShellAlt

  setup do
    Registry.reset_for_test()

    on_exit(fn ->
      Registry.reset_for_test()
      Registry.seed_builtin()
    end)

    :ok
  end

  test "seed_builtin registers Traditional as the default through the registry" do
    Registry.seed_builtin()

    assert %Entry{id: :traditional, source: :builtin, module: MingaEditor.Shell.Traditional} =
             Registry.default()

    assert Enum.map(Registry.list(), & &1.id) == [:traditional]
    assert Registry.id_for_module(MingaEditor.Shell.Traditional) == :traditional
  end

  test "resolve reads ids and modules from one publication" do
    Registry.seed_builtin()
    assert :ok = Registry.register({:extension, :fake}, shell_attrs(:fake, FakeShell, "Fake"))

    snapshot = Registry.snapshot()
    assert Registry.resolve(:fake) == snapshot.entries.fake
    assert Registry.resolve(FakeShell) == snapshot.entries.fake
  end

  test "input dispatch uses the active extension shell contract" do
    Registry.seed_builtin()
    assert :ok = Registry.register({:extension, :fake}, shell_attrs(:fake, FakeShell, "Fake"))

    state = TestHelpers.base_state() |> Workflow.switch(:fake)
    assert Runtime.id(state.shell_runtime) == :fake

    state = Router.dispatch(state, ?x, 0)
    assert Runtime.id(state.shell_runtime) == :fake
    assert Runtime.state(state.shell_runtime).events == [:input_probe]
  end

  test "register rejects duplicate shell ids" do
    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    assert {:error, {:duplicate_id, :fake}} =
             Registry.register({:extension, :other}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Other Fake",
               description: "Other fake shell",
               capabilities: [:tui]
             })
  end

  test "unregister protects source ownership" do
    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    assert {:error, :source_required} = Registry.unregister(:fake)
    assert {:error, :not_owner} = Registry.unregister({:extension, :other}, :fake)
    assert Registry.available?(:fake)
    assert :ok = Registry.unregister({:extension, :fake}, :fake)
    refute Registry.available?(:fake)
  end

  test "source cleanup unregisters extension-owned shells" do
    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    assert Registry.available?(:fake)
    assert :ok = ContributionCleanup.unregister_source({:extension, :fake})
    refute Registry.available?(:fake)
  end

  test "concurrent non-conflicting registrations preserve both contributions" do
    Registry.seed_builtin()
    parent = self()

    first =
      Task.async(fn ->
        send(parent, {:writer_ready, self()})

        receive do: (:publish ->
                       Registry.register(
                         {:extension, :first},
                         shell_attrs(:first, FakeShell, "First")
                       ))
      end)

    second =
      Task.async(fn ->
        send(parent, {:writer_ready, self()})

        receive do: (:publish ->
                       Registry.register(
                         {:extension, :second},
                         shell_attrs(:second, FakeShellAlt, "Second")
                       ))
      end)

    assert_receive {:writer_ready, first_pid}
    assert_receive {:writer_ready, second_pid}
    send(first_pid, :publish)
    send(second_pid, :publish)

    assert Task.await(first) == :ok
    assert Task.await(second) == :ok

    snapshot = Registry.snapshot()
    assert snapshot.entries.first.source == {:extension, :first}
    assert snapshot.entries.first.module == FakeShell
    assert snapshot.entries.second.source == {:extension, :second}
    assert snapshot.entries.second.module == FakeShellAlt
  end

  test "concurrent duplicate decisions publish exactly one coherent owner" do
    Registry.seed_builtin()
    parent = self()

    writers = [
      {{:extension, :first}, FakeShell, "First"},
      {{:extension, :second}, FakeShellAlt, "Second"}
    ]

    tasks =
      Enum.map(writers, fn {source, module, label} ->
        Task.async(fn ->
          send(parent, {:duplicate_writer_ready, self()})
          receive do: (:publish -> Registry.register(source, shell_attrs(:shared, module, label)))
        end)
      end)

    pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:duplicate_writer_ready, pid}
        pid
      end)

    Enum.each(pids, &send(&1, :publish))
    results = Enum.map(tasks, &Task.await/1)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:error, {:duplicate_id, :shared}}, &1)) == 1

    entry = Registry.snapshot().entries.shared

    assert {entry.source, entry.module} in [
             {{:extension, :first}, FakeShell},
             {{:extension, :second}, FakeShellAlt}
           ]
  end

  test "source cleanup removes all owned shells in one generation and preserves fallback" do
    Registry.seed_builtin()
    source = {:extension, :owned}
    assert :ok = Registry.register(source, shell_attrs(:first, FakeShell, "First"))
    assert :ok = Registry.register(source, shell_attrs(:second, FakeShellAlt, "Second"))
    before_cleanup = Registry.snapshot()

    assert :ok = Registry.unregister_source(source)

    after_cleanup = Registry.snapshot()
    assert after_cleanup.generation == before_cleanup.generation + 1
    refute Map.has_key?(after_cleanup.entries, :first)
    refute Map.has_key?(after_cleanup.entries, :second)
    assert after_cleanup.entries.traditional.source == :builtin
    assert after_cleanup.default_id == :traditional
  end

  test "readers observe coherent cleanup and reload publication boundaries" do
    Registry.seed_builtin()
    parent = self()
    old_source = {:extension, :old}
    new_source = {:extension, :new}
    assert :ok = Registry.register(old_source, shell_attrs(:first, FakeShell, "First"))
    assert :ok = Registry.register(old_source, shell_attrs(:second, FakeShellAlt, "Second"))
    before_cleanup = Registry.snapshot()

    writer =
      Task.async(fn ->
        assert :ok = Registry.unregister_source(old_source)
        send(parent, :cleanup_published)

        receive do
          :cleanup_observed -> :ok
        end

        assert :ok = Registry.register(new_source, shell_attrs(:first, FakeShellAlt, "Reloaded"))
        send(parent, :reload_published)

        receive do
          :reload_observed -> :ok
        end
      end)

    assert_receive :cleanup_published
    cleanup = Registry.snapshot()
    assert cleanup.generation == before_cleanup.generation + 1
    refute Map.has_key?(cleanup.entries, :first)
    refute Map.has_key?(cleanup.entries, :second)
    assert cleanup.entries.traditional.source == :builtin
    assert cleanup.default_id == :traditional
    send(writer.pid, :cleanup_observed)

    assert_receive :reload_published
    reload = Registry.snapshot()
    assert reload.generation == cleanup.generation + 1
    assert reload.entries.first.source == new_source
    assert reload.entries.first.module == FakeShellAlt
    refute Map.has_key?(reload.entries, :second)
    assert Enum.find(reload.ordered, &(&1.id == :first)) == reload.entries.first
    send(writer.pid, :reload_observed)

    assert Task.await(writer) == :ok
  end

  test "shell state stash does not restore after shell id is re-registered with a new identity" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake)
      |> Workflow.switch(:traditional)

    assert Runtime.stash(state.shell_runtime).fake.state == %{name: :fake, events: []}

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_alt}, %{
               id: :fake,
               module: FakeShellAlt,
               display_name: "Fake Alt",
               description: "Fake shell alt",
               capabilities: [:tui]
             })

    switched = Workflow.switch(state, :fake)

    assert Runtime.module(switched.shell_runtime) == FakeShellAlt
    assert switched.shell_runtime.state == %{name: :fake_alt, events: []}
  end

  test "switching back restores state for the matching registration" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake)
      |> put_active_shell_fields(%{marker: :preserved})
      |> Workflow.switch(:traditional)
      |> Workflow.switch(:fake)

    assert state.shell_runtime.state.marker == :preserved
  end

  test "current and exactly stashed registrations do not rerun shell initialization" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register(
               {:extension, :fake_alt},
               shell_attrs(:fake_alt, FakeShellAlt, "Fake Alt")
             )

    state = TestHelpers.base_state() |> Workflow.switch(:fake_alt)
    assert_receive {:fake_shell_alt_initialized, _pid}

    state = Workflow.ensure_available(state)
    refute_receive {:fake_shell_alt_initialized, _pid}

    state = Workflow.switch(state, :traditional)
    _state = Workflow.switch(state, :fake_alt)
    refute_receive {:fake_shell_alt_initialized, _pid}
  end

  test "switch invalidates layout and focus while active-shell selection remains a no-op" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    switched =
      %{TestHelpers.base_state() | layout: :layout, focus_tree: :focus}
      |> Workflow.switch(:fake)

    assert switched.layout == nil
    assert switched.focus_tree == nil

    unchanged =
      %{TestHelpers.base_state() | layout: :layout, focus_tree: :focus}
      |> Workflow.switch(:traditional)

    assert unchanged.layout == :layout
    assert unchanged.focus_tree == :focus
    assert EditorState.status_msg(unchanged) == "Already using Traditional"
  end

  test "unavailable active shell falls back with the default identity and fresh state" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake)
      |> put_active_shell_fields(%{obsolete: true})

    assert :ok = Registry.unregister_source({:extension, :fake})

    result = Workflow.ensure_available(state)
    default = Registry.default()

    assert Runtime.id(result.shell_runtime) == default.id
    assert Runtime.module(result.shell_runtime) == default.module
    assert Runtime.identity(result.shell_runtime) == Identity.new(default)
    refute Map.has_key?(result.shell_runtime.state, :obsolete)
    refute Map.has_key?(Runtime.stash(result.shell_runtime), :fake)
    assert result.layout == nil
    assert result.focus_tree == nil
  end

  test "background agent events update a matching stash but not a replaced registration" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    assert :ok =
             Registry.register({:extension, :fake_alt}, %{
               id: :fake_alt,
               module: FakeShellAlt,
               display_name: "Fake Alt",
               description: "Fake shell alt",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake)
      |> put_active_shell_fields(%{record_agent_events?: true})
      |> Workflow.switch(:fake_alt)
      |> Map.put(:backend, :gui)

    event = {:status_changed, :error}
    {:noreply, matching} = MingaEditor.handle_info({:agent_event, self(), event}, state)
    assert Runtime.stash(matching.shell_runtime).fake.state.events == [event]

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_replacement}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake replacement",
               description: "Replacement registration",
               capabilities: [:tui]
             })

    {:noreply, stale} =
      MingaEditor.handle_info({:agent_event, self(), {:status_changed, :idle}}, matching)

    assert Runtime.stash(stale.shell_runtime).fake.state.events == [event]
    Process.cancel_timer(stale.render_correlation.timer)
  end

  test "active agent event retains state returned by shell persistence" do
    Registry.seed_builtin()
    assert :ok = Registry.register({:extension, :fake}, shell_attrs(:fake, FakeShell, "Fake"))

    persisted_state = %{events: [:persisted]}

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake)
      |> put_active_shell_fields(%{
        record_agent_events?: true,
        persist_as: persisted_state
      })
      |> Map.put(:backend, :gui)

    {:noreply, updated} =
      MingaEditor.handle_info({:agent_event, self(), {:status_changed, :error}}, state)

    assert Runtime.state(updated.shell_runtime) == persisted_state
    Process.cancel_timer(updated.render_correlation.timer)
  end

  test "Agent.Events updates matching stashes but skips a replaced registration" do
    Registry.seed_builtin()
    session = self()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    assert :ok =
             Registry.register({:extension, :fake_alt}, %{
               id: :fake_alt,
               module: FakeShellAlt,
               display_name: "Fake Alt",
               description: "Fake shell alt",
               capabilities: [:tui]
             })

    fake_entry = Registry.get(:fake)

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake_alt)
      |> put_active_shell_fields(%{agent: %AgentState{}, session: session, tab_bar: nil})
      |> stash_shell_state(fake_entry, %{session: session})

    {matching, _effects} = Events.handle(state, {:status_changed, :thinking})
    assert Runtime.stash(matching.shell_runtime).fake.state.synced_agent_status == :thinking

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_replacement}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake replacement",
               description: "Replacement registration",
               capabilities: [:tui]
             })

    {stale, _effects} = Events.handle(matching, {:status_changed, :idle})
    assert Runtime.stash(stale.shell_runtime).fake.state.synced_agent_status == :thinking
  end

  test "buffer session restart updates a matching stash but not a replaced registration" do
    Registry.seed_builtin()
    old_pid = self()
    new_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(new_pid, :stop) end)

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    entry = Registry.get(:fake)

    state =
      TestHelpers.base_state()
      |> stash_shell_state(entry, %{session: old_pid})

    matching =
      BufferManagement.handle_agent_session_restarted(
        state,
        "session-id",
        old_pid,
        new_pid,
        :restarted
      )

    assert Runtime.stash(matching.shell_runtime).fake.state.session == new_pid

    stale_state = state

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_replacement}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake replacement",
               description: "Replacement registration",
               capabilities: [:tui]
             })

    stale =
      BufferManagement.handle_agent_session_restarted(
        stale_state,
        "session-id",
        old_pid,
        new_pid,
        :restarted
      )

    assert Runtime.stash(stale.shell_runtime).fake.state.session == old_pid
    assert {:stale, _normalized} = BufferManagement.prepare_agent_session_restart(stale, old_pid)
  end

  test "active shell session restart resets obsolete registration state before callbacks" do
    Registry.seed_builtin()
    old_pid = self()
    new_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(new_pid, :stop) end)

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake)
      |> put_active_shell_fields(%{session: old_pid})

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_replacement}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake replacement",
               description: "Replacement registration",
               capabilities: [:tui]
             })

    current_entry = Registry.get(:fake)

    restarted =
      BufferManagement.handle_agent_session_restarted(
        state,
        "session-id",
        old_pid,
        new_pid,
        :restarted
      )

    assert Map.take(restarted.shell_runtime.state, [:name, :events]) == %{name: :fake, events: []}
    refute Map.has_key?(restarted.shell_runtime.state, :session)
    assert Runtime.identity(restarted.shell_runtime) == Identity.new(current_entry)

    assert {:stale, normalized} = BufferManagement.prepare_agent_session_restart(state, old_pid)
    assert Runtime.identity(normalized.shell_runtime) == Identity.new(current_entry)
    refute Map.has_key?(normalized.shell_runtime.state, :session)
  end

  test "restart dispatch retains normalized state when subscription is stale" do
    Registry.seed_builtin()
    old_pid = self()
    session_id = "registry-restart-#{System.unique_integer([:positive])}"
    assert {:ok, ^session_id, new_pid} = SessionManager.start_session(session_id: session_id)
    on_exit(fn -> SessionManager.stop_session(session_id) end)

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    assert :ok =
             Registry.register({:extension, :valid}, %{
               id: :valid,
               module: FakeShellAlt,
               display_name: "Valid",
               description: "Valid shell",
               capabilities: [:tui]
             })

    valid_entry = Registry.get(:valid)
    dead_ingest = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor = Process.monitor(dead_ingest)
    send(dead_ingest, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^dead_ingest, :normal}

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake)
      |> put_active_shell_fields(%{session: old_pid})
      |> Map.put(:agent_ingest, dead_ingest)
      |> stash_shell_state(valid_entry, %{session: old_pid})

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_replacement}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake replacement",
               description: "Replacement registration",
               capabilities: [:tui]
             })

    current_entry = Registry.get(:fake)

    normalized =
      EventDispatcher.dispatch(
        state,
        :agent_session_restarted,
        %SessionRestartedEvent{
          session_id: session_id,
          old_pid: old_pid,
          new_pid: new_pid,
          reason: :restarted
        },
        nil
      )

    assert Runtime.identity(normalized.shell_runtime) == Identity.new(current_entry)
    refute Map.has_key?(normalized.shell_runtime.state, :session)
    assert Runtime.stash(normalized.shell_runtime).valid.state.session == old_pid
  end

  test "session down and disconnect reset obsolete active shell state before callbacks" do
    Registry.seed_builtin()
    session = self()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> Workflow.switch(:fake)
      |> put_active_shell_fields(%{session: session})

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_replacement}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake replacement",
               description: "Replacement registration",
               capabilities: [:tui]
             })

    current_entry = Registry.get(:fake)
    normal = BufferManagement.handle_agent_session_down(state, session, :boom)
    disconnected = BufferManagement.handle_agent_session_down(state, session, :noconnection)

    for normalized <- [normal, disconnected] do
      assert Runtime.identity(normalized.shell_runtime) == Identity.new(current_entry)
      refute Map.has_key?(normalized.shell_runtime.state, :session)
      refute Map.has_key?(normalized.shell_runtime.state, :session_down?)
      refute Map.has_key?(normalized.shell_runtime.state, :remote_disconnected?)
    end
  end

  test "buffer lifecycle updates every stashed shell that owns a restarted session" do
    Registry.seed_builtin()
    old_pid = self()
    new_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(new_pid, :stop) end)

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    assert :ok =
             Registry.register({:extension, :fake_alt}, %{
               id: :fake_alt,
               module: FakeShellAlt,
               display_name: "Fake Alt",
               description: "Fake shell alt",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> stash_shell_states([
        {Registry.get(:fake), %{session: old_pid}},
        {Registry.get(:fake_alt), %{session: old_pid}}
      ])

    restarted =
      BufferManagement.handle_agent_session_restarted(
        state,
        "session-id",
        old_pid,
        new_pid,
        :restarted
      )

    sessions =
      Enum.map(Runtime.stash(restarted.shell_runtime), fn {_id, stash} -> stash.state.session end)

    assert Enum.sort(sessions) == [new_pid, new_pid]
    refute Enum.any?(sessions, &(&1 == old_pid))
  end

  test "buffer lifecycle skips a stale stash before the matching owner" do
    Registry.seed_builtin()
    old_pid = self()
    new_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(new_pid, :stop) end)

    assert :ok =
             Registry.register({:extension, :stale}, %{
               id: :a_stale,
               module: FakeShell,
               display_name: "Stale",
               description: "Stale shell",
               capabilities: [:tui]
             })

    assert :ok =
             Registry.register({:extension, :valid}, %{
               id: :z_valid,
               module: FakeShellAlt,
               display_name: "Valid",
               description: "Valid shell",
               capabilities: [:tui]
             })

    stale_entry = Registry.get(:a_stale)
    valid_entry = Registry.get(:z_valid)
    assert :ok = Registry.unregister_source({:extension, :stale})

    assert :ok =
             Registry.register({:extension, :stale_replacement}, %{
               id: :a_stale,
               module: FakeShell,
               display_name: "Stale replacement",
               description: "Replacement registration",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> stash_shell_states([
        {stale_entry, %{session: old_pid}},
        {valid_entry, %{session: old_pid}}
      ])

    restarted =
      BufferManagement.handle_agent_session_restarted(
        state,
        "session-id",
        old_pid,
        new_pid,
        :restarted
      )

    assert Runtime.stash(restarted.shell_runtime).a_stale.state.session == old_pid
    assert Runtime.stash(restarted.shell_runtime).z_valid.state.session == new_pid
  end

  test "agent status synchronization updates every exact-identity stash" do
    Registry.seed_builtin()
    session = self()

    assert :ok =
             Registry.register({:extension, :first}, %{
               id: :first,
               module: FakeShell,
               display_name: "First",
               description: "First shell",
               capabilities: [:tui]
             })

    assert :ok =
             Registry.register({:extension, :second}, %{
               id: :second,
               module: FakeShellAlt,
               display_name: "Second",
               description: "Second shell",
               capabilities: [:tui]
             })

    state =
      TestHelpers.base_state()
      |> stash_shell_states([
        {Registry.get(:first), %{session: session}},
        {Registry.get(:second), %{session: session}}
      ])

    runtime = Runtime.sync_agent_status(state.shell_runtime, Registry.list(), session, :thinking)
    stash = Runtime.stash(runtime)

    assert stash.first.state.synced_agent_status == :thinking
    assert stash.second.state.synced_agent_status == :thinking
  end

  test "renderer writeback drops stale output after a shell id is re-registered" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    state = TestHelpers.base_state() |> Workflow.switch(:fake)
    input = Input.from_editor_state(state)

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_alt}, %{
               id: :fake,
               module: FakeShellAlt,
               display_name: "Fake Alt",
               description: "Fake shell alt",
               capabilities: [:tui]
             })

    writeback = %MingaEditor.Renderer.RenderReceipt{
      layout: :rendered_layout,
      focus_tree: :rendered_focus_tree,
      shell_id: :fake,
      shell_identity: input.shell_identity,
      modeline_click_regions: [{:old, 1}],
      tab_bar_click_regions: [],
      frame_seq: 1,
      keyframe?: false,
      render_sent_at: 0
    }

    available = Workflow.ensure_available(state)
    {result, _receipt_result} = EditorState.integrate_renderer_receipt(available, writeback)

    assert result.layout == nil
    assert result.focus_tree == nil
    assert Runtime.id(result.shell_runtime) == :fake
    refute Map.has_key?(result.shell_runtime.state, :modeline_click_regions)
  end

  test "input dispatch falls back when the active shell has been unregistered" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    frontend =
      start_supervised!(
        {RecordingFrontend, owner: self()},
        id: {:registry_fallback_frontend, System.unique_integer([:positive])}
      )

    state = TestHelpers.base_state(port_manager: frontend) |> Workflow.switch(:fake)
    assert :ok = Registry.unregister_source({:extension, :fake})

    result = Router.dispatch(state, ?j, 0)

    assert Runtime.id(result.shell_runtime) == :traditional
    assert Runtime.module(result.shell_runtime) == MingaEditor.Shell.Traditional
  end

  @spec put_active_shell_fields(EditorState.t(), map()) :: EditorState.t()
  defp put_active_shell_fields(%EditorState{} = state, fields) when is_map(fields) do
    replacement = Map.merge(Runtime.state(state.shell_runtime), fields)

    {runtime, workspace} =
      Runtime.route_event(
        state.shell_runtime,
        state.workspace,
        {:replace_test_state, replacement}
      )

    state
    |> EditorState.apply_shell_runtime_transition(runtime)
    |> EditorState.set_workspace(workspace)
  end

  @spec stash_shell_states(EditorState.t(), [{Entry.t(), term()}]) :: EditorState.t()
  defp stash_shell_states(%EditorState{} = state, entries_and_states) do
    Enum.reduce(entries_and_states, state, fn {entry, shell_state}, state_acc ->
      stash_shell_state(state_acc, entry, shell_state)
    end)
  end

  @spec stash_shell_state(EditorState.t(), Entry.t(), term()) :: EditorState.t()
  defp stash_shell_state(%EditorState{} = state, %Entry{} = entry, shell_state) do
    active_entry = Runtime.entry(state.shell_runtime)
    active_state = Runtime.state(state.shell_runtime)

    runtime =
      state.shell_runtime
      |> Runtime.activate(entry, shell_state)
      |> Runtime.activate(active_entry, active_state)

    EditorState.apply_shell_runtime_transition(state, runtime)
  end

  defp shell_attrs(id, module, label) do
    %{
      id: id,
      module: module,
      display_name: label,
      description: "#{label} shell",
      capabilities: [:tui]
    }
  end
end
