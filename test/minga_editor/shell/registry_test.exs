defmodule MingaEditor.Shell.RegistryTest do
  # Serial because the shell registry is backed by global persistent_term state.
  use ExUnit.Case, async: false

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Registry
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Test.FakeShell

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
    assert fake_state.shell_state_stash.traditional.status_msg == "keep me"

    restored = EditorState.switch_shell(fake_state, :traditional)
    assert restored.shell_id == :traditional
    assert restored.shell_state.status_msg == "keep me"
    assert restored.shell_state_stash.fake == %{name: :fake, events: []}
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

    fallback = EditorState.ensure_shell_available(state)
    assert fallback.shell_id == :traditional
    assert fallback.shell == MingaEditor.Shell.Traditional
    assert fallback.workspace.buffers.active == state.workspace.buffers.active
    assert fallback.shell_state_stash.fake == %{name: :fake, events: []}
  end
end
