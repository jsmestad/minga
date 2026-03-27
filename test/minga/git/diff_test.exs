defmodule Minga.Core.DiffTest do
  @moduledoc "Tests for in-memory line diffing and hunk operations."

  use ExUnit.Case, async: true

  alias Minga.Core.Diff

  # ── diff_lines/2 ───────────────────────────────────────────────────────────

  describe "diff_lines/2" do
    test "identical files produce no hunks" do
      lines = ["a", "b", "c"]
      assert Diff.diff_lines(lines, lines) == []
    end

    test "detects added lines" do
      base = ["a", "b"]
      current = ["a", "b", "c", "d"]

      hunks = Diff.diff_lines(base, current)
      assert length(hunks) == 1
      [hunk] = hunks
      assert hunk.type == :added
      assert hunk.start_line == 2
      assert hunk.count == 2
    end

    test "detects deleted lines" do
      base = ["a", "b", "c"]
      current = ["a"]

      hunks = Diff.diff_lines(base, current)
      assert length(hunks) == 1
      [hunk] = hunks
      assert hunk.type == :deleted
      assert hunk.start_line == 1
      assert hunk.count == 0
      assert hunk.old_lines == ["b", "c"]
    end

    test "detects modified lines" do
      base = ["a", "b", "c"]
      current = ["a", "x", "c"]

      hunks = Diff.diff_lines(base, current)
      assert length(hunks) == 1
      [hunk] = hunks
      assert hunk.type == :modified
      assert hunk.start_line == 1
      assert hunk.count == 1
      assert hunk.old_lines == ["b"]
    end

    test "detects mixed changes" do
      base = ["a", "b", "c", "d", "e"]
      current = ["a", "x", "c", "f", "g", "e"]

      hunks = Diff.diff_lines(base, current)
      assert length(hunks) == 2

      [first, second] = hunks
      assert first.type == :modified
      assert first.start_line == 1

      assert second.type == :modified
      assert second.start_line == 3
    end

    test "empty base means all lines are added" do
      hunks = Diff.diff_lines([], ["a", "b"])
      assert length(hunks) == 1
      [hunk] = hunks
      assert hunk.type == :added
      assert hunk.count == 2
    end

    test "empty current means all lines are deleted" do
      hunks = Diff.diff_lines(["a", "b"], [])
      assert length(hunks) == 1
      [hunk] = hunks
      assert hunk.type == :deleted
      assert hunk.old_lines == ["a", "b"]
    end

    test "both empty produces no hunks" do
      assert Diff.diff_lines([], []) == []
    end
  end

  # ── signs_for_hunks/1 ─────────────────────────────────────────────────────

  describe "signs_for_hunks/1" do
    test "maps added lines to their line numbers" do
      hunks = [
        %{type: :added, start_line: 3, count: 2, old_start: 3, old_count: 0, old_lines: []}
      ]

      signs = Diff.signs_for_hunks(hunks)

      assert signs[3] == :added
      assert signs[4] == :added
      assert signs[2] == nil
    end

    test "maps modified lines to their line numbers" do
      hunks = [
        %{type: :modified, start_line: 1, count: 1, old_start: 1, old_count: 1, old_lines: ["x"]}
      ]

      signs = Diff.signs_for_hunks(hunks)

      assert signs[1] == :modified
    end

    test "maps deleted hunks to the line above" do
      hunks = [
        %{
          type: :deleted,
          start_line: 3,
          count: 0,
          old_start: 3,
          old_count: 2,
          old_lines: ["a", "b"]
        }
      ]

      signs = Diff.signs_for_hunks(hunks)

      assert signs[2] == :deleted
    end

    test "deleted at start of file maps to line 0" do
      hunks = [
        %{type: :deleted, start_line: 0, count: 0, old_start: 0, old_count: 1, old_lines: ["a"]}
      ]

      signs = Diff.signs_for_hunks(hunks)

      assert signs[0] == :deleted
    end
  end

  # ── hunk_at_line/2 ─────────────────────────────────────────────────────────

  describe "hunk_at_line/2" do
    test "finds hunk containing the line" do
      hunk = %{type: :added, start_line: 5, count: 3, old_start: 5, old_count: 0, old_lines: []}
      assert Diff.hunk_at_line([hunk], 6) == hunk
    end

    test "returns nil when no hunk at line" do
      hunk = %{type: :added, start_line: 5, count: 3, old_start: 5, old_count: 0, old_lines: []}
      assert Diff.hunk_at_line([hunk], 10) == nil
    end

    test "empty hunk list returns nil" do
      assert Diff.hunk_at_line([], 0) == nil
    end
  end

  # ── next_hunk_line/2 and prev_hunk_line/2 ──────────────────────────────────

  describe "navigation" do
    setup do
      hunks = [
        %{type: :added, start_line: 3, count: 2, old_start: 3, old_count: 0, old_lines: []},
        %{
          type: :modified,
          start_line: 10,
          count: 1,
          old_start: 8,
          old_count: 1,
          old_lines: ["x"]
        },
        %{type: :deleted, start_line: 20, count: 0, old_start: 18, old_count: 1, old_lines: ["y"]}
      ]

      %{hunks: hunks}
    end

    test "next_hunk_line finds the next hunk", %{hunks: hunks} do
      assert Diff.next_hunk_line(hunks, 0) == 3
      assert Diff.next_hunk_line(hunks, 5) == 10
      assert Diff.next_hunk_line(hunks, 15) == 20
    end

    test "next_hunk_line returns nil at end", %{hunks: hunks} do
      assert Diff.next_hunk_line(hunks, 20) == nil
    end

    test "prev_hunk_line finds the previous hunk", %{hunks: hunks} do
      assert Diff.prev_hunk_line(hunks, 25) == 20
      assert Diff.prev_hunk_line(hunks, 15) == 10
      assert Diff.prev_hunk_line(hunks, 5) == 3
    end

    test "prev_hunk_line returns nil at start", %{hunks: hunks} do
      assert Diff.prev_hunk_line(hunks, 0) == nil
    end
  end

  # ── revert_hunk/2 ─────────────────────────────────────────────────────────

  describe "revert_hunk/2" do
    test "reverts added lines" do
      current = ["a", "b", "new1", "new2", "c"]
      hunk = %{type: :added, start_line: 2, count: 2, old_start: 2, old_count: 0, old_lines: []}

      assert Diff.revert_hunk(current, hunk) == ["a", "b", "c"]
    end

    test "reverts modified lines" do
      current = ["a", "changed", "c"]

      hunk = %{
        type: :modified,
        start_line: 1,
        count: 1,
        old_start: 1,
        old_count: 1,
        old_lines: ["original"]
      }

      assert Diff.revert_hunk(current, hunk) == ["a", "original", "c"]
    end

    test "reverts deleted lines" do
      current = ["a", "c"]

      hunk = %{
        type: :deleted,
        start_line: 1,
        count: 0,
        old_start: 1,
        old_count: 1,
        old_lines: ["b"]
      }

      assert Diff.revert_hunk(current, hunk) == ["a", "b", "c"]
    end
  end

  # ── generate_patch/4 ───────────────────────────────────────────────────────

  describe "generate_patch/4" do
    test "generates valid unified diff format" do
      base = ["a", "b", "c", "d", "e"]
      current = ["a", "b", "x", "d", "e"]

      hunk = %{
        type: :modified,
        start_line: 2,
        count: 1,
        old_start: 2,
        old_count: 1,
        old_lines: ["c"]
      }

      patch = Diff.generate_patch("test.ex", base, current, hunk)

      assert String.contains?(patch, "--- a/test.ex")
      assert String.contains?(patch, "+++ b/test.ex")
      assert String.contains?(patch, "@@")
      assert String.contains?(patch, "-c")
      assert String.contains?(patch, "+x")
    end
  end
end
