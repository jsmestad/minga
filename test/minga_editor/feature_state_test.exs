defmodule MingaEditor.FeatureStateTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.FeatureState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Board.Card
  alias MingaEditor.Shell.Board.State, as: BoardState
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

    state = FeatureState.update(state, @source, @feature, %{}, &Map.put(&1, :row, 2))
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
      port_manager: self(),
      workspace: live_workspace,
      shell_state: shell_state
    }

    cleaned = EditorState.drop_feature_state_source(state, @source)

    assert EditorState.get_feature_state(cleaned, @source, @feature) == nil
    assert EditorState.get_feature_state(cleaned, @other_source, @feature) == :live_other

    cleaned_tab = TabBar.get(EditorState.tab_bar(cleaned), 1)
    restored = SessionState.restore_tab_context(workspace(), cleaned_tab.context)

    assert SessionState.get_feature_state(restored, @source, @feature) == nil
    assert SessionState.get_feature_state(restored, @other_source, @feature) == :tab_other
  end

  test "editor cleanup removes source-owned feature state from board card workspaces" do
    card_context =
      workspace()
      |> SessionState.put_feature_state(@source, @feature, :board_owned)
      |> SessionState.put_feature_state(@other_source, @feature, :board_other)
      |> SessionState.to_tab_context()

    stashed_context =
      workspace()
      |> SessionState.put_feature_state(@source, @feature, :stashed_owned)
      |> SessionState.put_feature_state(@other_source, @feature, :stashed_other)
      |> SessionState.to_tab_context()

    board = board_with_workspace(1, card_context)
    stashed_board = board_with_workspace(2, stashed_context)

    state = %EditorState{
      port_manager: self(),
      workspace: workspace(),
      shell_state: board,
      stashed_board_state: stashed_board
    }

    cleaned = EditorState.drop_feature_state_source(state, @source)

    cleaned_context = cleaned.shell_state.cards[1].workspace
    cleaned_stashed_context = cleaned.stashed_board_state.cards[2].workspace
    restored = SessionState.restore_tab_context(workspace(), cleaned_context)
    restored_stashed = SessionState.restore_tab_context(workspace(), cleaned_stashed_context)

    assert SessionState.get_feature_state(restored, @source, @feature) == nil
    assert SessionState.get_feature_state(restored, @other_source, @feature) == :board_other
    assert SessionState.get_feature_state(restored_stashed, @source, @feature) == nil

    assert SessionState.get_feature_state(restored_stashed, @other_source, @feature) ==
             :stashed_other
  end

  test "config reload command cleans old config and extension state before loading replacements" do
    live_workspace =
      workspace()
      |> SessionState.put_feature_state(:config, @feature, :old_config)
      |> SessionState.put_feature_state(@source, @feature, :old_extension)
      |> SessionState.put_feature_state(@other_source, @feature, :old_other_extension)
      |> SessionState.put_feature_state(:builtin, @feature, :builtin)

    state = %EditorState{port_manager: self(), workspace: live_workspace}

    reloaded =
      BufferManagement.reload_config(state, fn cleaned_state ->
        assert EditorState.get_feature_state(cleaned_state, :config, @feature) == nil
        assert EditorState.get_feature_state(cleaned_state, @source, @feature) == nil
        assert EditorState.get_feature_state(cleaned_state, @other_source, @feature) == nil
        assert EditorState.get_feature_state(cleaned_state, :builtin, @feature) == :builtin

        cleaned_state =
          EditorState.put_feature_state(cleaned_state, :config, @feature, :new_config)

        {:ok, EditorState.put_feature_state(cleaned_state, @source, @feature, :new_extension)}
      end)

    assert EditorState.get_feature_state(reloaded, :config, @feature) == :new_config
    assert EditorState.get_feature_state(reloaded, @source, @feature) == :new_extension
    assert EditorState.get_feature_state(reloaded, @other_source, @feature) == nil
    assert EditorState.get_feature_state(reloaded, :builtin, @feature) == :builtin
  end

  test "brand-new tab defaults do not inherit outgoing feature state" do
    live_workspace = SessionState.put_feature_state(workspace(), @source, @feature, :outgoing)
    tab_bar = TabBar.new(Tab.new_file(1, "new"))
    shell_state = %ShellState{tab_bar: tab_bar}

    state = %EditorState{
      port_manager: self(),
      workspace: live_workspace,
      shell_state: shell_state
    }

    restored = EditorState.restore_tab_context(state, TabContext.empty())

    assert EditorState.get_feature_state(restored, @source, @feature) == nil
  end

  test "agent tab defaults do not inherit outgoing feature state" do
    live_workspace = SessionState.put_feature_state(workspace(), @source, @feature, :outgoing)
    tab_bar = TabBar.new(Tab.new_agent(1, "agent"))
    shell_state = %ShellState{tab_bar: tab_bar}

    state = %EditorState{
      port_manager: self(),
      workspace: live_workspace,
      shell_state: shell_state
    }

    context = EditorState.build_agent_tab_defaults(state, %MingaEditor.State.Windows{}, nil)

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

  @spec board_with_workspace(Card.id(), map()) :: BoardState.t()
  defp board_with_workspace(card_id, workspace_snapshot) do
    card = Card.new(card_id, task: "card #{card_id}", workspace: workspace_snapshot)

    %BoardState{
      cards: %{card_id => card},
      card_order: [card_id],
      focused_card: card_id,
      next_id: card_id + 1
    }
  end

  @spec assert_received_messages([term()]) :: :ok
  defp assert_received_messages(expected) do
    assert Process.info(self(), :messages) == {:messages, expected}
    :ok
  end
end
