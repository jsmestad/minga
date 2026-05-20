defmodule MingaEditor.State.TabBarTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.FileRef
  alias MingaEditor.State.AgentGroup
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState

  defp file_tab(id, label \\ ""), do: Tab.new_file(id, label)

  defp tab(:file, id, label), do: file_tab(id, label)
  defp tab(:agent, id, label), do: Tab.new_agent(id, label)

  defp tab_bar([{kind, label} | rest]) do
    tb = TabBar.new(tab(kind, 1, label))

    Enum.reduce(rest, tb, fn {kind, label}, acc ->
      {acc, _tab} = TabBar.add(acc, kind, label)
      acc
    end)
  end

  defp labels(tb), do: Enum.map(tb.tabs, & &1.label)
  defp active_label(tb), do: TabBar.active(tb).label

  defp buffer_for_path(path) do
    {:ok, pid} = BufferProcess.start_link(file_path: path)
    pid
  end

  defp tab_with_active_buffer(tab, buffer) do
    Tab.set_context(tab, %{buffers: %Buffers{active: buffer, list: [buffer], active_index: 0}})
  end

  defp two_agent_groups do
    tb = TabBar.new(file_tab(1, "a.ex"))
    {tb, _} = TabBar.add(tb, :file, "b.ex")
    {tb, group1} = TabBar.add_agent_group(tb, "Agent 1")
    tb = TabBar.move_tab_to_group(tb, 2, group1.id)
    {tb, group2} = TabBar.add_agent_group(tb, "Agent 2")
    {tb, _} = TabBar.add(tb, :file, "c.ex")
    tb = TabBar.move_tab_to_group(tb, 3, group2.id)
    {tb, group1, group2}
  end

  describe "new/1, active/1, and active_index/1" do
    test "initializes the first tab as active with the next id" do
      tab = file_tab(1, "main.ex")
      tb = TabBar.new(tab)

      assert TabBar.count(tb) == 1
      assert TabBar.active(tb) == tab
      assert TabBar.active_index(tb) == 0
      assert tb.next_id == 2
    end
  end

  describe "add/3" do
    test "adds supported tab kinds after the active tab and activates them" do
      for {kind, label} <- [file: "b.ex", agent: "Agent"] do
        tb = TabBar.new(file_tab(1, "a.ex"))
        {tb, new_tab} = TabBar.add(tb, kind, label)

        assert new_tab.kind == kind
        assert new_tab.label == label
        assert TabBar.count(tb) == 2
        assert TabBar.active(tb).id == new_tab.id
      end
    end

    test "inserts after active, not at end" do
      tb = tab_bar(file: "a", file: "b")
      tb = TabBar.switch_to(tb, 1)
      {tb, c} = TabBar.add(tb, :file, "c")

      assert labels(tb) == ["a", "c", "b"]
      assert TabBar.active(tb).id == c.id
    end

    test "assigns monotonically increasing ids" do
      tb = TabBar.new(file_tab(1))
      {tb, t2} = TabBar.add(tb, :file, "b")
      {_tb, t3} = TabBar.add(tb, :file, "c")

      assert {t2.id, t3.id} == {2, 3}
    end
  end

  describe "keep_only/2" do
    test "keeps the selected tab and prunes orphaned agent groups" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, group1} = TabBar.add_agent_group(tb, "Agent 1")
      {tb, group2} = TabBar.add_agent_group(tb, "Agent 2")
      {tb, tab2} = TabBar.add(tb, :agent, "agent one")
      tb = TabBar.move_tab_to_group(tb, tab2.id, group1.id)
      {tb, tab3} = TabBar.add(tb, :agent, "agent two")
      tb = TabBar.move_tab_to_group(tb, tab3.id, group2.id)

      tb = TabBar.keep_only(tb, tab2.id)

      assert TabBar.count(tb) == 1
      assert TabBar.active(tb).id == tab2.id
      assert Enum.map(tb.agent_groups, & &1.id) == [group1.id]
    end
  end

  describe "remove/2" do
    test "cannot remove the last tab" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.remove(tb, 1) == :last_tab
    end

    test "removes tabs and chooses the expected active neighbor" do
      cases = [
        {fn ->
           tb = tab_bar(file: "a", file: "b")
           TabBar.remove(tb, 1)
         end, ["b"], "b"},
        {fn ->
           tb = tab_bar(file: "a", file: "b", file: "c")
           tb = TabBar.switch_to(tb, 2)
           TabBar.remove(tb, 2)
         end, ["a", "c"], "c"},
        {fn ->
           tb = tab_bar(file: "a", file: "b")
           TabBar.remove(tb, TabBar.active(tb).id)
         end, ["a"], "a"},
        {fn ->
           tb = tab_bar(file: "a", file: "b")
           TabBar.remove(tb, 999)
         end, ["a", "b"], "b"}
      ]

      for {remove, expected_labels, expected_active} <- cases do
        assert {:ok, tb} = remove.()
        assert labels(tb) == expected_labels
        assert active_label(tb) == expected_active
      end
    end
  end

  describe "switch_to/2, next/1, and prev/1" do
    test "switches to existing tabs and ignores missing ids" do
      tb = tab_bar(file: "a", file: "b")
      assert active_label(tb) == "b"

      tb = TabBar.switch_to(tb, 1)
      assert active_label(tb) == "a"
      assert TabBar.switch_to(tb, 999) == tb
    end

    test "cycles tabs with wraparound and treats single-tab bars as no-ops" do
      cases = [
        {fn -> tab_bar(file: "a", file: "b", file: "c") |> TabBar.next() end, "a"},
        {fn -> tab_bar(file: "a", file: "b") |> TabBar.switch_to(1) |> TabBar.prev() end, "b"}
      ]

      for {cycle, expected_active} <- cases do
        assert active_label(cycle.()) == expected_active
      end

      single = TabBar.new(file_tab(1))
      assert TabBar.next(single) == single
      assert TabBar.prev(single) == single
    end

    test "cycles only within the active workspace" do
      tb =
        tab_bar(
          file: "manual-a",
          file: "manual-b",
          agent: "Agent",
          file: "agent-a",
          file: "agent-b"
        )

      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 3, group.id)
      tb = TabBar.move_tab_to_group(tb, 4, group.id)
      tb = TabBar.move_tab_to_group(tb, 5, group.id)

      tb = TabBar.switch_to(tb, 4)
      assert TabBar.next(tb).active_id == 5
      assert TabBar.next(TabBar.next(tb)).active_id == 4
      assert TabBar.prev(tb).active_id == 5

      tb = TabBar.switch_to(tb, 1)
      assert TabBar.next(tb).active_id == 2
      assert TabBar.prev(tb).active_id == 2
    end
  end

  describe "tab updates" do
    test "updates context and label on the selected tab" do
      tb = TabBar.new(file_tab(1, "old"))
      editing = VimState.new()

      tb =
        tb
        |> TabBar.update_context(1, %{editing: editing})
        |> TabBar.update_label(1, "new")

      assert TabBar.get(tb, 1).context.editing == editing
      assert TabBar.get(tb, 1).label == "new"
    end
  end

  describe "kind queries" do
    test "finds and filters tabs by kind" do
      tb = tab_bar(file: "a", file: "b", agent: "Agent")

      assert TabBar.find_by_kind(tb, :agent).label == "Agent"
      assert TabBar.find_by_kind(tb, :file).label == "a"
      assert TabBar.find_by_kind(TabBar.new(file_tab(1)), :agent) == nil
      assert length(TabBar.filter_by_kind(tb, :file)) == 2
      assert length(TabBar.filter_by_kind(tb, :agent)) == 1
    end
  end

  describe "visible_file_tabs/1 and visible_file_tabs/2" do
    test "returns only file tabs in the active workspace" do
      tb = tab_bar(file: "manual.ex", agent: "Agent", file: "agent.ex", file: "other.ex")
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.move_tab_to_group(tb, 3, group.id)
      tb = TabBar.switch_to(tb, 2)

      assert Enum.map(TabBar.visible_file_tabs(tb), & &1.label) == ["agent.ex"]
      assert Enum.map(TabBar.visible_file_tabs(tb, 0), & &1.label) == ["manual.ex", "other.ex"]
    end

    test "finds same-path file tabs by workspace and excludes agent tabs" do
      path = "/tmp/minga-tab-bar-same-file.ex"
      manual_buffer = buffer_for_path(path)
      agent_buffer = buffer_for_path(path)

      manual_tab = tab_with_active_buffer(file_tab(1, "same.ex"), manual_buffer)
      agent_tab = Tab.new_agent(2, "Agent")
      agent_file_tab = tab_with_active_buffer(file_tab(3, "same.ex"), agent_buffer)

      tb = %TabBar{tabs: [manual_tab, agent_tab, agent_file_tab], active_id: 2, next_id: 4}
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.move_tab_to_group(tb, 3, group.id)
      file_ref = FileRef.new(path)

      assert TabBar.find_file_tab_in_workspace(tb, 0, file_ref).id == 1
      assert TabBar.find_file_tab_in_workspace(tb, group.id, file_ref).id == 3
      refute Enum.any?(TabBar.visible_file_tabs(tb), &(&1.kind == :agent))
    end
  end

  describe "most_recent_of_kind/2" do
    test "returns the last non-active matching tab or nil" do
      tb = tab_bar(file: "a", file: "b", agent: "Agent")
      assert TabBar.most_recent_of_kind(tb, :file).label == "b"

      tb = TabBar.switch_to(tb, 1)
      assert TabBar.most_recent_of_kind(tb, :file).label == "b"
      assert TabBar.most_recent_of_kind(TabBar.new(file_tab(1)), :file) == nil
    end
  end

  describe "lookup helpers" do
    test "gets tabs by id, existence, and 1-based index" do
      tb = tab_bar(file: "first.ex", file: "second.ex", file: "third.ex")

      assert TabBar.get(tb, 1).label == "first.ex"
      assert TabBar.get(tb, 99) == nil
      assert TabBar.has_tab?(tb, 1)
      refute TabBar.has_tab?(tb, 99)
      assert TabBar.tab_at(tb, 1).label == "first.ex"
      assert TabBar.tab_at(tb, 2).label == "second.ex"
      assert TabBar.tab_at(tb, 3).label == "third.ex"
      assert TabBar.tab_at(tb, 5) == nil
      assert TabBar.tab_at(tb, 0) == nil
    end
  end

  describe "next_of_kind/2" do
    test "cycles through tabs of the requested kind only" do
      tb = tab_bar(file: "file.ex", agent: "Agent 1", file: "other.ex", agent: "Agent 2")
      tb = TabBar.switch_to(tb, 1)

      tb = TabBar.next_of_kind(tb, :agent)
      assert active_label(tb) == "Agent 1"

      tb = TabBar.next_of_kind(tb, :agent)
      assert active_label(tb) == "Agent 2"

      tb = TabBar.next_of_kind(tb, :agent)
      assert active_label(tb) == "Agent 1"
    end

    test "handles missing or single matching kinds" do
      only_file = TabBar.new(file_tab(1, "only.ex"))
      assert TabBar.next_of_kind(only_file, :agent).active_id == only_file.active_id

      tb = tab_bar(file: "file.ex", agent: "Solo") |> TabBar.switch_to(1)
      assert TabBar.next_of_kind(tb, :agent) |> active_label() == "Solo"
    end
  end

  describe "attention by tab or session" do
    test "detects attention and updates by matching session" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      refute TabBar.any_attention?(tb)

      {tb, agent} = TabBar.add(tb, :agent, "Agent")
      tb = TabBar.update_tab(tb, agent.id, &Tab.set_session(&1, self()))
      tb = TabBar.set_attention_by_session(tb, self(), true)

      assert TabBar.any_attention?(tb)
      assert TabBar.get(tb, agent.id).attention == true
    end

    test "returns unchanged when no session matches" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.set_attention_by_session(tb, self(), true) == tb
    end
  end

  describe "add_agent_group/3" do
    test "adds groups with monotonically increasing ids and optional session" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, group1} = TabBar.add_agent_group(tb, "Agent 1")
      {tb, group2} = TabBar.add_agent_group(tb, "Agent 2", self())

      assert Enum.map(tb.agent_groups, & &1.label) == ["Agent 1", "Agent 2"]
      assert {group1.id, group2.id} == {1, 2}
      assert group2.session == self()
    end
  end

  describe "remove_group/2" do
    test "removes groups, migrates tabs to manual, and leaves missing groups alone" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.remove_group(tb, 0) == tb

      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.switch_to_group(tb, group.id)
      tb = TabBar.remove_group(tb, group.id)

      assert TabBar.active_group_id(tb) == 0
      assert TabBar.get(tb, 2).group_id == 0

      initial_count = length(tb.agent_groups)
      assert length(TabBar.remove_group(tb, 999).agent_groups) == initial_count
    end
  end

  describe "group membership and switching" do
    test "moves tabs to groups, lists members, and switches to the group's first tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.switch_to(tb, 1)

      assert TabBar.tabs_in_group(tb, group.id) |> Enum.map(& &1.id) == [2]
      assert TabBar.tabs_in_group(tb, 0) |> Enum.map(& &1.id) == [1]

      tb = TabBar.switch_to_group(tb, group.id)
      assert TabBar.active_group_id(tb) == group.id
      assert tb.active_id == 2
      assert TabBar.switch_to_group(tb, 999) == tb
    end
  end

  describe "agent group cycling" do
    test "next and previous agent group wrap through agent groups only" do
      {tb, group1, group2} = two_agent_groups()

      tb = TabBar.switch_to_group(tb, group2.id)
      assert TabBar.next_agent_group(tb) |> TabBar.active_group_id() == group1.id

      tb = TabBar.switch_to_group(tb, group1.id)
      assert TabBar.prev_agent_group(tb) |> TabBar.active_group_id() == group2.id
    end

    test "next_agent_group skips manual and cycles agent groups" do
      {tb, group1, group2} = two_agent_groups()
      tb = TabBar.switch_to_group(tb, 0)

      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == group1.id

      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == group2.id

      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == group1.id
    end

    test "handles no groups and single group" do
      manual = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.next_agent_group(manual) == manual
      assert TabBar.prev_agent_group(manual) == manual

      tb = tab_bar(file: "a.ex", file: "b.ex")
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id) |> TabBar.switch_to_group(0)

      assert TabBar.next_agent_group(tb) |> TabBar.active_group_id() == group.id

      assert TabBar.next_agent_group(TabBar.next_agent_group(tb)) |> TabBar.active_group_id() ==
               group.id
    end
  end

  describe "disclosure_tier/1" do
    test "maps agent group count to progressive disclosure tier" do
      for {group_count, expected_tier} <- [{0, 0}, {1, 1}, {2, 2}, {4, 2}, {5, 3}] do
        tb =
          Enum.reduce(1..group_count//1, TabBar.new(file_tab(1, "a.ex")), fn i, acc ->
            {acc, _} = TabBar.add_agent_group(acc, "A#{i}")
            acc
          end)

        assert TabBar.disclosure_tier(tb) == expected_tier
      end
    end
  end

  describe "agent group lookup and updates" do
    test "finds groups by session and active tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.active_group(tb) == nil
      assert TabBar.find_group_by_session(tb, self()) == nil
      assert TabBar.get_group(tb, 999) == nil
      refute TabBar.has_agent_groups?(tb)

      {tb, group} = TabBar.add_agent_group(tb, "Agent", self())
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, group.id) |> TabBar.switch_to_group(group.id)

      assert TabBar.has_agent_groups?(tb)
      assert TabBar.find_group_by_session(tb, self()).id == group.id
      assert TabBar.active_group(tb).id == group.id
    end

    test "updates a group through the owning function" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, group} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.update_group(tb, group.id, &AgentGroup.set_agent_status(&1, :error))

      assert TabBar.get_group(tb, group.id).agent_status == :error
    end
  end

  describe "scrub_dead_buffer/2" do
    test "removes dead pid from inactive tab context buffers" do
      dead = :dead_pid
      live = :live_pid

      tab1 = file_tab(1, "active")

      tab2 =
        file_tab(2, "inactive")
        |> Tab.set_context(%{
          buffers: %Buffers{list: [dead, live], active: dead, active_index: 0}
        })

      tb = %TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}
      result = TabBar.scrub_dead_buffer(tb, dead)

      scrubbed = TabBar.get(result, 2)
      assert scrubbed.context.buffers.list == [live]
      assert scrubbed.context.buffers.active == live
      refute dead in scrubbed.context.buffers.list
    end

    test "no-op for tabs without context buffers" do
      tab1 = file_tab(1, "empty context")
      tb = TabBar.new(tab1)

      assert TabBar.scrub_dead_buffer(tb, :some_pid) == tb
    end

    test "scrubs multiple tabs in one pass" do
      dead = :dead_pid

      tab1 =
        file_tab(1, "a")
        |> Tab.set_context(%{buffers: %Buffers{list: [dead], active: dead, active_index: 0}})

      tab2 =
        file_tab(2, "b")
        |> Tab.set_context(%{
          buffers: %Buffers{list: [:live, dead], active: :live, active_index: 0}
        })

      tb = %TabBar{tabs: [tab1, tab2], active_id: 1, next_id: 3}
      result = TabBar.scrub_dead_buffer(tb, dead)

      assert TabBar.get(result, 1).context.buffers.list == []
      assert TabBar.get(result, 1).context.buffers.active == nil
      assert TabBar.get(result, 2).context.buffers.list == [:live]
      refute dead in TabBar.get(result, 2).context.buffers.list
    end
  end
end
