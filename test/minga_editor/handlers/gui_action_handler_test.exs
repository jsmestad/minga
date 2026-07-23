defmodule MingaEditor.Handlers.GuiActionHandlerTest do
  @moduledoc """
  Pure-function tests for `MingaEditor.Handlers.GuiActionHandler`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Events
  alias Minga.Extension.CodeLease
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias MingaEditor.BottomPanel
  alias MingaEditor.Agent.SemanticUI.Registry, as: SemanticUIRegistry
  alias MingaEditor.Commands
  alias MingaEditor.Editing
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderModel.UI.SidebarsBuilder
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Test.SidebarActionProbe
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Window
  alias MingaEditor.State.ExtensionSurfaces
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Persistence, as: WorkspacePersistence
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter
  alias MingaEditor.UI.Popup.Active, as: PopupActive
  alias Minga.Popup.Rule
  alias Minga.Project.FileTree, as: ProjectFileTree
  alias MingaEditor.WorkspaceWorkflow

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    semantic_table = Module.concat(__MODULE__, "SemanticUI#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    start_supervised!({SemanticUIRegistry, name: semantic_table, notify: false})
    %{sidebar_registry: table, semantic_registry: semantic_table}
  end

  test "scroll_to_line is state-only and outer housekeeping submits exactly one render", %{
    sidebar_registry: table
  } do
    state = base_state(table, backend: :gui)
    state = %{state | render: MingaEditor.State.Render.connect_renderer(state.render, self())}
    snapshot = MingaEditor.Input.Router.capture_snapshot(state)
    revision = state.render.render_correlation.latest_intent_revision

    handled = GuiActionHandler.dispatch(state, {:scroll_to_line, 1})

    assert handled.render.render_correlation.latest_intent_revision == revision

    window = Map.fetch!(handled.workspace.windows.map, handled.workspace.windows.active)
    assert window.viewport.top == 1
    assert window.scroll_echo_top == 1
    assert window.scroll_detach_cursor == {0, 0}
    refute_receive {:"$gen_cast", {:render, _, _, _}}, 0

    rendered = MingaEditor.Input.Router.post_action_housekeeping(handled, snapshot)

    assert rendered.render.render_correlation.latest_intent_revision == revision + 1

    assert_receive {:"$gen_cast",
                    {:render, %MingaEditor.RenderPipeline.Intent{}, _seq, _pushed_at}}

    refute_receive {:"$gen_cast", {:render, _, _, _}}, 0
  end

  test "notification dismiss removes only the selected notification", %{sidebar_registry: table} do
    state =
      table
      |> base_state()
      |> then(fn state ->
        %{
          state
          | feedback:
              MingaEditor.State.Feedback.upsert_notification(
                state.feedback,
                Notification.new(
                  id: "build:test",
                  level: :progress,
                  title: "Building Minga",
                  created_at: 1_715_000_000
                )
              )
        }
      end)
      |> then(fn state ->
        %{
          state
          | feedback:
              MingaEditor.State.Feedback.upsert_notification(
                state.feedback,
                Notification.new(
                  id: "other",
                  level: :info,
                  title: "Still here",
                  created_at: 1_715_000_010
                )
              )
        }
      end)

    state = GuiActionHandler.dispatch(state, {:notification_dismiss, "build:test"})

    assert NotificationCenter.find(state.feedback.notifications, "build:test") == nil
    assert [%{id: "other"}] = NotificationCenter.list(state.feedback.notifications)
  end

  test "legacy breadcrumb_click is ignored without mutating state", %{sidebar_registry: table} do
    state = base_state(table)

    assert GuiActionHandler.dispatch(state, {:breadcrumb_click, 0}) == state
  end

  test "panel_switch_tab is an explicit no-op", %{sidebar_registry: table} do
    panel = %BottomPanel{visible: true, focused: true, filter: :warnings, height_percent: 45}

    state =
      base_state(table)
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_bottom_panel(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            panel
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    assert GuiActionHandler.dispatch(state, {:panel_switch_tab, 255}).shell_runtime.state.bottom_panel ==
             panel
  end

  test "panel_dismiss hides the panel through the owner", %{sidebar_registry: table} do
    panel = %BottomPanel{visible: true, focused: true, filter: :warnings, height_percent: 45}

    state =
      base_state(table)
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_bottom_panel(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            panel
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    new_panel = GuiActionHandler.dispatch(state, :panel_dismiss).shell_runtime.state.bottom_panel

    assert new_panel.visible == false
    assert new_panel.focused == false
    assert new_panel.filter == :warnings
    assert new_panel.height_percent == 45
  end

  test "panel_resize clamps through the owner", %{sidebar_registry: table} do
    state = base_state(table)

    low_panel =
      GuiActionHandler.dispatch(state, {:panel_resize, 5}).shell_runtime.state.bottom_panel

    high_panel =
      GuiActionHandler.dispatch(state, {:panel_resize, 80}).shell_runtime.state.bottom_panel

    assert low_panel.height_percent == 10
    assert high_panel.height_percent == 60
  end

  test "tab context actions target the requested tab without selecting it", %{
    sidebar_registry: table
  } do
    tab1 = Tab.new_file(1, "a.ex")
    tab2 = Tab.new_file(2, "b.ex")
    tab3 = Tab.new_file(3, "c.ex")
    tab_bar = %TabBar{tabs: [tab1, tab2, tab3], active_id: 1, next_id: 4}

    state =
      base_state(table)
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    pinned = GuiActionHandler.dispatch(state, {:tab_pin, 3})
    pinned_tab_bar = pinned.shell_runtime.state.tab_bar

    assert pinned_tab_bar.active_id == 1
    assert TabBar.get(pinned_tab_bar, 3).pinned?
    assert Enum.map(TabBar.visible_file_tabs(pinned_tab_bar), & &1.id) == [3, 1, 2]

    moved = GuiActionHandler.dispatch(pinned, {:tab_move_left, 2})
    moved_tab_bar = moved.shell_runtime.state.tab_bar

    assert moved_tab_bar.active_id == 1
    assert Enum.map(TabBar.visible_file_tabs(moved_tab_bar), & &1.id) == [3, 2, 1]

    unpinned = GuiActionHandler.dispatch(moved, {:tab_unpin, 3})
    unpinned_tab_bar = unpinned.shell_runtime.state.tab_bar

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

    state =
      base_state(table)
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    switched = GuiActionHandler.dispatch(state, {:execute_command, "workspace_goto_id:7"})

    assert switched.shell_runtime.state.tab_bar.active_id == 2
    assert TabBar.active_workspace_id(switched.shell_runtime.state.tab_bar) == 7
  end

  test "activating visible sidebars updates focus and keyboard scope", %{sidebar_registry: table} do
    file_tree_state = %FileTreeState{tree_status: :loading, visibility: :visible}

    state = base_state(table)
    state = %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree_state)}

    file_tree_active =
      GuiActionHandler.dispatch(state, {:sidebar_action, "file_tree", "renamed_kind", "activate"})

    assert file_tree_active.workspace.file_tree.visibility == :focused
    assert file_tree_active.workspace.keymap_scope == :file_tree
    assert SidebarWorkflow.active_id(file_tree_active) == "file_tree"

    git_state = SidebarWorkflow.replace_git_status(state, GitStatusPanel.new(%{entries: []}))

    assert %{visible?: true, focused?: false} = Sidebar.get(table, "git_status")

    git_active =
      GuiActionHandler.dispatch(
        git_state,
        {:sidebar_action, "git_status", "renamed_kind", "activate"}
      )

    assert git_active.workspace.keymap_scope == :git_status
    assert SidebarWorkflow.active_id(git_active) == "git_status"
    assert Sidebar.get(table, "git_status").focused?

    observatory_state =
      state
      |> SidebarWorkflow.open_observatory(nil)
      |> then(fn current ->
        %{current | workspace: SessionState.set_keymap_scope(current.workspace, :file_tree)}
      end)

    observatory_active =
      GuiActionHandler.dispatch(
        observatory_state,
        {:sidebar_action, "observatory", "observatory", "activate"}
      )

    refute FileTreeState.focused?(observatory_active.workspace.file_tree)
    assert observatory_active.workspace.keymap_scope == :editor
    assert SidebarWorkflow.active_id(observatory_active) == "observatory"
  end

  @tag :tmp_dir
  test "native GUI file tree sidebar actions use the registered FileTree action handler", %{
    sidebar_registry: table,
    tmp_dir: tmp_dir
  } do
    assert :ok = FileTreeFeature.sync_sidebar(%FileTreeState{}, table)

    state = base_state(table)

    file_tree = %FileTreeState{
      tree: ProjectFileTree.new(tmp_dir),
      tree_status: :ready,
      visibility: :hidden
    }

    state = %{state | workspace: SessionState.set_file_tree(state.workspace, file_tree)}

    opened =
      GuiActionHandler.dispatch(state, {:sidebar_action, "file_tree", "file_tree", "toggle"})

    assert opened.workspace.file_tree.tree != nil
    assert FileTreeState.focused?(opened.workspace.file_tree)
    assert SidebarWorkflow.active_id(opened) == "file_tree"
    assert %{visible?: true, focused?: true} = Sidebar.get(table, "file_tree")

    assert %{active_id: "file_tree", sidebars: [%{visible?: true, focused?: true}]} =
             SidebarsBuilder.build(Context.from_editor_state(opened))

    focused =
      GuiActionHandler.dispatch(
        %{opened | workspace: %{opened.workspace | keymap_scope: :editor}},
        {:sidebar_action, "file_tree", "file_tree", "activate"}
      )

    assert FileTreeState.focused?(focused.workspace.file_tree)
    assert focused.workspace.keymap_scope == :file_tree
    assert SidebarWorkflow.active_id(focused) == "file_tree"

    hidden =
      GuiActionHandler.dispatch(focused, {:sidebar_action, "file_tree", "file_tree", "toggle"})

    # Toggling off now hides the sidebar without tearing down the tree (#2626):
    # the data stays loaded so re-showing is a pure layout change, but the
    # sidebar is no longer visible/focused and its contribution is deregistered.
    hidden_state = hidden.workspace.file_tree
    assert hidden_state.tree != nil
    refute FileTreeState.visible?(hidden_state)
    refute FileTreeState.focused?(hidden_state)
    assert SidebarWorkflow.active_id(hidden) == nil
    assert %{visible?: false, focused?: false} = Sidebar.get(table, "file_tree")

    assert %{active_id: "", sidebars: [%{visible?: false, focused?: false}]} =
             SidebarsBuilder.build(Context.from_editor_state(hidden))
  end

  test "optional GUI commands report scheduling failures instead of no-op", %{
    sidebar_registry: table
  } do
    state = base_state(table)

    toggled = GuiActionHandler.dispatch(state, {:toggle_panel, 2})

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(toggled) ==
             "Git command not scheduled: :scheduler_unavailable"

    assert toggled.workspace.keymap_scope == state.workspace.keymap_scope
    assert SidebarWorkflow.active_id(toggled) == SidebarWorkflow.active_id(state)

    activated =
      GuiActionHandler.dispatch(state, {:sidebar_action, "git_status", "git_status", "activate"})

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(activated) ==
             "Git command not scheduled: :scheduler_unavailable"

    assert activated.workspace.keymap_scope == state.workspace.keymap_scope
    assert SidebarWorkflow.active_id(activated) == nil
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

        assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
                 "Extension panel action unavailable"
      end)

    assert log =~ "Extension panel action ignored"
    assert log =~ "missing_extension_for_gui_action/refresh"
  end

  test "font size actions mark retained window state reset-pending", %{sidebar_registry: table} do
    state = table |> base_state() |> clear_window_reset_pending()

    new_state = GuiActionHandler.dispatch(state, {:font_size_adjust, :increase})

    assert new_state.appearance.font_size_override != nil

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

    assert new_state.appearance.font_size_override == nil

    assert Enum.all?(Map.values(new_state.workspace.windows.map), fn %Window{} = window ->
             match?(%MingaEditor.Window.RenderCache{}, window.render_cache)
           end)
  end

  test "native GUI sidebar actions route to extension-owned sidebars", %{sidebar_registry: table} do
    source = {:extension, :gui_action_test}
    :ok = CodeLease.activate_source(source, [SidebarActionProbe])

    on_exit(fn ->
      {:ok, token} = CodeLease.quiesce_source(source)
      CodeLease.complete_unload(token)
    end)

    assert :ok =
             Sidebar.register(table, source, %{
               id: "outline",
               display_name: "Outline",
               action_handler: {SidebarActionProbe, :publish_notice}
             })

    state = base_state(table)

    new_state =
      GuiActionHandler.dispatch(state, {:sidebar_action, "outline", "generic_tree", "activate"})

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
             "activate:generic_tree"
  end

  test "unknown sidebar action is reported instead of silently ignored", %{
    sidebar_registry: table
  } do
    state = base_state(table)

    log =
      capture_log(fn ->
        new_state =
          GuiActionHandler.dispatch(state, {:sidebar_action, "custom", "custom_kind", "toggle"})

        assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
                 "Unsupported sidebar action: custom_kind/toggle"
      end)

    assert log =~ "Ignored sidebar action"
    assert log =~ "custom_kind"
  end

  test "command-opened observatory replaces stale active sidebar id", %{sidebar_registry: table} do
    state = base_state(table)

    frontend =
      FrontendState.accept_capabilities(
        state.frontend,
        %Capabilities{frontend_type: :native_gui, semantic_ui: true}
      )

    file_tree = state.workspace.file_tree |> FileTreeState.loading() |> FileTreeState.focus()

    workspace =
      state.workspace
      |> SessionState.set_file_tree(file_tree)
      |> SessionState.set_keymap_scope(:file_tree)

    state =
      %{state | frontend: frontend, workspace: workspace}
      |> SidebarWorkflow.select("git_status")

    new_state = Commands.execute(state, :toggle_beam_observatory)

    assert SidebarWorkflow.active_id(new_state) == "observatory"
    assert SidebarWorkflow.observatory_visible?(new_state)
    refute FileTreeState.focused?(new_state.workspace.file_tree)
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

    state = base_state(table) |> SidebarWorkflow.inspect_observatory(inspection)

    new_state = GuiActionHandler.dispatch(state, :float_popup_dismiss)

    assert new_state |> SidebarWorkflow.observatory() |> Observatory.inspection() == nil
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
        | popup_meta: PopupActive.new(Rule.new("*Help*", display: :float), main_id)
      }

    state =
      %{
        state
        | workspace:
            MingaEditor.Session.State.set_windows(
              state.workspace,
              then(state.workspace.windows, fn windows ->
                %{
                  windows
                  | map: Map.put(windows.map, popup_id, popup_window),
                    active: popup_id,
                    next_id: popup_id + 1
                }
              end)
            )
      }

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

    state = base_state(table)

    state = %{
      state
      | extension_surfaces:
          ExtensionSurfaces.install_events_registry(state.extension_surfaces, registry)
    }

    assert {:ok, {:power_thermal_state, true, {:unknown, 255}}} =
             ProtocolGUI.decode_gui_action(0x47, <<1, 255>>)

    new_state = GuiActionHandler.dispatch(state, {:power_thermal_state, true, {:unknown, 255}})

    assert new_state.frontend.resource_pressure ==
             ResourcePressure.update(ResourcePressure.new(), true, {:unknown, 255})

    assert_receive {:minga_event, :power_thermal_state_changed,
                    %Events.PowerThermalStateEvent{
                      low_power?: true,
                      thermal_state: {:unknown, 255}
                    }}
  end

  describe "agent chat pin intents (#2654)" do
    alias MingaEditor.Agent.UIState

    test "chat_scrolled_away_from_bottom unpins without moving the offset", %{
      sidebar_registry: table
    } do
      # Seed a pinned scroll that sits at a concrete offset so the test can prove
      # the offset a round-trip frontend relies on is left untouched.
      seeded =
        base_state(table)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (fn ui ->
               %{
                 ui
                 | panel: %{
                     ui.panel
                     | scroll: Minga.Editing.set_pinned(Minga.Editing.Scroll.new(5), true)
                   }
               }
             end).(state.workspace.agent_ui)
          )
        end)

      assert seeded.workspace.agent_ui.panel.scroll.pinned == true

      scrolled = GuiActionHandler.dispatch(seeded, :chat_scrolled_away_from_bottom)
      scroll = scrolled.workspace.agent_ui.panel.scroll

      assert scroll.pinned == false
      assert scroll.offset == 5
    end

    test "chat_returned_to_bottom re-pins without moving the offset", %{
      sidebar_registry: table
    } do
      seeded =
        base_state(table)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (fn ui -> %{ui | panel: %{ui.panel | scroll: Minga.Editing.Scroll.new(9)}} end).(
              state.workspace.agent_ui
            )
          )
        end)

      assert seeded.workspace.agent_ui.panel.scroll.pinned == false

      returned = GuiActionHandler.dispatch(seeded, :chat_returned_to_bottom)
      scroll = returned.workspace.agent_ui.panel.scroll

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

  @tag :tmp_dir
  test "GUI workspace close, rename, and icon actions persist their durable transitions", %{
    sidebar_registry: table,
    tmp_dir: root
  } do
    state = base_state(table)
    initial_tab_bar = state.shell_runtime.state.tab_bar || TabBar.new(Tab.new_file(1, "file.ex"))
    {tab_bar, workspace} = TabBar.add_workspace(initial_tab_bar, "Agent")
    workspace = Workspace.with_project_root(workspace, root)
    tab_bar = TabBar.accept_workspace(tab_bar, workspace)
    state = WorkspaceWorkflow.install_tab_bar(state, tab_bar)
    path = WorkspacePersistence.path_for(root, workspace.id)
    assert :ok = WorkspacePersistence.write(workspace, root)
    assert File.exists?(path)

    renamed = GuiActionHandler.dispatch(state, {:workspace_rename, workspace.id, "Renamed"})
    assert {:ok, persisted} = WorkspacePersistence.read(path, root)
    assert persisted.label == "Renamed"

    assert TabBar.get_workspace(renamed.shell_runtime.state.tab_bar, workspace.id).label ==
             "Renamed"

    reiconed = GuiActionHandler.dispatch(renamed, {:workspace_set_icon, workspace.id, "sparkles"})
    assert {:ok, persisted} = WorkspacePersistence.read(path, root)
    assert persisted.icon == "sparkles"

    assert TabBar.get_workspace(reiconed.shell_runtime.state.tab_bar, workspace.id).icon ==
             "sparkles"

    closed = GuiActionHandler.dispatch(reiconed, {:workspace_close, workspace.id})
    refute File.exists?(path)
    refute TabBar.get_workspace(closed.shell_runtime.state.tab_bar, workspace.id)
  end

  @tag :tmp_dir
  test "GUI persistence errors are logged without rolling back visible state", %{
    sidebar_registry: table,
    tmp_dir: root
  } do
    invalid_root = Path.join(root, "missing")
    state = base_state(table)
    initial_tab_bar = state.shell_runtime.state.tab_bar || TabBar.new(Tab.new_file(1, "file.ex"))
    {tab_bar, workspace} = TabBar.add_workspace(initial_tab_bar, "Agent")
    workspace = Workspace.with_project_root(workspace, invalid_root)
    tab_bar = TabBar.accept_workspace(tab_bar, workspace)

    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        Runtime.state(state.shell_runtime),
        tab_bar
      )

    state = %{
      state
      | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }

    parent = self()

    log =
      capture_log(fn ->
        result = GuiActionHandler.dispatch(state, {:workspace_rename, workspace.id, "Visible"})
        send(parent, {:gui_persistence_result, result})
      end)

    assert_receive {:gui_persistence_result, result}

    assert TabBar.get_workspace(result.shell_runtime.state.tab_bar, workspace.id).label ==
             "Visible"

    assert log =~ "Workspace persistence write failed"
    assert log =~ "invalid_project_root"
  end

  defp base_state(sidebar_registry, opts \\ []) do
    opts = Keyword.put(opts, :sidebar_registry, sidebar_registry)
    state = TestHelpers.base_state(opts)

    case Keyword.fetch(opts, :agent_semantic_ui_registry) do
      {:ok, registry} ->
        %{
          state
          | extension_surfaces:
              MingaEditor.State.ExtensionSurfaces.install_agent_semantic_ui_registry(
                state.extension_surfaces,
                registry
              )
        }

      :error ->
        state
    end
  end

  defp clear_window_reset_pending(state), do: state

  defp power_thermal_events_registry do
    :"power_thermal_events_#{System.unique_integer([:positive])}"
  end
end
