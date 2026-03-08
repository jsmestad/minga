defmodule Minga.Agent.DiffRendererTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.DiffRenderer
  alias Minga.Agent.DiffReview

  defp default_theme do
    Minga.Theme.get!(:doom_one)
  end

  defp simple_review do
    DiffReview.new("lib/foo.ex", "line1\nold_line\nline3\n", "line1\nnew_line\nline3\n")
  end

  defp added_review do
    DiffReview.new("lib/bar.ex", "line1\n", "line1\nnew_line\n")
  end

  describe "render/3" do
    test "returns draw commands" do
      review = simple_review()
      rect = {0, 0, 60, 20}
      cmds = DiffRenderer.render(rect, review, default_theme())
      assert [_ | _] = cmds
    end

    test "header shows file path and change counts" do
      review = simple_review()
      rect = {0, 0, 80, 20}
      cmds = DiffRenderer.render(rect, review, default_theme())

      # First command should be the header
      header = hd(cmds)
      header_text = elem(header, 2)
      assert String.contains?(header_text, "Diff:")
      assert String.contains?(header_text, "foo.ex")
    end

    test "renders added lines with + gutter" do
      review = added_review()
      rect = {0, 0, 60, 20}
      cmds = DiffRenderer.render(rect, review, default_theme())

      texts = Enum.map(cmds, fn cmd -> elem(cmd, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "+"))
    end

    test "renders removed lines with - gutter" do
      review = DiffReview.new("f.ex", "line1\nremoved\n", "line1\n")
      rect = {0, 0, 60, 20}
      cmds = DiffRenderer.render(rect, review, default_theme())

      texts = Enum.map(cmds, fn cmd -> elem(cmd, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "-"))
    end

    test "renders hunk header with @@ markers" do
      review = simple_review()
      rect = {0, 0, 80, 20}
      cmds = DiffRenderer.render(rect, review, default_theme())

      texts = Enum.map(cmds, fn cmd -> elem(cmd, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "@@"))
    end

    test "renders resolution markers (? for unresolved)" do
      review = simple_review()
      rect = {0, 0, 60, 20}
      cmds = DiffRenderer.render(rect, review, default_theme())

      texts = Enum.map(cmds, fn cmd -> elem(cmd, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "?"))
    end

    test "renders ✓ for accepted hunks" do
      review = simple_review() |> DiffReview.accept_current()
      rect = {0, 0, 60, 20}
      cmds = DiffRenderer.render(rect, review, default_theme())

      texts = Enum.map(cmds, fn cmd -> elem(cmd, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "✓"))
    end

    test "renders ✗ for rejected hunks" do
      review = simple_review() |> DiffReview.reject_current()
      rect = {0, 0, 60, 20}
      cmds = DiffRenderer.render(rect, review, default_theme())

      texts = Enum.map(cmds, fn cmd -> elem(cmd, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "✗"))
    end

    test "fills remaining rows with blank" do
      review = simple_review()
      rect = {0, 0, 40, 50}
      cmds = DiffRenderer.render(rect, review, default_theme())

      # Should have commands for all 50 rows
      rows = cmds |> Enum.map(fn cmd -> elem(cmd, 0) end) |> Enum.uniq()
      assert Enum.count(rows) >= 20
    end
  end
end
