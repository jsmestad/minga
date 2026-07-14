defmodule MingaEditor.Shell.Traditional.StateTest do
  use ExUnit.Case, async: true

  alias MingaEditor.BottomPanel
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.Shell.Traditional.Notice
  alias MingaEditor.Shell.Traditional.State
  alias MingaEditor.SignatureHelp
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  test "exact child installers replace only their owned Traditional fields" do
    original_notice = Notice.publish(%Notice{}, "keep")
    state = %State{notice: original_notice}
    panel = %BottomPanel{visible: true}
    tab_bar = TabBar.new(Tab.new_file(1, "one.ex"))

    state = State.install_bottom_panel(state, panel)
    assert State.bottom_panel(state) == panel
    assert state.notice == original_notice

    state = State.install_tab_bar(state, tab_bar)
    assert State.tab_bar(state) == tab_bar
    assert state.bottom_panel == panel

    cleared = State.install_tab_bar(state, nil)
    assert State.tab_bar(cleared) == nil
    assert cleared.notice == original_notice
  end

  test "child installers reject foreign roots and legacy map-shaped values" do
    panel = %BottomPanel{}
    tab_bar = TabBar.new(Tab.new_file(1, "one.ex"))

    assert_raise FunctionClauseError, fn ->
      invoke(State, :install_bottom_panel, [%{}, panel])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(State, :install_bottom_panel, [%State{}, %{}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(State, :install_tab_bar, [%{}, tab_bar])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(State, :install_tab_bar, [%State{}, %{tabs: []}])
    end

    refute function_exported?(State, :set_bottom_panel, 2)
    refute function_exported?(State, :set_tab_bar, 2)
  end

  test "signature help and Git status accept only concrete owner values" do
    signature_help = %SignatureHelp{
      signatures: [],
      active_signature: 0,
      active_parameter: 0,
      anchor_row: 0,
      anchor_col: 0
    }

    state = State.show_signature_help(%State{}, signature_help)
    assert state.signature_help == signature_help

    panel = GitStatusPanel.new(%{entries: []})
    state = State.replace_git_status_panel(state, panel)
    assert State.git_status_panel(state) == panel

    assert_raise FunctionClauseError, fn ->
      invoke(State, :show_signature_help, [state, %{}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(State, :replace_git_status_panel, [state, %{entries: []}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(State, :replace_git_status_tui_state, [state, %{cursor_index: 0}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(State, :replace_git_status_tui_state, [state, %URI{path: "/foreign"}])
    end
  end

  test "agent and inline installers reject legacy map-shaped values" do
    state = %State{}

    assert_raise FunctionClauseError, fn -> invoke(State, :replace_agent, [state, %{}]) end
    assert_raise FunctionClauseError, fn -> invoke(State, :activate_inline_ask, [state, %{}]) end
    assert_raise FunctionClauseError, fn -> invoke(State, :replace_inline_ask, [state, %{}]) end
    assert_raise FunctionClauseError, fn -> invoke(State, :activate_inline_edit, [state, %{}]) end
    assert_raise FunctionClauseError, fn -> invoke(State, :replace_inline_edit, [state, %{}]) end

    assert_raise FunctionClauseError, fn ->
      invoke(State, :replace_tool_prompts, [state, [], []])
    end
  end

  test "flash replacement rejects broad positions and range atoms" do
    state = State.replace_yank_flash(%State{}, self(), {1, 2}, {3, 4}, :charwise)
    assert state.flashes.yank.start_pos == {1, 2}
    assert state.flashes.yank.end_pos == {3, 4}
    assert state.flashes.yank.range_type == :charwise

    assert_raise FunctionClauseError, fn ->
      invoke(State, :replace_yank_flash, [state, self(), %{line: 1}, {3, 4}, :charwise])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(State, :replace_yank_flash, [state, self(), {1, 2}, {3, 4}, :legacy_range])
    end
  end

  # The indirection lets runtime boundary tests pass intentionally invalid typed values.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp invoke(module, function, arguments), do: apply(module, function, arguments)
end
