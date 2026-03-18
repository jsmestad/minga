defmodule Minga.Editor.TabBarRendererTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.TabBarRenderer
  alias Minga.Theme
  alias Minga.Face

  defp doom_theme, do: Theme.get!(:doom_one)

  describe "render/5 basics" do
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
      assert active_style.bg == colors.active_bg

      assert inactive_draw != nil
      {_, _, _, inactive_style} = inactive_draw
      assert inactive_style.bg == colors.inactive_bg
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
      assert String.contains?(all_text, "\u{E0B0}")
    end
  end

  describe "close button" do
    test "active tab shows close icon" do
      tab = Tab.new_file(1, "main.ex")
      tb = TabBar.new(tab)

      {draws, _} = TabBarRenderer.render(0, 80, tb, doom_theme())

      all_text = Enum.map_join(draws, fn {_, _, text, _} -> text end)
      assert String.contains?(all_text, "✕")
    end

    test "inactive tab hides close icon when not hovered" do
      tab1 = Tab.new_file(1, "one.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "two.ex")
      tb = TabBar.switch_to(tb, 1)

      theme = doom_theme()
      colors = Map.from_struct(theme.tab_bar)

      {draws, _} = TabBarRenderer.render(0, 80, tb, theme, nil)

      # Find the close icon draw for the inactive tab (two.ex).
      # The close draw is the draw command right after the body draw
      # containing "two.ex". Its fg should match the inactive tab's bg
      # (invisible).
      inactive_body_idx =
        Enum.find_index(draws, fn {_, _, text, _} -> String.contains?(text, "two.ex") end)

      assert inactive_body_idx != nil
      close_draw = Enum.at(draws, inactive_body_idx + 1)
      {_, _, _close_text, close_style} = close_draw
      assert close_style.fg == colors.inactive_bg
    end

    test "inactive tab shows close icon when hovered" do
      tab1 = Tab.new_file(1, "one.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "two.ex")
      tb = TabBar.switch_to(tb, 1)

      theme = doom_theme()
      colors = Map.from_struct(theme.tab_bar)

      # Render once without hover to find the inactive tab's column range
      {draws, _} = TabBarRenderer.render(0, 120, tb, theme, nil)

      inactive_draw =
        Enum.find(draws, fn {_, _, text, _} -> String.contains?(text, "two.ex") end)

      {_, inactive_col, _, _} = inactive_draw

      # Now render with hover_col inside the inactive tab's region
      {draws_hovered, _} = TabBarRenderer.render(0, 120, tb, theme, inactive_col + 1)

      # Find the close draw for the inactive tab
      inactive_body_idx =
        Enum.find_index(draws_hovered, fn {_, _, text, _} -> String.contains?(text, "two.ex") end)

      close_draw = Enum.at(draws_hovered, inactive_body_idx + 1)
      {_, _, close_text, close_style} = close_draw
      assert String.contains?(close_text, "✕")
      assert close_style.fg == colors.close_hover_fg
    end

    test "close icon on active tab uses close_hover_fg color" do
      tab = Tab.new_file(1, "main.ex")
      tb = TabBar.new(tab)

      theme = doom_theme()
      colors = Map.from_struct(theme.tab_bar)

      {draws, _} = TabBarRenderer.render(0, 80, tb, theme)

      close_draw = Enum.find(draws, fn {_, _, text, _} -> String.contains?(text, "✕") end)
      assert close_draw != nil
      {_, _, _, close_style} = close_draw
      assert close_style.fg == colors.close_hover_fg
    end

    test "tab widths are stable regardless of hover state" do
      tab1 = Tab.new_file(1, "one.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "two.ex")
      tb = TabBar.switch_to(tb, 1)

      theme = doom_theme()

      # Render without hover
      {draws_no_hover, _} = TabBarRenderer.render(0, 120, tb, theme, nil)

      # Find the column of the inactive tab's body
      inactive_draw_no_hover =
        Enum.find(draws_no_hover, fn {_, _, text, _} -> String.contains?(text, "two.ex") end)

      {_, col_no_hover, _, _} = inactive_draw_no_hover

      # Render with hover on the inactive tab
      {draws_hover, _} = TabBarRenderer.render(0, 120, tb, theme, col_no_hover + 1)

      inactive_draw_hover =
        Enum.find(draws_hover, fn {_, _, text, _} -> String.contains?(text, "two.ex") end)

      {_, col_hover, _, _} = inactive_draw_hover

      # Tab position should be identical
      assert col_no_hover == col_hover
    end
  end

  describe "click regions" do
    test "each tab has goto and close click regions" do
      tab1 = Tab.new_file(1, "a.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, _} = TabBar.add(tb, :agent, "Agent")

      {_, regions} = TabBarRenderer.render(0, 80, tb, doom_theme())

      commands = Enum.map(regions, fn {_, _, cmd} -> cmd end) |> MapSet.new()

      # Goto regions
      assert :tab_goto_1 in commands
      assert :tab_goto_2 in commands
      assert :tab_goto_3 in commands

      # Close regions
      assert :tab_close_1 in commands
      assert :tab_close_2 in commands
      assert :tab_close_3 in commands
    end

    test "goto and close regions for the same tab don't overlap" do
      tab1 = Tab.new_file(1, "main.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "other.ex")

      {_, regions} = TabBarRenderer.render(0, 120, tb, doom_theme())

      # Check each tab's goto and close regions don't overlap
      for tab_id <- [1, 2] do
        goto = Enum.find(regions, fn {_, _, cmd} -> cmd == :"tab_goto_#{tab_id}" end)
        close = Enum.find(regions, fn {_, _, cmd} -> cmd == :"tab_close_#{tab_id}" end)

        assert goto != nil, "Missing goto region for tab #{tab_id}"
        assert close != nil, "Missing close region for tab #{tab_id}"

        {_, goto_end, _} = goto
        {close_start, _, _} = close

        assert goto_end < close_start,
               "Tab #{tab_id} goto (end=#{goto_end}) overlaps close (start=#{close_start})"
      end
    end

    test "all click regions across tabs don't overlap" do
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

    test "close region comes after goto region for the same tab" do
      tab = Tab.new_file(1, "test.ex")
      tb = TabBar.new(tab)

      {_, regions} = TabBarRenderer.render(0, 80, tb, doom_theme())

      goto = Enum.find(regions, fn {_, _, cmd} -> cmd == :tab_goto_1 end)
      close = Enum.find(regions, fn {_, _, cmd} -> cmd == :tab_close_1 end)

      {goto_start, _, _} = goto
      {close_start, _, _} = close

      assert close_start > goto_start
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

  describe "tab numbers" do
    test "tabs 1-9 show position number" do
      tab1 = Tab.new_file(1, "a.ex")
      tb = TabBar.new(tab1)
      {tb, _} = TabBar.add(tb, :file, "b.ex")
      {tb, _} = TabBar.add(tb, :file, "c.ex")

      {draws, _} = TabBarRenderer.render(0, 120, tb, doom_theme())

      all_text = Enum.map_join(draws, fn {_, _, text, _} -> text end)
      assert String.contains?(all_text, "1:")
      assert String.contains?(all_text, "2:")
      assert String.contains?(all_text, "3:")
    end
  end

  describe "agent tabs" do
    test "agent tab shows agent icon" do
      tab = Tab.new_agent(1, "My Session")
      tb = TabBar.new(tab)

      {draws, _} = TabBarRenderer.render(0, 80, tb, doom_theme())

      all_text = Enum.map_join(draws, fn {_, _, text, _} -> text end)
      assert String.contains?(all_text, "\u{F06A9}")
    end
  end
end
