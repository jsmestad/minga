defmodule Minga.Editor.TabBarRendererTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.TabBarRenderer
  alias Minga.Theme

  defp doom_theme, do: Theme.get!(:doom_one)

  describe "render/4 basics" do
    test "produces draws and click regions for a single tab" do
      tab = Tab.new_file(1, "main.ex")
      tb = TabBar.new(tab)

      {draws, regions} = TabBarRenderer.render(0, 80, tb, doom_theme())

      assert draws != []
      assert regions != []

      # All draws at row 0
      assert Enum.all?(draws, fn {row, _, _, _} -> row == 0 end)

      # Click region maps to tab_goto_1
      assert Enum.any?(regions, fn {_, _, cmd} -> cmd == :tab_goto_1 end)
    end

    test "active tab uses active colors, inactive uses inactive" do
      tab1 = Tab.new_file(1, "one.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "two.ex")
      # Switch back to tab 1 so it's active
      tb = TabBar.switch_to(tb, 1)

      theme = doom_theme()
      colors = Map.from_struct(theme.tab_bar)

      {draws, _} = TabBarRenderer.render(0, 80, tb, theme)

      # Find draws for active (one.ex) and inactive (two.ex)
      active_draw = Enum.find(draws, fn {_, _, text, _} -> String.contains?(text, "one.ex") end)
      inactive_draw = Enum.find(draws, fn {_, _, text, _} -> String.contains?(text, "two.ex") end)

      assert active_draw != nil
      {_, _, _, active_style} = active_draw
      assert Keyword.get(active_style, :bg) == colors.active_bg

      assert inactive_draw != nil
      {_, _, _, inactive_style} = inactive_draw
      assert Keyword.get(inactive_style, :bg) == colors.inactive_bg
    end

    test "fills remaining width with background" do
      tab = Tab.new_file(1, "x.ex")
      tb = TabBar.new(tab)

      {draws, _} = TabBarRenderer.render(0, 80, tb, doom_theme())

      # Last draw should be a fill (spaces with bg color)
      last = List.last(draws)
      {_, _, text, _} = last
      assert String.trim(text) == ""
    end

    test "powerline separator between tabs" do
      tab1 = Tab.new_file(1, "a.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "b.ex")

      {draws, _} = TabBarRenderer.render(0, 80, tb, doom_theme())

      # Should contain a Powerline character
      all_text = Enum.map_join(draws, fn {_, _, text, _} -> text end)
      assert String.contains?(all_text, "")
    end
  end

  describe "click regions" do
    test "each tab has a click region" do
      tab1 = Tab.new_file(1, "a.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, _} = TabBar.add(tb, :agent, "Agent")

      {_, regions} = TabBarRenderer.render(0, 80, tb, doom_theme())

      commands = Enum.map(regions, fn {_, _, cmd} -> cmd end) |> MapSet.new()
      assert :tab_goto_1 in commands
      assert :tab_goto_2 in commands
      assert :tab_goto_3 in commands
    end

    test "click regions don't overlap" do
      tab1 = Tab.new_file(1, "first.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "second.ex")
      {tb, _} = TabBar.add(tb, :file, "third.ex")

      {_, regions} = TabBarRenderer.render(0, 120, tb, doom_theme())

      sorted = Enum.sort_by(regions, fn {start, _, _} -> start end)

      Enum.chunk_every(sorted, 2, 1, :discard)
      |> Enum.each(fn [{_, end1, _}, {start2, _, _}] ->
        assert end1 < start2, "Regions overlap: end=#{end1} >= start=#{start2}"
      end)
    end
  end

  describe "overflow" do
    test "many tabs overflow the terminal width" do
      tab1 = Tab.new_file(1, "first_very_long_filename.ex")
      tb = TabBar.new(tab1)

      tb =
        Enum.reduce(2..20, tb, fn i, acc ->
          {new_tb, _} = TabBar.add(acc, :file, "long_file_name_#{i}.ex")
          new_tb
        end)

      # Render in a narrow terminal
      {draws, _regions} = TabBarRenderer.render(0, 40, tb, doom_theme())

      all_text = Enum.map_join(draws, fn {_, _, text, _} -> text end)

      # Should show overflow indicators
      assert String.contains?(all_text, "◂") or String.contains?(all_text, "▸")
    end

    test "active tab is always visible in overflow" do
      tab1 = Tab.new_file(1, "start.ex")
      tb = TabBar.new(tab1)

      tb =
        Enum.reduce(2..15, tb, fn i, acc ->
          {new_tb, _} = TabBar.add(acc, :file, "file_#{i}.ex")
          new_tb
        end)

      # Switch to a tab in the middle
      tb = TabBar.switch_to(tb, 8)

      {draws, regions} = TabBarRenderer.render(0, 50, tb, doom_theme())

      # The active tab's click region should exist
      assert Enum.any?(regions, fn {_, _, cmd} -> cmd == :tab_goto_8 end)

      # The active tab's label should appear in the draws
      all_text = Enum.map_join(draws, fn {_, _, text, _} -> text end)
      assert String.contains?(all_text, "file_8.ex")
    end
  end

  describe "agent tabs" do
    test "agent tab shows agent icon" do
      tab = Tab.new_agent(1, "My Session")
      tb = TabBar.new(tab)

      {draws, _} = TabBarRenderer.render(0, 80, tb, doom_theme())

      all_text = Enum.map_join(draws, fn {_, _, text, _} -> text end)
      assert String.contains?(all_text, "󰚩")
    end
  end
end
