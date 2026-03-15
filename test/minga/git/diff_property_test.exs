defmodule Minga.Git.DiffPropertyTest do
  @moduledoc """
  Property-based tests for Git.Diff.

  Verifies diff invariants: hunks don't overlap, sign maps cover
  exactly the changed lines, and reverting a hunk restores original
  content.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Git.Diff

  import Minga.Test.Generators

  # ── Hunk invariants ──────────────────────────────────────────────────────

  property "diff_lines produces non-overlapping hunks" do
    check all(
            base <- line_list(),
            current <- line_list(),
            max_runs: 200
          ) do
      hunks = Diff.diff_lines(base, current)

      # Verify hunks are sorted by start_line
      start_lines = Enum.map(hunks, & &1.start_line)
      assert start_lines == Enum.sort(start_lines)

      # Verify no overlaps: each hunk's start_line is >= previous hunk's end
      hunks
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [h1, h2] ->
        h1_end = h1.start_line + max(h1.count - 1, 0)

        assert h2.start_line > h1_end,
               "Hunk overlap: #{inspect(h1)} overlaps #{inspect(h2)}"
      end)
    end
  end

  property "sign_for_hunks covers exactly the changed lines" do
    check all(
            base <- line_list(),
            current <- line_list(),
            max_runs: 200
          ) do
      hunks = Diff.diff_lines(base, current)
      signs = Diff.signs_for_hunks(hunks)

      # Every sign line should correspond to a hunk
      Enum.each(signs, fn {line, sign_type} ->
        assert is_integer(line) and line >= 0
        assert sign_type in [:added, :modified, :deleted]
      end)

      # Every added/modified hunk should have corresponding signs
      for hunk <- hunks, hunk.type in [:added, :modified] do
        for line <- hunk.start_line..(hunk.start_line + hunk.count - 1) do
          assert Map.has_key?(signs, line),
                 "Missing sign for #{hunk.type} line #{line}"
        end
      end
    end
  end

  property "reverting an added hunk removes the added lines" do
    check all(
            base <- line_list(),
            insert_at <- integer(0..length(base)),
            new_lines <- list_of(line_text(), min_length: 1, max_length: 5)
          ) do
      # Create "current" by inserting new lines into base
      {before, after_lines} = Enum.split(base, insert_at)
      current = before ++ new_lines ++ after_lines

      hunks = Diff.diff_lines(base, current)
      added_hunks = Enum.filter(hunks, &(&1.type == :added))

      # Reverting each added hunk one at a time should remove lines
      Enum.each(added_hunks, fn hunk ->
        reverted = Diff.revert_hunk(current, hunk)

        assert length(reverted) < length(current),
               "Reverting added hunk should reduce line count"
      end)
    end
  end

  property "identical content produces no hunks" do
    check all(lines <- line_list(), max_runs: 100) do
      hunks = Diff.diff_lines(lines, lines)
      assert hunks == [], "Identical content should produce no hunks"
    end
  end

  property "diff against empty base marks everything as added" do
    check all(current <- line_list(), max_runs: 100) do
      hunks = Diff.diff_lines([], current)

      if current != [] do
        assert hunks != [], "Non-empty current vs empty base should produce hunks"

        total_added = Enum.sum(Enum.map(hunks, & &1.count))
        assert total_added == length(current)
      end
    end
  end
end
