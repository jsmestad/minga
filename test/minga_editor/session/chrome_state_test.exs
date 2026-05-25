defmodule MingaEditor.Session.ChromeStateTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.State, as: SessionState

  describe "from_editor_state/1 manual workspace" do
    test "includes non-agent workspace label from project root", %{tmp_dir: tmp_dir} do
      state = state(project_root: tmp_dir)

      chrome = ChromeState.from_editor_state(state)
      manual = hd(chrome.workspaces)

      assert manual.id == 0
      assert manual.kind == :manual
      assert manual.label == Path.basename(tmp_dir)
      assert manual.icon == "folder"
      refute manual.closeable?
    end

    test "falls back to Files when project root is unavailable" do
      chrome = ChromeState.from_editor_state(state(project_root: nil))
      assert hd(chrome.workspaces).label == "Files"
    end

    test "honors custom_name when supplied" do
      chrome =
        ChromeState.from_editor_state(%{
          workspace: %{custom_name: "Client App", file_tree: %FileTreeState{}},
          shell_state: %{tab_bar: nil}
        })

      assert hd(chrome.workspaces).label == "Client App"
    end
  end

  describe "from_editor_state/1 agent workspaces" do
    test "includes one agent workspace", %{tmp_dir: tmp_dir} do
      {tb, group} = tab_bar_with_agent_workspace(tmp_dir)
      chrome = ChromeState.from_editor_state(state(tab_bar: tb, project_root: tmp_dir))

      assert Enum.any?(chrome.workspaces, &(&1.id == group.id and &1.kind == :agent))
    end

    test "tracks background and attention counts", %{tmp_dir: tmp_dir} do
      {tb, group} = tab_bar_with_agent_workspace(tmp_dir)

      tb =
        tb
        |> TabBar.update_workspace(group.id, &Workspace.set_agent_status(&1, :thinking))
        |> TabBar.update_tab(3, &Tab.set_attention(&1, true))
        |> TabBar.switch_to(1)

      chrome = ChromeState.from_editor_state(state(tab_bar: tb, project_root: tmp_dir))

      assert chrome.active_workspace_id == 0
      assert chrome.background_count == 1
      assert chrome.attention_count == 1
    end
  end

  describe "visible_tabs" do
    test "includes only active workspace file tabs", %{tmp_dir: tmp_dir} do
      {tb, group} = tab_bar_with_agent_workspace(tmp_dir)
      manual_chrome = ChromeState.from_editor_state(state(tab_bar: tb, project_root: tmp_dir))

      assert Enum.map(manual_chrome.visible_tabs, & &1.workspace_id) == [0]
      assert Enum.map(manual_chrome.visible_tabs, & &1.label) == ["manual.ex"]

      agent_chrome =
        ChromeState.from_editor_state(
          state(tab_bar: TabBar.switch_to(tb, 3), project_root: tmp_dir)
        )

      assert agent_chrome.active_workspace_id == group.id
      assert Enum.map(agent_chrome.visible_tabs, & &1.workspace_id) == [group.id]
      assert Enum.map(agent_chrome.visible_tabs, & &1.label) == ["agent.ex"]
    end

    test "duplicate paths in different workspaces remain distinct", %{tmp_dir: tmp_dir} do
      duplicate_path = Path.join(tmp_dir, "same.ex")
      {tb, group} = duplicate_path_tab_bar(duplicate_path)

      manual = ChromeState.from_editor_state(state(tab_bar: tb, project_root: tmp_dir))

      agent =
        ChromeState.from_editor_state(
          state(tab_bar: TabBar.switch_to(tb, 3), project_root: tmp_dir)
        )

      assert [%{id: 1, workspace_id: 0, path: ^duplicate_path}] = manual.visible_tabs
      assert [%{id: 3, workspace_id: group_id, path: ^duplicate_path}] = agent.visible_tabs
      assert group_id == group.id
    end

    test "does not include agent-chat tabs in visible file tabs", %{tmp_dir: tmp_dir} do
      {tb, _group} = tab_bar_with_agent_workspace(tmp_dir)

      chrome =
        ChromeState.from_editor_state(
          state(tab_bar: TabBar.switch_to(tb, 2), project_root: tmp_dir)
        )

      assert Enum.map(chrome.visible_tabs, & &1.kind) == [:file]
      assert Enum.map(chrome.visible_tabs, & &1.label) == ["agent.ex"]
    end

    test "keeps pinned agent workspace tabs first and tints them", %{tmp_dir: tmp_dir} do
      {tb, group} = tab_bar_with_agent_workspace(tmp_dir)
      {tb, pinned_tab} = TabBar.add(tb, :file, "pinned.ex")
      tb = TabBar.move_tab_to_workspace(tb, pinned_tab.id, group.id)
      tb = TabBar.pin_tab(tb, pinned_tab.id)
      tb = TabBar.switch_to(tb, pinned_tab.id)

      chrome = ChromeState.from_editor_state(state(tab_bar: tb, project_root: tmp_dir))

      assert Enum.map(chrome.visible_tabs, & &1.label) == ["pinned.ex", "agent.ex"]
      assert Enum.map(chrome.visible_tabs, & &1.pinned?) == [true, false]
      assert Enum.all?(chrome.visible_tabs, &(&1.tint_color > 0))

      manual_chrome =
        ChromeState.from_editor_state(
          state(tab_bar: TabBar.switch_to(tb, 1), project_root: tmp_dir)
        )

      assert Enum.map(manual_chrome.visible_tabs, & &1.label) == ["manual.ex"]
      assert Enum.all?(manual_chrome.visible_tabs, &(&1.tint_color == 0))
    end

    test "falls back to the tab context when the active buffer is dead", %{tmp_dir: tmp_dir} do
      stale_path = Path.join(tmp_dir, "stale.ex")
      stale_buffer = start_file_buffer(stale_path)
      stale_ref = Process.monitor(stale_buffer)
      GenServer.stop(stale_buffer)
      assert_receive {:DOWN, ^stale_ref, :process, ^stale_buffer, _}

      context_path = Path.join(tmp_dir, "context.ex")
      context_buffer = start_file_buffer(context_path)

      context =
        TabContext.from_workspace_map(%{
          buffers: %Buffers{active: context_buffer, list: [context_buffer]}
        })

      tab =
        Tab.new_file(1, "context.ex")
        |> Tab.set_context(context)

      tb = %TabBar{tabs: [tab], active_id: 1, next_id: 2}

      chrome =
        ChromeState.from_editor_state(
          state(tab_bar: tb, active_buffer: stale_buffer, project_root: tmp_dir)
        )

      assert [%{path: ^context_path}] = chrome.visible_tabs
    end
  end

  test "draft and conflict counts default to zero", %{tmp_dir: tmp_dir} do
    {tb, _group} = tab_bar_with_agent_workspace(tmp_dir)
    chrome = ChromeState.from_editor_state(state(tab_bar: tb, project_root: tmp_dir))

    assert chrome.draft_count == 0
    assert chrome.conflict_count == 0
    assert Enum.all?(chrome.workspaces, &(&1.draft_count == 0 and &1.conflict_count == 0))
    assert Enum.all?(chrome.visible_tabs, &(&1.draft_state == :none))
  end

  defp state(opts) do
    project_root = Keyword.get(opts, :project_root)
    tb = Keyword.get(opts, :tab_bar, TabBar.new(Tab.new_file(1, "manual.ex")))
    active_buffer = Keyword.get(opts, :active_buffer) || buffer_for_tab(TabBar.active(tb))

    %{
      workspace:
        %SessionState{
          viewport: Viewport.new(24, 80),
          keymap_scope: :editor,
          buffers: %Buffers{active: active_buffer, list: List.wrap(active_buffer)}
        }
        |> SessionState.set_file_tree(%FileTreeState{project_root: project_root}),
      shell_state: %{tab_bar: tb}
    }
  end

  defp tab_bar_with_agent_workspace(tmp_dir) do
    manual = file_tab(1, "manual.ex", Path.join(tmp_dir, "manual.ex"), 0)
    agent_chat = Tab.new_agent(2, "Agent") |> Tab.set_group(1)
    agent_file = file_tab(3, "agent.ex", Path.join(tmp_dir, "agent.ex"), 1)
    group = Workspace.new_agent(1, "Agent", self())

    {%TabBar{
       tabs: [manual, agent_chat, agent_file],
       active_id: 1,
       next_id: 4,
       workspaces: [group],
       next_workspace_id: 2
     }, group}
  end

  defp duplicate_path_tab_bar(path) do
    manual = file_tab(1, "same.ex", path, 0)
    agent_chat = Tab.new_agent(2, "Agent") |> Tab.set_group(1)
    agent_file = file_tab(3, "same.ex", path, 1)
    group = Workspace.new_agent(1, "Agent", self())

    {%TabBar{
       tabs: [manual, agent_chat, agent_file],
       active_id: 1,
       next_id: 4,
       workspaces: [group],
       next_workspace_id: 2
     }, group}
  end

  defp file_tab(id, label, path, group_id) do
    buffer = start_file_buffer(path)
    context = TabContext.from_workspace_map(%{buffers: %Buffers{active: buffer, list: [buffer]}})

    id
    |> Tab.new_file(label)
    |> Tab.set_group(group_id)
    |> Tab.set_context(context)
  end

  defp buffer_for_tab(%Tab{context: context}) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: buffer}} -> buffer
      _ -> nil
    end
  end

  defp buffer_for_tab(nil), do: nil

  defp start_file_buffer(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    start_supervised!({BufferProcess, file_path: path}, id: make_ref())
  end
end
