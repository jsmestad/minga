defmodule MingaEditor.Handlers.GuiActionHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.GuiActionHandler`.
  """

  # Uses the default extension sidebar registry for GUI action routing tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Events
  alias MingaEditor.Commands
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  setup do
    Sidebar.unregister_source({:extension, :gui_action_test})
    Sidebar.unregister_source(:builtin)

    on_exit(fn ->
      Sidebar.unregister_source({:extension, :gui_action_test})
      Sidebar.unregister_source(:builtin)
    end)

    :ok
  end

  test "tab context actions target the requested tab without selecting it" do
    tab1 = Tab.new_file(1, "a.ex")
    tab2 = Tab.new_file(2, "b.ex")
    tab3 = Tab.new_file(3, "c.ex")
    tab_bar = %TabBar{tabs: [tab1, tab2, tab3], active_id: 1, next_id: 4}
    state = TestHelpers.base_state() |> EditorState.set_tab_bar(tab_bar)

    pinned = GuiActionHandler.dispatch(state, {:tab_pin, 3})
    pinned_tab_bar = EditorState.tab_bar(pinned)

    assert pinned_tab_bar.active_id == 1
    assert TabBar.get(pinned_tab_bar, 3).pinned?
    assert Enum.map(TabBar.visible_file_tabs(pinned_tab_bar), & &1.id) == [3, 1, 2]

    moved = GuiActionHandler.dispatch(pinned, {:tab_move_left, 2})
    moved_tab_bar = EditorState.tab_bar(moved)

    assert moved_tab_bar.active_id == 1
    assert Enum.map(TabBar.visible_file_tabs(moved_tab_bar), & &1.id) == [3, 2, 1]

    unpinned = GuiActionHandler.dispatch(moved, {:tab_unpin, 3})
    unpinned_tab_bar = EditorState.tab_bar(unpinned)

    assert unpinned_tab_bar.active_id == 1
    refute TabBar.get(unpinned_tab_bar, 3).pinned?
  end

  test "activating visible sidebars updates focus and keyboard scope" do
    file_tree_state = %FileTreeState{tree_status: :loading, focused: false}

    state =
      TestHelpers.base_state()
      |> EditorState.update_file_tree(fn _file_tree -> file_tree_state end)

    file_tree_active =
      GuiActionHandler.dispatch(state, {:sidebar_action, "file_tree", "renamed_kind", "activate"})

    assert EditorState.file_tree_state(file_tree_active).focused
    assert file_tree_active.workspace.keymap_scope == :file_tree
    assert EditorState.sidebar_active_id(file_tree_active) == "file_tree"

    git_state = EditorState.set_git_status_panel(state, %{entries: []})

    git_active =
      GuiActionHandler.dispatch(
        git_state,
        {:sidebar_action, "git_status", "renamed_kind", "activate"}
      )

    assert git_active.workspace.keymap_scope == :git_status
    assert EditorState.sidebar_active_id(git_active) == "git_status"

    observatory_state =
      state
      |> EditorState.open_observatory(nil)
      |> EditorState.set_keymap_scope(:file_tree)

    observatory_active =
      GuiActionHandler.dispatch(
        observatory_state,
        {:sidebar_action, "observatory", "observatory", "activate"}
      )

    refute EditorState.file_tree_state(observatory_active).focused
    assert observatory_active.workspace.keymap_scope == :editor
    assert EditorState.sidebar_active_id(observatory_active) == "observatory"
  end

  test "native GUI file tree sidebar actions use the registered FileTree action handler" do
    assert :ok = FileTreeFeature.register_contributions(%FileTreeState{})
    state = TestHelpers.base_state()

    opened =
      GuiActionHandler.dispatch(state, {:sidebar_action, "file_tree", "file_tree", "toggle"})

    assert EditorState.file_tree_state(opened).tree != nil
    assert EditorState.file_tree_state(opened).focused
    assert EditorState.sidebar_active_id(opened) == "file_tree"

    focused =
      GuiActionHandler.dispatch(
        %{opened | workspace: %{opened.workspace | keymap_scope: :editor}},
        {:sidebar_action, "file_tree", "file_tree", "activate"}
      )

    assert EditorState.file_tree_state(focused).focused
    assert focused.workspace.keymap_scope == :file_tree
    assert EditorState.sidebar_active_id(focused) == "file_tree"

    closed =
      GuiActionHandler.dispatch(focused, {:sidebar_action, "file_tree", "file_tree", "toggle"})

    assert EditorState.file_tree_state(closed).tree == nil
    assert EditorState.sidebar_active_id(closed) == nil
  end

  test "git porcelain GUI actions report disabled extension instead of no-op" do
    state = TestHelpers.base_state()

    toggled = GuiActionHandler.dispatch(state, {:toggle_panel, 2})

    assert EditorState.status_msg(toggled) ==
             "Git porcelain extension is disabled or failed to load"

    assert toggled.workspace.keymap_scope == state.workspace.keymap_scope
    assert EditorState.sidebar_active_id(toggled) == EditorState.sidebar_active_id(state)

    activated =
      GuiActionHandler.dispatch(state, {:sidebar_action, "git_status", "git_status", "activate"})

    assert EditorState.status_msg(activated) ==
             "Git porcelain extension is disabled or failed to load"

    assert activated.workspace.keymap_scope == state.workspace.keymap_scope
    assert EditorState.sidebar_active_id(activated) == nil
  end

  test "native GUI sidebar actions route to extension-owned sidebars" do
    assert :ok =
             Sidebar.register({:extension, :gui_action_test}, %{
               id: "outline",
               display_name: "Outline",
               action_handler: fn state, action, context ->
                 EditorState.set_status(state, "#{action}:#{context.kind}")
               end
             })

    state = TestHelpers.base_state()

    new_state =
      GuiActionHandler.dispatch(state, {:sidebar_action, "outline", "generic_tree", "activate"})

    assert EditorState.status_msg(new_state) == "activate:generic_tree"
  end

  test "unknown sidebar action is reported instead of silently ignored" do
    state = TestHelpers.base_state()

    log =
      capture_log(fn ->
        new_state =
          GuiActionHandler.dispatch(state, {:sidebar_action, "custom", "custom_kind", "toggle"})

        assert EditorState.status_msg(new_state) ==
                 "Unsupported sidebar action: custom_kind/toggle"
      end)

    assert log =~ "Ignored sidebar action"
    assert log =~ "custom_kind"
  end

  test "command-opened observatory replaces stale active sidebar id" do
    state =
      TestHelpers.base_state()
      |> Map.put(:capabilities, %Capabilities{frontend_type: :native_gui})
      |> EditorState.update_file_tree(fn _file_tree ->
        %FileTreeState{tree_status: :loading, focused: true}
      end)
      |> EditorState.set_keymap_scope(:file_tree)
      |> EditorState.set_sidebar_active_id("git_status")

    new_state = Commands.execute(state, :toggle_beam_observatory)

    assert EditorState.sidebar_active_id(new_state) == "observatory"
    assert EditorState.observatory_visible?(new_state)
    refute EditorState.file_tree_state(new_state).focused
    assert new_state.workspace.keymap_scope == :editor
  end

  test "observatory inspect is a no-op in the Board shell" do
    state = %{
      TestHelpers.base_state()
      | shell: MingaEditor.Shell.Board,
        shell_state: MingaEditor.Shell.Board.State.new()
    }

    assert GuiActionHandler.dispatch(state, {:observatory_inspect, "<0.1.0>"}) == state
  end

  test "power thermal gui action updates resource pressure and broadcasts the event" do
    registry = power_thermal_events_registry()
    start_supervised!({Events, name: registry})
    Events.subscribe(:power_thermal_state_changed, registry: registry)

    state = %{TestHelpers.base_state() | events_registry: registry}

    assert {:ok, {:power_thermal_state, true, {:unknown, 255}}} =
             ProtocolGUI.decode_gui_action(0x47, <<1, 255>>)

    new_state = GuiActionHandler.dispatch(state, {:power_thermal_state, true, {:unknown, 255}})

    assert new_state.resource_pressure ==
             ResourcePressure.update(ResourcePressure.new(), true, {:unknown, 255})

    assert_receive {:minga_event, :power_thermal_state_changed,
                    %Events.PowerThermalStateEvent{
                      low_power?: true,
                      thermal_state: {:unknown, 255}
                    }}
  end

  defp power_thermal_events_registry do
    :"power_thermal_events_#{System.unique_integer([:positive])}"
  end
end
