defmodule Minga.Editor.State.TabBarTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.AgentGroup

  defp file_tab(id, label \\ ""), do: Tab.new_file(id, label)

  describe "new/1" do
    test "creates a tab bar with one tab" do
      tab = file_tab(1, "main.ex")
      tb = TabBar.new(tab)
      assert TabBar.count(tb) == 1
      assert TabBar.active(tb) == tab
      assert tb.next_id == 2
    end
  end

  describe "active/1 and active_index/1" do
    test "returns the active tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.active(tb).label == "a.ex"
      assert TabBar.active_index(tb) == 0
    end
  end

  describe "add/3" do
    test "adds a file tab after the active tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, new_tab} = TabBar.add(tb, :file, "b.ex")
      assert new_tab.kind == :file
      assert new_tab.label == "b.ex"
      assert TabBar.count(tb) == 2
      assert TabBar.active(tb).id == new_tab.id
    end

    test "adds an agent tab" do
      tb = TabBar.new(file_tab(1))
      {tb, new_tab} = TabBar.add(tb, :agent, "Agent")
      assert new_tab.kind == :agent
      assert TabBar.active(tb).id == new_tab.id
    end

    test "inserts after active, not at end" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _b} = TabBar.add(tb, :file, "b")
      # Switch back to tab 1
      tb = TabBar.switch_to(tb, 1)
      {tb, c} = TabBar.add(tb, :file, "c")
      # Order should be: a, c, b
      labels = Enum.map(tb.tabs, & &1.label)
      assert labels == ["a", "c", "b"]
      assert TabBar.active(tb).id == c.id
    end

    test "assigns monotonically increasing ids" do
      tb = TabBar.new(file_tab(1))
      {tb, t2} = TabBar.add(tb, :file, "b")
      {_tb, t3} = TabBar.add(tb, :file, "c")
      assert t2.id == 2
      assert t3.id == 3
    end
  end

  describe "remove/2" do
    test "cannot remove the last tab" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.remove(tb, 1) == :last_tab
    end

    test "removes a non-active tab" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _b} = TabBar.add(tb, :file, "b")
      # Active is tab 2 (b). Remove tab 1 (a).
      {:ok, tb} = TabBar.remove(tb, 1)
      assert TabBar.count(tb) == 1
      assert TabBar.active(tb).label == "b"
    end

    test "removing active tab switches to right neighbor" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, b} = TabBar.add(tb, :file, "b")
      {tb, _c} = TabBar.add(tb, :file, "c")
      # Active is c (last added). Switch to b.
      tb = TabBar.switch_to(tb, b.id)
      {:ok, tb} = TabBar.remove(tb, b.id)
      # Should switch to c (right neighbor)
      assert TabBar.active(tb).label == "c"
    end

    test "removing last tab switches to left neighbor" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _b} = TabBar.add(tb, :file, "b")
      # Active is b (index 1). Remove b.
      {:ok, tb} = TabBar.remove(tb, TabBar.active(tb).id)
      assert TabBar.active(tb).label == "a"
    end

    test "removing nonexistent tab is a no-op" do
      tb = TabBar.new(file_tab(1))
      {tb, _} = TabBar.add(tb, :file, "b")
      {:ok, tb2} = TabBar.remove(tb, 999)
      assert tb2 == tb
    end
  end

  describe "switch_to/2" do
    test "switches to the given tab" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, b} = TabBar.add(tb, :file, "b")
      assert TabBar.active(tb).id == b.id
      tb = TabBar.switch_to(tb, 1)
      assert TabBar.active(tb).label == "a"
    end

    test "switching to nonexistent id is a no-op" do
      tb = TabBar.new(file_tab(1))
      tb2 = TabBar.switch_to(tb, 999)
      assert tb2 == tb
    end
  end

  describe "next/1 and prev/1" do
    test "next wraps around" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      {tb, _} = TabBar.add(tb, :file, "c")
      # Active is c (index 2). Next wraps to a (index 0).
      tb = TabBar.next(tb)
      assert TabBar.active(tb).label == "a"
    end

    test "prev wraps around" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      # Active is b. Switch to a.
      tb = TabBar.switch_to(tb, 1)
      # Prev from a wraps to b.
      tb = TabBar.prev(tb)
      assert TabBar.active(tb).label == "b"
    end

    test "next on single tab is a no-op" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.next(tb) == tb
    end

    test "prev on single tab is a no-op" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.prev(tb) == tb
    end
  end

  describe "update_context/3" do
    test "stores context on the given tab" do
      tb = TabBar.new(file_tab(1))
      ctx = %{mode: :insert}
      tb = TabBar.update_context(tb, 1, ctx)
      assert TabBar.get(tb, 1).context == ctx
    end
  end

  describe "update_label/3" do
    test "updates the label of the given tab" do
      tb = TabBar.new(file_tab(1, "old"))
      tb = TabBar.update_label(tb, 1, "new")
      assert TabBar.get(tb, 1).label == "new"
    end
  end

  describe "find_by_kind/2 and filter_by_kind/2" do
    test "finds first tab of a kind" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :agent, "Agent 1")
      assert TabBar.find_by_kind(tb, :agent).label == "Agent 1"
      assert TabBar.find_by_kind(tb, :file).label == "a"
    end

    test "returns nil when no tab of that kind exists" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.find_by_kind(tb, :agent) == nil
    end

    test "filters all tabs of a kind" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      assert length(TabBar.filter_by_kind(tb, :file)) == 2
      assert length(TabBar.filter_by_kind(tb, :agent)) == 1
    end
  end

  describe "most_recent_of_kind/2" do
    test "returns the last non-active tab of the given kind" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      # Active is agent tab. Most recent file tab is b.
      assert TabBar.most_recent_of_kind(tb, :file).label == "b"
    end

    test "returns nil when no other tab of that kind exists" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.most_recent_of_kind(tb, :file) == nil
    end

    test "skips the active tab" do
      tb = TabBar.new(file_tab(1, "a"))
      {tb, _} = TabBar.add(tb, :file, "b")
      tb = TabBar.switch_to(tb, 1)
      # Active is a. Most recent file is b (not a).
      result = TabBar.most_recent_of_kind(tb, :file)
      assert result.label == "b"
    end
  end

  describe "get/2" do
    test "returns the tab by id" do
      tb = TabBar.new(file_tab(1, "x"))
      assert TabBar.get(tb, 1).label == "x"
    end

    test "returns nil for missing id" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.get(tb, 99) == nil
    end
  end

  describe "has_tab?/2" do
    test "returns true for existing tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.has_tab?(tb, 1)
    end

    test "returns false for missing tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      refute TabBar.has_tab?(tb, 99)
    end
  end

  describe "tab_at/2" do
    test "returns tab at 1-based index" do
      tb = TabBar.new(file_tab(1, "first.ex"))
      {tb, _} = TabBar.add(tb, :file, "second.ex")
      {tb, _} = TabBar.add(tb, :file, "third.ex")

      assert TabBar.tab_at(tb, 1).label == "first.ex"
      assert TabBar.tab_at(tb, 2).label == "second.ex"
      assert TabBar.tab_at(tb, 3).label == "third.ex"
    end

    test "returns nil for out-of-range index" do
      tb = TabBar.new(file_tab(1))
      assert TabBar.tab_at(tb, 5) == nil
      assert TabBar.tab_at(tb, 0) == nil
    end
  end

  describe "next_of_kind/2" do
    test "cycles through agent tabs only" do
      tb = TabBar.new(file_tab(1, "file.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent 1")
      {tb, _} = TabBar.add(tb, :file, "other.ex")
      {tb, _} = TabBar.add(tb, :agent, "Agent 2")

      # Start on file tab
      tb = TabBar.switch_to(tb, 1)
      tb = TabBar.next_of_kind(tb, :agent)
      assert TabBar.active(tb).label == "Agent 1"

      tb = TabBar.next_of_kind(tb, :agent)
      assert TabBar.active(tb).label == "Agent 2"

      tb = TabBar.next_of_kind(tb, :agent)
      assert TabBar.active(tb).label == "Agent 1"
    end

    test "returns unchanged when no tabs of that kind exist" do
      tb = TabBar.new(file_tab(1, "only.ex"))
      tb2 = TabBar.next_of_kind(tb, :agent)
      assert tb2.active_id == tb.active_id
    end

    test "stays on single agent tab" do
      tb = TabBar.new(file_tab(1, "file.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Solo")
      tb = TabBar.switch_to(tb, 1)

      tb = TabBar.next_of_kind(tb, :agent)
      assert TabBar.active(tb).label == "Solo"
    end
  end

  describe "any_attention?/1" do
    test "returns false when no tabs have attention" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      refute TabBar.any_attention?(tb)
    end

    test "returns true when a tab has attention" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, agent} = TabBar.add(tb, :agent, "Agent")
      tb = TabBar.update_tab(tb, agent.id, &Tab.set_attention(&1, true))
      assert TabBar.any_attention?(tb)
    end
  end

  describe "set_attention_by_session/3" do
    test "sets attention on the matching tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, agent} = TabBar.add(tb, :agent, "Agent")
      fake_pid = self()
      tb = TabBar.update_tab(tb, agent.id, &Tab.set_session(&1, fake_pid))

      tb = TabBar.set_attention_by_session(tb, fake_pid, true)
      assert Enum.find(tb.tabs, &(&1.id == agent.id)).attention == true
    end

    test "returns unchanged when no tab matches" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      tb2 = TabBar.set_attention_by_session(tb, self(), true)
      assert tb2 == tb
    end
  end

  # ── Workspace management ───────────────────────────────────────────────────

  describe "add_agent_group/3" do
    test "adds a group and returns it" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, group} = TabBar.add_agent_group(tb, "Claude")
      assert group.label == "Claude"
      assert length(tb.agent_groups) == 1
    end

    test "assigns monotonically increasing workspace ids" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, ws1} = TabBar.add_agent_group(tb, "Agent 1")
      {_tb, ws2} = TabBar.add_agent_group(tb, "Agent 2")
      assert ws1.id == 1
      assert ws2.id == 2
    end

    test "stores session pid on workspace" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {_tb, ws} = TabBar.add_agent_group(tb, "Agent", self())
      assert ws.session == self()
    end
  end

  describe "remove_group/2" do
    test "removing manual workspace (id 0) is a no-op" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      tb2 = TabBar.remove_group(tb, 0)
      assert tb2 == tb
    end

    test "removing workspace migrates its tabs to manual" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, ws} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 1, ws.id)
      assert TabBar.get(tb, 1).group_id == ws.id

      tb = TabBar.remove_group(tb, ws.id)
      assert TabBar.get(tb, 1).group_id == 0
    end

    test "removing active workspace migrates tabs and active lands on manual" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, ws} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, ws.id)
      tb = TabBar.switch_to_group(tb, ws.id)
      assert TabBar.active_group_id(tb) == ws.id

      # Remove workspace: tab 2 migrates to manual, active tab stays 2 (now in manual)
      tb = TabBar.remove_group(tb, ws.id)
      assert TabBar.active_group_id(tb) == 0
      assert TabBar.get(tb, 2).group_id == 0
    end

    test "removing nonexistent group is harmless" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      initial_count = length(tb.agent_groups)
      tb2 = TabBar.remove_group(tb, 999)
      assert length(tb2.agent_groups) == initial_count
    end
  end

  describe "move_tab_to_group/3" do
    test "moves a tab to a workspace" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, ws} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 1, ws.id)
      assert TabBar.get(tb, 1).group_id == ws.id
    end
  end

  describe "tabs_in_group/2" do
    test "returns only tabs in that group" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, ws} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 1, ws.id)

      assert length(TabBar.tabs_in_group(tb, ws.id)) == 1
      assert length(TabBar.tabs_in_group(tb, 0)) == 1
      assert hd(TabBar.tabs_in_group(tb, ws.id)).id == 1
    end
  end

  describe "switch_to_group/2" do
    test "switches to an existing workspace by activating its first tab" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, ws} = TabBar.add_agent_group(tb, "Agent")
      # Put agent tab in agent workspace
      tb = TabBar.move_tab_to_group(tb, 2, ws.id)
      # Start on file tab
      tb = TabBar.switch_to(tb, 1)

      tb = TabBar.switch_to_group(tb, ws.id)
      assert TabBar.active_group_id(tb) == ws.id
      assert tb.active_id == 2
    end

    test "switching to nonexistent workspace is a no-op" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      tb2 = TabBar.switch_to_group(tb, 999)
      assert TabBar.active_group_id(tb2) == TabBar.active_group_id(tb)
    end
  end

  describe "next_agent_group/1 and prev_agent_group/1" do
    test "next_agent_group wraps around" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, g1} = TabBar.add_agent_group(tb, "Agent 1")
      tb = TabBar.move_tab_to_group(tb, 2, g1.id)
      {tb, g2} = TabBar.add_agent_group(tb, "Agent 2")
      {tb, _} = TabBar.add(tb, :file, "c.ex")
      tb = TabBar.move_tab_to_group(tb, 3, g2.id)

      # Start on g2
      tb = TabBar.switch_to_group(tb, g2.id)
      assert TabBar.active_group_id(tb) == g2.id

      # Next wraps to g1 (no manual workspace to cycle through)
      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == g1.id
    end

    test "prev_agent_group wraps around" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, g1} = TabBar.add_agent_group(tb, "Agent 1")
      tb = TabBar.move_tab_to_group(tb, 2, g1.id)
      {tb, g2} = TabBar.add_agent_group(tb, "Agent 2")
      {tb, _} = TabBar.add(tb, :file, "c.ex")
      tb = TabBar.move_tab_to_group(tb, 3, g2.id)

      # Start on g1
      tb = TabBar.switch_to_group(tb, g1.id)

      # Prev wraps to g2
      tb = TabBar.prev_agent_group(tb)
      assert TabBar.active_group_id(tb) == g2.id
    end

    test "next_agent_group on single workspace is a no-op" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      tb2 = TabBar.next_agent_group(tb)
      assert tb2 == tb
    end

    test "prev_agent_group on single workspace is a no-op" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      tb2 = TabBar.prev_agent_group(tb)
      assert tb2 == tb
    end
  end

  describe "next_agent_group/1" do
    test "cycles through agent workspaces only, skipping manual" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, ws1} = TabBar.add_agent_group(tb, "Agent 1")
      tb = TabBar.move_tab_to_group(tb, 2, ws1.id)
      {tb, ws2} = TabBar.add_agent_group(tb, "Agent 2")
      {tb, _} = TabBar.add(tb, :file, "c.ex")
      tb = TabBar.move_tab_to_group(tb, 3, ws2.id)

      # Start on manual
      tb = TabBar.switch_to_group(tb, 0)
      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == ws1.id

      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == ws2.id

      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == ws1.id
    end

    test "no agent workspaces returns unchanged" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      tb2 = TabBar.next_agent_group(tb)
      assert tb2 == tb
    end

    test "single agent workspace always lands on it" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, ws} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.move_tab_to_group(tb, 2, ws.id)

      # Start on manual
      tb = TabBar.switch_to_group(tb, 0)
      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == ws.id

      tb = TabBar.next_agent_group(tb)
      assert TabBar.active_group_id(tb) == ws.id
    end
  end

  describe "disclosure_tier/1" do
    test "tier 0: no agent workspaces" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.disclosure_tier(tb) == 0
    end

    test "tier 1: exactly one agent workspace" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add_agent_group(tb, "Agent")
      assert TabBar.disclosure_tier(tb) == 1
    end

    test "tier 2: 2-4 agent workspaces" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add_agent_group(tb, "A1")
      {tb, _} = TabBar.add_agent_group(tb, "A2")
      assert TabBar.disclosure_tier(tb) == 2

      {tb, _} = TabBar.add_agent_group(tb, "A3")
      {tb, _} = TabBar.add_agent_group(tb, "A4")
      assert TabBar.disclosure_tier(tb) == 2
    end

    test "tier 3: 5+ agent workspaces" do
      tb = TabBar.new(file_tab(1, "a.ex"))

      tb =
        Enum.reduce(1..5, tb, fn i, acc ->
          {acc, _} = TabBar.add_agent_group(acc, "A#{i}")
          acc
        end)

      assert TabBar.disclosure_tier(tb) == 3
    end
  end

  describe "find_group_by_session/2" do
    test "finds workspace matching session pid" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, ws} = TabBar.add_agent_group(tb, "Agent", self())
      found = TabBar.find_group_by_session(tb, self())
      assert found.id == ws.id
    end

    test "returns nil when no workspace matches" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.find_group_by_session(tb, self()) == nil
    end
  end

  describe "active_group/1 and get_group/2" do
    test "active_group returns nil for ungrouped tabs" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.active_group(tb) == nil
    end

    test "active_group returns the group when tab is in one" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_agent_group(tb, "Test")
      tb = TabBar.move_tab_to_group(tb, 2, group.id)
      tb = TabBar.switch_to_group(tb, group.id)
      assert TabBar.active_group(tb).id == group.id
    end

    test "get_group returns nil for missing id" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      assert TabBar.get_group(tb, 999) == nil
    end
  end

  describe "has_agent_groups?/1" do
    test "false with only manual" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      refute TabBar.has_agent_groups?(tb)
    end

    test "true after adding agent workspace" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, _} = TabBar.add_agent_group(tb, "Agent")
      assert TabBar.has_agent_groups?(tb)
    end
  end

  describe "update_group/3" do
    test "updates workspace via function" do
      tb = TabBar.new(file_tab(1, "a.ex"))
      {tb, ws} = TabBar.add_agent_group(tb, "Agent")
      tb = TabBar.update_group(tb, ws.id, &AgentGroup.set_agent_status(&1, :error))
      assert TabBar.get_group(tb, ws.id).agent_status == :error
    end
  end
end
