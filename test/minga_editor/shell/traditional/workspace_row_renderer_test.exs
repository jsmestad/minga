defmodule MingaEditor.Shell.Traditional.WorkspaceRowRendererTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.WorkspaceRowRenderer
  alias MingaEditor.UI.Theme
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.TabSummary
  alias MingaEditor.Session.ChromeState.WorkspaceSummary

  defp doom_theme, do: Theme.get!(:doom_one)

  defp workspace(attrs) do
    WorkspaceSummary.new(
      Keyword.merge(
        [
          id: 0,
          kind: :manual,
          label: "minga",
          icon: "folder",
          color: 0x51AFEF,
          status: :idle,
          attention?: false,
          tab_count: 1,
          draft_count: 0,
          conflict_count: 0,
          running_background_count: 0,
          closeable?: false
        ],
        attrs
      )
    )
  end

  defp chrome_state(attrs) do
    workspaces =
      Keyword.get(attrs, :workspaces, [
        workspace(id: 0, kind: :manual, label: "minga", icon: "folder"),
        workspace(
          id: 1,
          kind: :agent,
          label: "Tests",
          icon: "cpu",
          status: :tool_executing,
          tab_count: 2,
          running_background_count: 1,
          closeable?: true
        )
      ])

    %ChromeState{
      workspaces: workspaces,
      visible_tabs: Keyword.get(attrs, :visible_tabs, []),
      mode: Keyword.get(attrs, :mode, :editor),
      active_workspace_id: Keyword.get(attrs, :active_workspace_id, 0),
      active_tab_id: Keyword.get(attrs, :active_tab_id),
      background_count: Keyword.get(attrs, :background_count, 0),
      attention_count: Keyword.get(attrs, :attention_count, 0),
      draft_count: Keyword.get(attrs, :draft_count, 0),
      conflict_count: Keyword.get(attrs, :conflict_count, 0)
    }
  end

  test "renders active and inactive workspace chips with status, background, and tab counts" do
    {draws, regions} =
      WorkspaceRowRenderer.render(0, 120, chrome_state(active_workspace_id: 1), doom_theme())

    text = Enum.map_join(draws, fn {_row, _col, run, _face} -> run end)

    assert String.contains?(text, "minga")
    assert String.contains?(text, "Tests*")
    assert String.contains?(text, "⚡")
    assert String.contains?(text, "bg1")
    assert String.contains?(text, "[2]")

    assert Enum.any?(regions, fn
             {0, _start, _end, {:workspace_goto, 1}} -> true
             _ -> false
           end)
  end

  test "renders badges in conflict draft attention background order" do
    state =
      chrome_state(
        active_workspace_id: 1,
        workspaces: [
          workspace(id: 0, kind: :manual, label: "minga", icon: "folder"),
          workspace(
            id: 1,
            kind: :agent,
            label: "Review",
            icon: "cpu",
            attention?: true,
            conflict_count: 2,
            draft_count: 3,
            running_background_count: 4,
            closeable?: true
          )
        ]
      )

    {draws, _regions} = WorkspaceRowRenderer.render(0, 120, state, doom_theme())
    text = Enum.map_join(draws, fn {_row, _col, run, _face} -> run end)

    assert String.contains?(text, "C2 D3 ! bg4")
  end

  test "overflow uses indicators while keeping active workspace visible" do
    workspaces =
      [workspace(id: 0, kind: :manual, label: "minga", icon: "folder")] ++
        Enum.map(1..8, fn id ->
          workspace(
            id: id,
            kind: :agent,
            label: "VeryLongWorkspace#{id}",
            icon: "cpu",
            closeable?: true
          )
        end)

    {draws, regions} =
      WorkspaceRowRenderer.render(
        0,
        40,
        chrome_state(workspaces: workspaces, active_workspace_id: 6),
        doom_theme()
      )

    text = Enum.map_join(draws, fn {_row, _col, run, _face} -> run end)

    assert String.contains?(text, "◂") or String.contains?(text, "▸")
    assert String.contains?(text, "VeryLongWorkspace6*")

    assert Enum.any?(regions, fn
             {0, _start, _end, {:workspace_goto, 6}} -> true
             _ -> false
           end)
  end

  test "targets the actual workspace id even after ordinal nine" do
    workspaces =
      [workspace(id: 0, kind: :manual, label: "m", icon: "folder")] ++
        Enum.map(1..10, fn id ->
          workspace(
            id: id,
            kind: :agent,
            label: "W#{id}",
            icon: "cpu",
            closeable?: true
          )
        end)

    {_draws, regions} =
      WorkspaceRowRenderer.render(
        0,
        120,
        chrome_state(workspaces: workspaces, active_workspace_id: 10),
        doom_theme()
      )

    assert Enum.any?(regions, fn
             {0, _start, _end, {:workspace_goto, 10}} -> true
             _ -> false
           end)
  end

  test "active-workspace-only tabs are separate from workspace row state" do
    tab =
      TabSummary.new(
        id: 42,
        workspace_id: 1,
        kind: :file,
        label: "active.ex",
        path: "/tmp/active.ex",
        icon: "",
        dirty?: false,
        draft_state: :none,
        attention?: false
      )

    state = chrome_state(active_workspace_id: 1, visible_tabs: [tab])

    assert [%TabSummary{id: 42, workspace_id: 1}] = ChromeState.visible_tabs(state)
  end
end
