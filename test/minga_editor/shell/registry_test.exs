defmodule MingaEditor.Shell.RegistryTest do
  # Serial because the shell registry is backed by global persistent_term state.
  use ExUnit.Case, async: false

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Identity
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.StateStash
  alias MingaEditor.State, as: EditorState
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
      |> EditorState.switch_shell(:fake)
      |> EditorState.switch_shell(:traditional)

    assert state.shell_state_stash.fake.state == %{name: :fake, events: []}

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_alt}, %{
               id: :fake,
               module: FakeShellAlt,
               display_name: "Fake Alt",
               description: "Fake shell alt",
               capabilities: [:tui]
             })

    switched = EditorState.switch_shell(state, :fake)

    assert switched.shell == FakeShellAlt
    assert switched.shell_state == %{name: :fake_alt, events: []}
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
      |> EditorState.switch_shell(:fake)
      |> EditorState.update_shell_state(&Map.put(&1, :marker, :preserved))
      |> EditorState.switch_shell(:traditional)
      |> EditorState.switch_shell(:fake)

    assert state.shell_state.marker == :preserved
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
      |> EditorState.switch_shell(:fake)

    assert switched.layout == nil
    assert switched.focus_tree == nil

    unchanged =
      %{TestHelpers.base_state() | layout: :layout, focus_tree: :focus}
      |> EditorState.switch_shell(:traditional)

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
      |> EditorState.switch_shell(:fake)
      |> EditorState.update_shell_state(&Map.put(&1, :obsolete, true))

    assert :ok = Registry.unregister_source({:extension, :fake})

    result = EditorState.ensure_shell_available(state)
    default = Registry.default()

    assert result.shell_id == default.id
    assert result.shell == default.module
    assert Identity.matches?(result.shell_identity, default)
    refute Map.has_key?(result.shell_state, :obsolete)
    refute Map.has_key?(result.shell_state_stash, :fake)
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
      |> EditorState.switch_shell(:fake)
      |> EditorState.update_shell_state(&Map.put(&1, :record_agent_events?, true))
      |> EditorState.switch_shell(:fake_alt)
      |> Map.put(:backend, :gui)

    event = {:status_changed, :error}
    {:noreply, matching} = MingaEditor.handle_info({:agent_event, self(), event}, state)
    assert matching.shell_state_stash.fake.state.events == [event]

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

    assert stale.shell_state_stash.fake.state.events == [event]
    Process.cancel_timer(stale.render_timer)
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

    state = %{
      TestHelpers.base_state()
      | shell_state_stash: %{fake: StateStash.new(entry, %{session: old_pid})}
    }

    matching =
      BufferManagement.handle_agent_session_restarted(
        state,
        "session-id",
        old_pid,
        new_pid,
        :restarted
      )

    assert matching.shell_state_stash.fake.state.session == new_pid

    stale_state = %{
      state
      | shell_state_stash: %{fake: StateStash.new(entry, %{session: old_pid})}
    }

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

    assert stale.shell_state_stash.fake.state.session == old_pid
    refute BufferManagement.agent_session_restart_owned?(stale, old_pid)
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
      |> EditorState.switch_shell(:fake)
      |> EditorState.update_shell_state(&Map.put(&1, :session, old_pid))

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

    assert Map.take(restarted.shell_state, [:name, :events]) == %{name: :fake, events: []}
    refute Map.has_key?(restarted.shell_state, :session)
    assert Identity.matches?(restarted.shell_identity, current_entry)
    refute BufferManagement.agent_session_restart_owned?(state, old_pid)
  end

  test "buffer lifecycle stops after the first stashed shell handles a restart" do
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

    state = %{
      TestHelpers.base_state()
      | shell_state_stash: %{
          fake: StateStash.new(Registry.get(:fake), %{session: old_pid}),
          fake_alt: StateStash.new(Registry.get(:fake_alt), %{session: old_pid})
        }
    }

    restarted =
      BufferManagement.handle_agent_session_restarted(
        state,
        "session-id",
        old_pid,
        new_pid,
        :restarted
      )

    sessions = Enum.map(restarted.shell_state_stash, fn {_id, stash} -> stash.state.session end)
    assert Enum.count(sessions, &(&1 == new_pid)) == 1
    assert Enum.count(sessions, &(&1 == old_pid)) == 1
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

    state = TestHelpers.base_state() |> EditorState.switch_shell(:fake)
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

    result = EditorState.apply_renderer_writeback(state, writeback)

    assert result.layout == nil
    assert result.focus_tree == nil
    assert result.shell_id == :fake
    refute Map.has_key?(result.shell_state, :modeline_click_regions)
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

    state = TestHelpers.base_state() |> EditorState.switch_shell(:fake)
    assert :ok = Registry.unregister_source({:extension, :fake})

    result = Router.dispatch(state, ?j, 0)

    assert result.shell_id == :traditional
    assert result.shell == MingaEditor.Shell.Traditional
  end
end
