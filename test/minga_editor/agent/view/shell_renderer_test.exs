defmodule MingaEditor.Agent.View.ShellRendererTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.View.ShellRenderer
  alias MingaEditor.UI.Theme

  defp default_theme do
    {:ok, theme} = Theme.get(:doom_one)
    theme
  end

  describe "render/8" do
    test "renders header with command name" do
      rect = {0, 0, 60, 20}

      draws =
        ShellRenderer.render(rect, "mix test", "output\n", :running, 0, false, 0, default_theme())

      texts = Enum.map(draws, fn {_r, _c, text, _opts} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "mix test"))
    end

    test "renders running status with spinner" do
      rect = {0, 0, 60, 20}
      draws = ShellRenderer.render(rect, "ls", "", :running, 0, false, 3, default_theme())
      # Header row should have a braille spinner char
      header = Enum.find(draws, fn {r, _c, _t, _o} -> r == 0 end)
      {_, _, text, _} = header

      assert String.match?(text, ~r/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/)
    end

    test "renders done status with checkmark" do
      rect = {0, 0, 60, 20}
      draws = ShellRenderer.render(rect, "echo hi", "hi\n", :done, 0, false, 0, default_theme())
      header = Enum.find(draws, fn {r, _c, _t, _o} -> r == 0 end)
      {_, _, text, _} = header
      assert String.contains?(text, "✓")
    end

    test "renders error status with cross" do
      rect = {0, 0, 60, 20}
      draws = ShellRenderer.render(rect, "false", "exit 1", :error, 0, false, 0, default_theme())
      header = Enum.find(draws, fn {r, _c, _t, _o} -> r == 0 end)
      {_, _, text, _} = header
      assert String.contains?(text, "✗")
    end

    test "renders output lines with line numbers" do
      output = "line one\nline two\nline three"
      rect = {0, 0, 60, 20}
      draws = ShellRenderer.render(rect, "cat", output, :done, 0, false, 0, default_theme())
      texts = Enum.map(draws, fn {_r, _c, text, _opts} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "1"))
      assert Enum.any?(texts, &String.contains?(&1, "line one"))
    end

    test "scrolling skips top lines" do
      output = Enum.map_join(1..50, "\n", &"line #{&1}")
      rect = {0, 0, 60, 10}
      draws = ShellRenderer.render(rect, "seq", output, :done, 5, false, 0, default_theme())
      texts = Enum.map(draws, fn {_r, _c, text, _opts} -> text end)
      # Line 6 should be visible (scroll=5, so skip first 5 lines)
      assert Enum.any?(texts, &String.contains?(&1, "line 6"))
    end

    test "fills remaining rows when output is short" do
      rect = {0, 0, 40, 10}
      draws = ShellRenderer.render(rect, "echo", "hi", :done, 0, false, 0, default_theme())
      # Should have draws for all 10 rows (header + 9 content)
      rows = Enum.map(draws, fn {r, _c, _t, _o} -> r end) |> Enum.uniq() |> Enum.sort()
      assert length(rows) >= 10
    end
  end
end
