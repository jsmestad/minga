defmodule MingaEditor.FeatureStateTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.FeatureState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport

  @source {:extension, :fake_feature}
  @other_source {:extension, :other_feature}
  @feature :sidebar

  test "stores reads updates and drops source-owned feature state" do
    state = FeatureState.new()

    assert FeatureState.get(state, @source, @feature) == nil
    assert FeatureState.get(state, @source, @feature, %{visible?: false}) == %{visible?: false}

    state = FeatureState.put(state, @source, @feature, %{visible?: true, row: 1})
    assert FeatureState.get(state, @source, @feature) == %{visible?: true, row: 1}
    assert FeatureState.member?(state, @source, @feature)

    state = FeatureState.put(state, @source, @feature, %{visible?: true, row: 2})
    assert FeatureState.get(state, @source, @feature) == %{visible?: true, row: 2}

    state = FeatureState.drop(state, @source, @feature)
    assert FeatureState.get(state, @source, @feature) == nil
    assert FeatureState.empty?(state)
  end

  test "source cleanup removes only matching source entries" do
    state =
      FeatureState.new()
      |> FeatureState.put(@source, :sidebar, :owned_sidebar)
      |> FeatureState.put(@source, :panel, :owned_panel)
      |> FeatureState.put(@other_source, :sidebar, :other_sidebar)
      |> FeatureState.drop_source(@source)

    assert FeatureState.get(state, @source, :sidebar) == nil
    assert FeatureState.get(state, @source, :panel) == nil
    assert FeatureState.get(state, @other_source, :sidebar) == :other_sidebar
  end

  test "invalid sources and feature ids are ignored" do
    state =
      FeatureState.new()
      |> FeatureState.put({:extension, "unsafe"}, @feature, :bad_source)
      |> FeatureState.put(@source, nil, :bad_feature)

    assert FeatureState.empty?(state)
    assert FeatureState.get(state, {:extension, "unsafe"}, @feature) == nil
    assert FeatureState.get(state, @source, nil) == nil
  end

  test "tab context carries every session workspace field" do
    workspace_fields =
      SessionState.__struct__()
      |> Map.delete(:__struct__)
      |> Map.keys()

    # Every workspace field is either snapshotted per tab (TabContext.field_names/0)
    # or an explicit, documented transient exclusion (TabContext.transient_fields/0,
    # e.g. the #2630 Cmd/Ctrl-hover link). A new NON-transient field that is added
    # to neither will fail this guard, which is the point.
    accounted_fields = TabContext.field_names() ++ TabContext.transient_fields()

    assert Enum.sort(accounted_fields) == Enum.sort(workspace_fields)
  end

  test "session helpers keep feature state scoped to tab snapshots" do
    tab_one =
      workspace()
      |> SessionState.put_feature_state(@source, @feature, %{selected: "one"})
      |> SessionState.to_tab_context()

    tab_two =
      workspace()
      |> SessionState.put_feature_state(@source, @feature, %{selected: "two"})
      |> SessionState.to_tab_context()

    restored_one = SessionState.restore_tab_context(workspace(), tab_one)
    restored_two = SessionState.restore_tab_context(workspace(), tab_two)

    assert SessionState.get_feature_state(restored_one, @source, @feature) == %{selected: "one"}
    assert SessionState.get_feature_state(restored_two, @source, @feature) == %{selected: "two"}
  end

  test "editor cleanup removes source-owned feature state from live and snapshotted workspaces" do
    live_workspace =
      workspace()
      |> SessionState.put_feature_state(@source, @feature, :live_owned)
      |> SessionState.put_feature_state(@other_source, @feature, :live_other)

    tab_context =
      workspace()
      |> SessionState.put_feature_state(@source, @feature, :tab_owned)
      |> SessionState.put_feature_state(@other_source, @feature, :tab_other)
      |> SessionState.to_tab_context()

    tab = Tab.new_file(1, "one") |> Tab.set_context(tab_context)
    tab_bar = TabBar.new(tab)
    shell_state = %ShellState{tab_bar: tab_bar}

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: live_workspace,
      shell_runtime: Runtime.new(Runtime.default_entry(), shell_state)
    }

    cleaned = MingaEditor.FeatureStateWorkflow.drop_source(state, @source)

    assert MingaEditor.Session.State.get_feature_state(cleaned.workspace, @source, @feature) ==
             nil

    assert MingaEditor.Session.State.get_feature_state(cleaned.workspace, @other_source, @feature) ==
             :live_other

    cleaned_tab = TabBar.get(cleaned.shell_runtime.state.tab_bar, 1)
    restored = SessionState.restore_tab_context(workspace(), cleaned_tab.context)

    assert SessionState.get_feature_state(restored, @source, @feature) == nil
    assert SessionState.get_feature_state(restored, @other_source, @feature) == :tab_other
  end

  test "config reload command cleans old config and extension state before loading replacements" do
    live_workspace =
      workspace()
      |> SessionState.put_feature_state(:config, @feature, :old_config)
      |> SessionState.put_feature_state(@source, @feature, :old_extension)
      |> SessionState.put_feature_state(@other_source, @feature, :old_other_extension)
      |> SessionState.put_feature_state(:builtin, @feature, :builtin)

    tab_context =
      workspace()
      |> SessionState.put_feature_state(:config, @feature, :tab_config)
      |> SessionState.put_feature_state(@source, @feature, :tab_extension)
      |> SessionState.put_feature_state(:builtin, @feature, :tab_builtin)
      |> SessionState.to_tab_context()

    tab = Tab.new_file(1, "one") |> Tab.set_context(tab_context)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: live_workspace,
      shell_runtime: Runtime.new(Runtime.default_entry(), %ShellState{tab_bar: TabBar.new(tab)})
    }

    reloaded =
      BufferManagement.reload_config(state, fn cleaned_state ->
        assert MingaEditor.Session.State.get_feature_state(
                 cleaned_state.workspace,
                 :config,
                 @feature
               ) == nil

        assert MingaEditor.Session.State.get_feature_state(
                 cleaned_state.workspace,
                 @source,
                 @feature
               ) == nil

        assert MingaEditor.Session.State.get_feature_state(
                 cleaned_state.workspace,
                 @other_source,
                 @feature
               ) == nil

        assert MingaEditor.Session.State.get_feature_state(
                 cleaned_state.workspace,
                 :builtin,
                 @feature
               ) == :builtin

        cleaned_tab = TabBar.get(cleaned_state.shell_runtime.state.tab_bar, 1)

        assert_snapshot_feature_state(cleaned_tab.context,
          config: nil,
          extension: nil,
          builtin: :tab_builtin
        )

        cleaned_state =
          then(cleaned_state, fn state ->
            %{
              state
              | workspace:
                  then(
                    state.workspace,
                    &MingaEditor.Session.State.put_feature_state(
                      &1,
                      :config,
                      @feature,
                      :new_config
                    )
                  )
            }
          end)

        {:ok,
         then(cleaned_state, fn state ->
           %{
             state
             | workspace:
                 then(
                   state.workspace,
                   &MingaEditor.Session.State.put_feature_state(
                     &1,
                     @source,
                     @feature,
                     :new_extension
                   )
                 )
           }
         end)}
      end)

    assert MingaEditor.Session.State.get_feature_state(reloaded.workspace, :config, @feature) ==
             :new_config

    assert MingaEditor.Session.State.get_feature_state(reloaded.workspace, @source, @feature) ==
             :new_extension

    assert MingaEditor.Session.State.get_feature_state(
             reloaded.workspace,
             @other_source,
             @feature
           ) == nil

    assert MingaEditor.Session.State.get_feature_state(reloaded.workspace, :builtin, @feature) ==
             :builtin

    reloaded_tab = TabBar.get(reloaded.shell_runtime.state.tab_bar, 1)

    assert_snapshot_feature_state(reloaded_tab.context,
      config: nil,
      extension: nil,
      builtin: :tab_builtin
    )
  end

  test "brand-new tab defaults do not inherit outgoing feature state" do
    live_workspace = SessionState.put_feature_state(workspace(), @source, @feature, :outgoing)
    tab_bar = TabBar.new(Tab.new_file(1, "new"))
    shell_state = %ShellState{tab_bar: tab_bar}

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: live_workspace,
      shell_runtime: Runtime.new(Runtime.default_entry(), shell_state)
    }

    restored = EditorState.restore_tab_context(state, TabContext.empty())

    assert MingaEditor.Session.State.get_feature_state(restored.workspace, @source, @feature) ==
             nil
  end

  test "agent tab defaults do not inherit outgoing feature state" do
    live_workspace = SessionState.put_feature_state(workspace(), @source, @feature, :outgoing)
    tab_bar = TabBar.new(Tab.new_agent(1, "agent"))
    shell_state = %ShellState{tab_bar: tab_bar}

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: live_workspace,
      shell_runtime: Runtime.new(Runtime.default_entry(), shell_state)
    }

    context =
      MingaEditor.State.Tab.Context.new_agent(
        state.frontend.terminal_viewport,
        state.workspace.file_tree.project_root,
        %MingaEditor.State.Windows{}
      )

    restored = SessionState.restore_tab_context(live_workspace, context)

    assert SessionState.get_feature_state(restored, @source, @feature) == nil
  end

  test "cleanup preserves empty tab context semantics" do
    tab = Tab.new_file(1, "empty")

    cleaned = Tab.drop_feature_state_source(tab, @source)

    assert cleaned.context == TabContext.empty()
    assert TabContext.empty?(cleaned.context)
  end

  test "missing state helpers are safe defaults for inactive features" do
    ws = workspace()

    assert SessionState.get_feature_state(ws, @source, @feature) == nil

    assert SessionState.get_feature_state(ws, @source, @feature, %{active?: false}) == %{
             active?: false
           }

    assert SessionState.drop_feature_state(ws, @source, @feature) == ws
  end

  test "hot-path access is a pure map lookup on the workspace snapshot" do
    ws = SessionState.put_feature_state(workspace(), @source, @feature, :cached)
    assert SessionState.get_feature_state(ws, @source, @feature) == :cached
    assert_received_messages([])
  end

  @spec workspace() :: SessionState.t()
  defp workspace do
    %SessionState{viewport: Viewport.new(24, 80)}
  end

  @spec assert_snapshot_feature_state(TabContext.t(), keyword()) :: :ok
  defp assert_snapshot_feature_state(context, expected) do
    restored = SessionState.restore_tab_context(workspace(), context)

    assert SessionState.get_feature_state(restored, :config, @feature) ==
             Keyword.fetch!(expected, :config)

    assert SessionState.get_feature_state(restored, @source, @feature) ==
             Keyword.fetch!(expected, :extension)

    assert SessionState.get_feature_state(restored, :builtin, @feature) ==
             Keyword.fetch!(expected, :builtin)
  end

  @spec assert_received_messages([term()]) :: :ok
  defp assert_received_messages(expected) do
    assert Process.info(self(), :messages) == {:messages, expected}
    :ok
  end
end
