defmodule MingaEditor.Handlers.GuiActionHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.GuiActionHandler`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Events
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias MingaEditor.Agent.SemanticUI.Registry, as: SemanticUIRegistry
  alias MingaEditor.Commands
  alias MingaEditor.Editing
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter
  alias MingaEditor.UI.Popup.Active, as: PopupActive
  alias Minga.Popup.Rule
  alias Minga.Project.FileTree, as: ProjectFileTree

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    semantic_table = Module.concat(__MODULE__, "SemanticUI#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    start_supervised!({SemanticUIRegistry, name: semantic_table, notify: false})
    %{sidebar_registry: table, semantic_registry: semantic_table}
  end

  test "notification dismiss removes only the selected notification", %{sidebar_registry: table} do
    state =
      table
      |> base_state()
      |> EditorState.upsert_notification(
        Notification.new(
          id: "build:test",
          level: :progress,
          title: "Building Minga",
          created_at: 1_715_000_000
        )
      )
      |> EditorState.upsert_notification(
        Notification.new(
          id: "other",
          level: :info,
          title: "Still here",
          created_at: 1_715_000_010
        )
      )

    state = GuiActionHandler.dispatch(state, {:notification_dismiss, "build:test"})

    assert NotificationCenter.find(state.notifications, "build:test") == nil
    assert [%{id: "other"}] = NotificationCenter.list(state.notifications)
  end

  test "tab context actions target the requested tab without selecting it", %{
    sidebar_registry: table
  } do
    tab1 = Tab.new_file(1, "a.ex")
    tab2 = Tab.new_file(2, "b.ex")
    tab3 = Tab.new_file(3, "c.ex")
    tab_bar = %TabBar{tabs: [tab1, tab2, tab3], active_id: 1, next_id: 4}
    state = base_state(table) |> EditorState.set_tab_bar(tab_bar)

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

  test "execute_command switches workspaces by exact workspace id", %{sidebar_registry: table} do
    manual_tab = Tab.new_file(1, "main.ex")
    agent_tab = Tab.new_agent(2, "Agent") |> Tab.set_group(7)

    tab_bar = %TabBar{
      tabs: [manual_tab, agent_tab],
      active_id: 1,
      next_id: 3,
      workspaces: [Workspace.new_manual(nil), Workspace.new_agent(7, "Agent")]
    }

    state = base_state(table) |> EditorState.set_tab_bar(tab_bar)

    switched = GuiActionHandler.dispatch(state, {:execute_command, "workspace_goto_id:7"})

    assert EditorState.tab_bar(switched).active_id == 2
    assert TabBar.active_workspace_id(EditorState.tab_bar(switched)) == 7
  end

  test "activating visible sidebars updates focus and keyboard scope", %{sidebar_registry: table} do
    file_tree_state = %FileTreeState{tree_status: :loading, focused: false}

    state =
      base_state(table)
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

  @tag :tmp_dir
  test "native GUI file tree sidebar actions use the registered FileTree action handler", %{
    sidebar_registry: table,
    tmp_dir: tmp_dir
  } do
    assert :ok = FileTreeFeature.sync_sidebar(%FileTreeState{}, table)

    state =
      table
      |> base_state()
      |> EditorState.update_file_tree(fn _file_tree ->
        %FileTreeState{tree: ProjectFileTree.new(tmp_dir), tree_status: :ready, hidden: true}
      end)

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

    hidden =
      GuiActionHandler.dispatch(focused, {:sidebar_action, "file_tree", "file_tree", "toggle"})

    # Toggling off now hides the sidebar without tearing down the tree (#2626):
    # the data stays loaded so re-showing is a pure layout change, but the
    # sidebar is no longer visible/focused and its contribution is deregistered.
    hidden_state = EditorState.file_tree_state(hidden)
    assert hidden_state.tree != nil
    refute FileTreeState.visible?(hidden_state)
    refute hidden_state.focused
    assert EditorState.sidebar_active_id(hidden) == nil
  end

  test "git porcelain GUI actions report disabled extension instead of no-op", %{
    sidebar_registry: table
  } do
    state = base_state(table)

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

  test "extension panel actions route semantic registry entries before legacy extensions", %{
    sidebar_registry: table,
    semantic_registry: semantic_table
  } do
    :ok =
      SemanticUIRegistry.register(semantic_table, {:bundle, :gui_action_test}, %{
        id: "gui-action-test",
        surface: :dashboard_section,
        payload: [%Text{text: "GUI action test"}],
        actions: [
          %{
            id: "choose_register",
            label: "Choose register",
            editor_action: {:select_register, "g"}
          }
        ]
      })

    state = base_state(table, agent_semantic_ui_registry: semantic_table)

    new_state =
      GuiActionHandler.dispatch(
        state,
        {:extension_panel_action, "bundle:gui_action_test", "choose_register", %{source: :mouse}}
      )

    assert Editing.active_register(new_state) == "g"
  end

  test "extension panel actions report unavailable extensions", %{sidebar_registry: table} do
    state = base_state(table)

    log =
      capture_log(fn ->
        new_state =
          GuiActionHandler.dispatch(
            state,
            {:extension_panel_action, "missing_extension_for_gui_action", :refresh, %{}}
          )

        assert EditorState.status_msg(new_state) == "Extension panel action unavailable"
      end)

    assert log =~ "Extension panel action ignored"
    assert log =~ "missing_extension_for_gui_action/refresh"
  end

  test "font size actions mark retained window state reset-pending", %{sidebar_registry: table} do
    state = table |> base_state() |> clear_window_reset_pending()

    new_state = GuiActionHandler.dispatch(state, {:font_size_adjust, :increase})

    assert new_state.font_size_override != nil

    assert Enum.all?(Map.values(new_state.workspace.windows.map), fn %Window{} = window ->
             match?(%MingaEditor.Window.RenderCache{}, window.render_cache)
           end)
  end

  test "font size reset clears override and marks retained state reset-pending", %{
    sidebar_registry: table
  } do
    state =
      table
      |> base_state()
      |> clear_window_reset_pending()
      |> Map.put(:font_size_override, 18)

    new_state = GuiActionHandler.dispatch(state, {:font_size_adjust, :reset})

    assert new_state.font_size_override == nil

    assert Enum.all?(Map.values(new_state.workspace.windows.map), fn %Window{} = window ->
             match?(%MingaEditor.Window.RenderCache{}, window.render_cache)
           end)
  end

  test "native GUI sidebar actions route to extension-owned sidebars", %{sidebar_registry: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :gui_action_test}, %{
               id: "outline",
               display_name: "Outline",
               action_handler: fn state, action, context ->
                 EditorState.set_status(state, "#{action}:#{context.kind}")
               end
             })

    state = base_state(table)

    new_state =
      GuiActionHandler.dispatch(state, {:sidebar_action, "outline", "generic_tree", "activate"})

    assert EditorState.status_msg(new_state) == "activate:generic_tree"
  end

  test "unknown sidebar action is reported instead of silently ignored", %{
    sidebar_registry: table
  } do
    state = base_state(table)

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

  test "command-opened observatory replaces stale active sidebar id", %{sidebar_registry: table} do
    state =
      base_state(table)
      |> Map.put(:capabilities, %Capabilities{frontend_type: :native_gui, semantic_ui: true})
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

  test "observatory inspect is a no-op when the active shell has no observatory state", %{
    sidebar_registry: table
  } do
    entry = %Entry{
      id: :fake,
      source: :config,
      module: MingaEditor.Test.FakeShell,
      display_name: "Fake",
      description: "Fake shell",
      capabilities: [:gui],
      generation: 1
    }

    state = %{base_state(table) | shell_runtime: Runtime.new(entry, %{})}

    assert GuiActionHandler.dispatch(state, {:observatory_inspect, "<0.1.0>"}) == state
  end

  test "float_popup_dismiss clears a visible observatory inspection float (#2338)", %{
    sidebar_registry: table
  } do
    # The observatory inspection is the higher-priority float source
    # (FloatPopupBuilder checks it first), so dismissing the float clears it back
    # to nil, the same effect inspect_process(state, "") produces.
    inspection = %MingaEditor.Observatory.Inspection{
      visible: true,
      title: "Process <0.1.0>",
      lines: ["Class: worker"],
      width: 82,
      height: 10
    }

    state = base_state(table) |> EditorState.set_observatory_inspection(inspection)

    new_state = GuiActionHandler.dispatch(state, :float_popup_dismiss)

    assert Runtime.state(new_state.shell_runtime).observatory_inspection == nil
  end

  test "float_popup_dismiss closes the open :float popup window (#2338)", %{
    sidebar_registry: table
  } do
    # A window carrying a :float popup rule is the second float source; dismissing
    # the float removes that window from the workspace, the same effect the popup
    # lifecycle close produces (and the keyboard quit key reaches).
    state = base_state(table)
    main_id = state.workspace.windows.active
    popup_id = state.workspace.windows.next_id

    {:ok, popup_buf} = Minga.Buffer.Process.start_link(content: "help")

    popup_window =
      %Window{
        Window.new(popup_id, popup_buf, 10, 40)
        | popup_meta: %PopupActive{
            rule: Rule.new("*Help*", display: :float),
            window_id: popup_id,
            previous_active: main_id
          }
      }

    state =
      update_in(state.workspace.windows, fn windows ->
        %{
          windows
          | map: Map.put(windows.map, popup_id, popup_window),
            active: popup_id,
            next_id: popup_id + 1
        }
      end)

    assert Map.has_key?(state.workspace.windows.map, popup_id)

    new_state = GuiActionHandler.dispatch(state, :float_popup_dismiss)

    refute Map.has_key?(new_state.workspace.windows.map, popup_id)
  end

  test "float_popup_dismiss is a no-op when no float popup is visible (#2338)", %{
    sidebar_registry: table
  } do
    state = base_state(table)

    assert GuiActionHandler.dispatch(state, :float_popup_dismiss) == state
  end

  test "power thermal gui action updates resource pressure and broadcasts the event", %{
    sidebar_registry: table
  } do
    registry = power_thermal_events_registry()
    start_supervised!({Events, name: registry})
    Events.subscribe(:power_thermal_state_changed, registry: registry)

    state = %{base_state(table) | events_registry: registry}

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

  describe "agent chat pin intents (#2654)" do
    alias MingaEditor.Agent.UIState
    alias MingaEditor.State.AgentAccess

    test "chat_scrolled_away_from_bottom unpins without moving the offset", %{
      sidebar_registry: table
    } do
      # Seed a pinned scroll that sits at a concrete offset so the test can prove
      # the offset a round-trip frontend relies on is left untouched.
      seeded =
        base_state(table)
        |> AgentAccess.update_agent_ui(fn ui ->
          %{
            ui
            | panel: %{
                ui.panel
                | scroll: Minga.Editing.set_pinned(Minga.Editing.Scroll.new(5), true)
              }
          }
        end)

      assert AgentAccess.agent_ui(seeded).panel.scroll.pinned == true

      scrolled = GuiActionHandler.dispatch(seeded, :chat_scrolled_away_from_bottom)
      scroll = AgentAccess.agent_ui(scrolled).panel.scroll

      assert scroll.pinned == false
      assert scroll.offset == 5
    end

    test "chat_returned_to_bottom re-pins without moving the offset", %{sidebar_registry: table} do
      seeded =
        base_state(table)
        |> AgentAccess.update_agent_ui(fn ui ->
          %{ui | panel: %{ui.panel | scroll: Minga.Editing.Scroll.new(9)}}
        end)

      assert AgentAccess.agent_ui(seeded).panel.scroll.pinned == false

      returned = GuiActionHandler.dispatch(seeded, :chat_returned_to_bottom)
      scroll = AgentAccess.agent_ui(returned).panel.scroll

      assert scroll.pinned == true
      assert scroll.offset == 9
    end

    test "UIState.set_pinned toggles the pin flag without touching the offset" do
      state = UIState.new()
      unpinned = %{state | panel: %{state.panel | scroll: Minga.Editing.Scroll.new(3)}}

      assert UIState.set_pinned(unpinned, true).panel.scroll == %{
               unpinned.panel.scroll
               | pinned: true
             }

      assert UIState.set_pinned(unpinned, true).panel.scroll.offset == 3
    end
  end

  defp base_state(sidebar_registry, opts \\ []) do
    opts = Keyword.put(opts, :sidebar_registry, sidebar_registry)
    state = TestHelpers.base_state(opts)

    case Keyword.fetch(opts, :agent_semantic_ui_registry) do
      {:ok, registry} -> EditorState.put_agent_semantic_ui_registry(state, registry)
      :error -> state
    end
  end

  defp clear_window_reset_pending(state), do: state

  defp power_thermal_events_registry do
    :"power_thermal_events_#{System.unique_integer([:positive])}"
  end
end
