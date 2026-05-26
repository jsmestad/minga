defmodule MingaEditor.Shell.RegistryTest do
  # Serial because the shell registry is backed by global persistent_term state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Input.Router
  alias MingaEditor.Shell.Registry
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

    assert Enum.map(Registry.list(), & &1.id) == [:traditional, :board]
    assert Registry.module_for(:board) == MingaEditor.Shell.Board
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

  test "register rejects duplicate shell modules" do
    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    assert {:error, {:duplicate_module, FakeShell, :fake}} =
             Registry.register({:extension, :other}, %{
               id: :other,
               module: FakeShell,
               display_name: "Other Fake",
               description: "Other fake shell",
               capabilities: [:tui]
             })
  end

  test "register rejects modules that do not implement the shell callbacks" do
    assert {:error, {:invalid_entry, {:missing_callbacks, String, _callbacks}}} =
             Registry.register({:extension, :bad}, %{
               id: :bad,
               module: String,
               display_name: "Bad",
               description: "Not a shell",
               capabilities: [:tui]
             })
  end

  test "built-in shells survive direct unregister and source cleanup" do
    Registry.seed_builtin()

    assert {:error, :builtin_shell} = Registry.unregister(:traditional)
    assert :ok = Registry.unregister_source(:builtin)

    assert Enum.map(Registry.list(), & &1.id) == [:traditional, :board]
    assert Registry.default().id == :traditional
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

  test "switch_shell stashes and restores shell state by shell id" do
    Registry.seed_builtin()

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    state = TestHelpers.base_state()
    original_shell_state = %{state.shell_state | status_msg: "keep me"}
    state = %{state | shell_state: original_shell_state}

    fake_state = EditorState.switch_shell(state, :fake)
    assert fake_state.shell_id == :fake
    assert fake_state.shell == FakeShell
    assert fake_state.shell_state == %{name: :fake, events: []}
    assert fake_state.shell_state_stash.traditional.state.status_msg == "keep me"

    restored = EditorState.switch_shell(fake_state, :traditional)
    assert restored.shell_id == :traditional
    assert restored.shell_state.status_msg == "keep me"
    assert restored.shell_state_stash.fake.state == %{name: :fake, events: []}
  end

  test "shell state stash does not restore after shell id is re-registered with the same module" do
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
      |> EditorState.update_shell_state(&Map.put(&1, :events, [:old_generation]))
      |> EditorState.switch_shell(:traditional)

    assert state.shell_state_stash.fake.state.events == [:old_generation]

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    switched = EditorState.switch_shell(state, :fake)

    assert switched.shell == FakeShell
    assert switched.shell_state == %{name: :fake, events: []}
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

  test "ensure_shell_available resets nil-identity extension state when shell id is re-registered with the same module" do
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
      |> Map.put(:shell_identity, nil)
      |> EditorState.update_shell_state(&Map.put(&1, :events, [:stale]))

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    reset = EditorState.ensure_shell_available(state)

    assert reset.shell_id == :fake
    assert reset.shell == FakeShell
    assert reset.shell_state.events == []
    assert reset.shell_state.status_msg == "Shell Fake reloaded"
  end

  test "ensure_shell_available resets active state when shell id is re-registered" do
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
    assert state.shell_state == %{name: :fake, events: []}

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert :ok =
             Registry.register({:extension, :fake_alt}, %{
               id: :fake,
               module: FakeShellAlt,
               display_name: "Fake Alt",
               description: "Fake shell alt",
               capabilities: [:tui]
             })

    reset = EditorState.ensure_shell_available(state)

    assert reset.shell_id == :fake
    assert reset.shell == FakeShellAlt
    assert reset.shell_state.name == :fake_alt
    assert reset.shell_state.events == []
    assert reset.shell_state.status_msg == "Shell Fake Alt reloaded"
  end

  test "ensure_shell_available falls back to default when active shell disappears" do
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

    assert :ok = Registry.unregister_source({:extension, :fake})

    assert EditorState.active_shell_module(state) == MingaEditor.Shell.Traditional

    {fallback, log} = with_log(fn -> EditorState.ensure_shell_available(state) end)
    assert log =~ "Active shell :fake"
    assert log =~ "switching to :traditional"
    assert fallback.shell_id == :traditional
    assert fallback.shell == MingaEditor.Shell.Traditional
    assert fallback.workspace.buffers.active == state.workspace.buffers.active
    refute Map.has_key?(fallback.shell_state_stash, :fake)
  end

  test "render input snapshots keep captured shell module after shell id is re-registered" do
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

    assert EditorState.active_shell_module(input) == FakeShell
  end

  test "renderer writeback drops stale output after a shell id is re-registered with the same module" do
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
             Registry.register({:extension, :fake}, %{
               id: :fake,
               module: FakeShell,
               display_name: "Fake",
               description: "Fake shell",
               capabilities: [:tui]
             })

    writeback = %{
      caches: input.caches,
      layout: :rendered_layout,
      focus_tree: :rendered_focus_tree,
      windows: state.workspace.windows,
      shell_id: :fake,
      shell_identity: input.shell_identity,
      shell_state: Map.put(state.shell_state, :modeline_click_regions, [{:old, 1}])
    }

    result = EditorState.apply_renderer_writeback(state, writeback)

    assert result.layout == nil
    assert result.focus_tree == nil
    assert result.shell_id == :fake
    refute Map.has_key?(result.shell_state, :modeline_click_regions)
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

    writeback = %{
      caches: input.caches,
      layout: :rendered_layout,
      focus_tree: :rendered_focus_tree,
      windows: state.workspace.windows,
      shell_id: :fake,
      shell_identity: input.shell_identity,
      shell_state: Map.put(state.shell_state, :modeline_click_regions, [{:old, 1}])
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
