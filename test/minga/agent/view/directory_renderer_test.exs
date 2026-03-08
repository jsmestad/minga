defmodule Minga.Agent.View.DirectoryRendererTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.View.DirectoryRenderer
  alias Minga.Theme

  defp default_theme do
    {:ok, theme} = Theme.get(:doom_one)
    theme
  end

  describe "render/5" do
    test "renders header with directory path" do
      rect = {0, 0, 60, 20}
      draws = DirectoryRenderer.render(rect, "lib/minga", ["foo.ex", "bar/"], 0, default_theme())
      texts = Enum.map(draws, fn {_r, _c, text, _opts} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "lib/minga"))
    end

    test "renders file entries with file icon" do
      rect = {0, 0, 60, 20}
      draws = DirectoryRenderer.render(rect, ".", ["README.md"], 0, default_theme())
      texts = Enum.map(draws, fn {_r, _c, text, _opts} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "📄"))
      assert Enum.any?(texts, &String.contains?(&1, "README.md"))
    end

    test "renders directory entries with folder icon" do
      rect = {0, 0, 60, 20}
      draws = DirectoryRenderer.render(rect, ".", ["src/", "lib/"], 0, default_theme())
      texts = Enum.map(draws, fn {_r, _c, text, _opts} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "📁"))
      assert Enum.any?(texts, &String.contains?(&1, "src/"))
    end

    test "renders mixed files and directories" do
      entries = ["lib/", "mix.exs", "test/", "README.md"]
      rect = {0, 0, 60, 20}
      draws = DirectoryRenderer.render(rect, ".", entries, 0, default_theme())
      texts = Enum.map(draws, fn {_r, _c, text, _opts} -> text end)

      assert Enum.any?(texts, &String.contains?(&1, "📁"))
      assert Enum.any?(texts, &String.contains?(&1, "📄"))
    end

    test "scrolling skips top entries" do
      entries = Enum.map(1..50, &"file_#{&1}.ex")
      rect = {0, 0, 60, 10}
      draws = DirectoryRenderer.render(rect, ".", entries, 5, default_theme())
      texts = Enum.map(draws, fn {_r, _c, text, _opts} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "file_6.ex"))
    end

    test "fills remaining rows when entries are short" do
      rect = {0, 0, 40, 10}
      draws = DirectoryRenderer.render(rect, ".", ["a.ex"], 0, default_theme())
      rows = Enum.map(draws, fn {r, _c, _t, _o} -> r end) |> Enum.uniq() |> Enum.sort()
      assert length(rows) >= 10
    end

    test "handles empty entry list" do
      rect = {0, 0, 60, 10}
      draws = DirectoryRenderer.render(rect, ".", [], 0, default_theme())
      assert [_ | _] = draws
    end
  end
end
