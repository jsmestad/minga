defmodule MingaEditor.Shell.Traditional.SidebarsTest do
  use ExUnit.Case, async: true

  alias MingaEditor.GitStatus.Panel
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.GitStatus.TUIState
  alias MingaEditor.Observatory.Data
  alias MingaEditor.Observatory.Inspection
  alias MingaEditor.Shell.Traditional.Observatory
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.Shell.Traditional.Sidebars
  alias MingaEditor.State, as: EditorState

  test "Git status close clears its selected surface and paired TUI state" do
    sidebars =
      %Sidebars{}
      |> Sidebars.replace_git_status(Panel.new(%{entries: []}))
      |> Sidebars.replace_git_status_tui(TUIState.new())
      |> Sidebars.select("git_status")

    closed = Sidebars.close_git_status(sidebars)

    assert Sidebars.active_id(closed) == nil
    assert Sidebars.git_status_panel(closed) == nil
    assert Sidebars.git_status_tui_state(closed) == nil
  end

  test "Git status workflow close clears shell state and registered visibility" do
    state =
      MingaEditor.RenderPipeline.TestHelpers.base_state()
      |> SidebarWorkflow.replace_git_status(Panel.new(%{entries: []}))
      |> SidebarWorkflow.select("git_status")

    table = state.extension_surfaces.sidebar_registry
    assert %{visible?: true, focused?: true} = Sidebar.get(table, "git_status")

    closed = SidebarWorkflow.close_git_status(state)

    assert SidebarWorkflow.git_status_panel(closed) == nil
    assert SidebarWorkflow.active_id(closed) == nil
    assert %{visible?: false, focused?: false, badge_count: 0} = Sidebar.get(table, "git_status")
  end

  test "Git status replacement rejects legacy map-shaped panel and TUI state" do
    editor_state = %EditorState{
      workspace: %MingaEditor.Session.State{viewport: MingaEditor.Viewport.new(24, 80)}
    }

    assert_raise FunctionClauseError, fn ->
      invoke(Sidebars, :replace_git_status, [%Sidebars{}, %{entries: []}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(Sidebars, :replace_git_status_tui, [%Sidebars{}, %{cursor_index: 0}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(Sidebars, :replace_git_status_tui, [%Sidebars{}, %URI{path: "/foreign"}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(SidebarWorkflow, :replace_git_status, [editor_state, %{entries: []}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(SidebarWorkflow, :replace_git_status_tui, [editor_state, %{cursor_index: 0}])
    end

    assert_raise FunctionClauseError, fn ->
      invoke(SidebarWorkflow, :replace_git_status_tui, [editor_state, %URI{path: "/foreign"}])
    end
  end

  test "closing Observatory clears every surface value and invalidates delayed work" do
    timer = make_ref()
    token = make_ref()
    data = Data.visible(nil, [])
    inspection = %Inspection{visible: true, title: "Process", lines: [], width: 20, height: 10}

    sidebars =
      %Sidebars{}
      |> Sidebars.open_observatory({timer, token})
      |> Sidebars.replace_observatory_data(data)
      |> Sidebars.inspect_observatory(inspection)

    closed = Sidebars.close_observatory(sidebars)
    observatory = Sidebars.observatory(closed)

    assert Sidebars.active_id(closed) == nil
    refute Observatory.visible?(observatory)
    assert Observatory.timer(observatory) == nil
    assert Observatory.data(observatory) == nil
    assert Observatory.inspection(observatory) == nil
    assert {:stale, ^closed} = Sidebars.expire_observatory(closed, token)

    next_timer = {make_ref(), make_ref()}
    assert {:stale, ^closed} = Sidebars.complete_observatory(closed, token, data, next_timer)
  end

  test "replacement tokens reject an old tick and accept only the current collection" do
    first_token = make_ref()
    second_token = make_ref()

    sidebars =
      %Sidebars{}
      |> Sidebars.open_observatory({make_ref(), first_token})
      |> Sidebars.open_observatory({make_ref(), second_token})

    assert {:stale, ^sidebars} = Sidebars.expire_observatory(sidebars, first_token)
    assert {:collect, collecting} = Sidebars.expire_observatory(sidebars, second_token)

    data = Data.visible(nil, [])
    next_timer = make_ref()
    next_token = make_ref()

    assert {:stale, ^collecting} =
             Sidebars.complete_observatory(
               collecting,
               first_token,
               data,
               {next_timer, next_token}
             )

    assert {:accepted, scheduled} =
             Sidebars.complete_observatory(
               collecting,
               second_token,
               data,
               {next_timer, next_token}
             )

    observatory = Sidebars.observatory(scheduled)
    assert Observatory.visible?(observatory)
    assert Observatory.data(observatory) == data
    assert Observatory.timer(observatory) == next_timer
    assert observatory.token == next_token
  end

  # The indirection lets runtime boundary tests pass intentionally invalid typed values.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp invoke(module, function, arguments), do: apply(module, function, arguments)
end
