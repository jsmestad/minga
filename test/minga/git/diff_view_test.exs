defmodule Minga.Git.DiffViewTest do
  @moduledoc "Tests for Minga.Git.DiffView: unified diff view builder."
  use ExUnit.Case, async: true

  alias Minga.Git.DiffView

  describe "build/2" do
    test "returns 'No changes' for identical content" do
      result = DiffView.build("hello\nworld\n", "hello\nworld\n")
      assert result.text == "No changes"
      assert result.hunk_lines == []
    end

    test "shows added lines" do
      base = "line1\nline3\n"
      current = "line1\nline2\nline3\n"

      result = DiffView.build(base, current)
      lines = String.split(result.text, "\n")

      # Should contain the added line
      assert "line2" in lines

      # Should have at least one :added metadata entry
      added_meta = Enum.filter(result.line_metadata, fn m -> m.type == :added end)
      assert length(added_meta) > 0
    end

    test "shows deleted lines" do
      base = "line1\nline2\nline3\n"
      current = "line1\nline3\n"

      result = DiffView.build(base, current)
      lines = String.split(result.text, "\n")

      # Should contain the deleted line from HEAD
      assert "line2" in lines

      # Should have :removed metadata
      removed_meta = Enum.filter(result.line_metadata, fn m -> m.type == :removed end)
      assert length(removed_meta) > 0
    end

    test "shows modified lines as removed + added" do
      base = "line1\nold_line\nline3\n"
      current = "line1\nnew_line\nline3\n"

      result = DiffView.build(base, current)
      lines = String.split(result.text, "\n")

      assert "old_line" in lines
      assert "new_line" in lines

      removed = Enum.filter(result.line_metadata, fn m -> m.type == :removed end)
      added = Enum.filter(result.line_metadata, fn m -> m.type == :added end)
      assert length(removed) > 0
      assert length(added) > 0
    end

    test "folds large unchanged regions" do
      # Create content with many unchanged lines between hunks
      base_lines = Enum.map(1..20, &"line #{&1}")
      current_lines = List.replace_at(base_lines, 0, "changed line 1")
      current_lines = List.replace_at(current_lines, 19, "changed line 20")

      base = Enum.join(base_lines, "\n")
      current = Enum.join(current_lines, "\n")

      result = DiffView.build(base, current)

      # Should have fold metadata for the large unchanged region
      fold_meta = Enum.filter(result.line_metadata, fn m -> m.type == :fold end)
      assert length(fold_meta) > 0

      # The fold should indicate how many lines were hidden
      fold = hd(fold_meta)
      assert fold.fold_count > 0
    end

    test "tracks hunk line indices" do
      base = "aaa\nbbb\nccc\n"
      current = "aaa\nXXX\nccc\n"

      result = DiffView.build(base, current)
      assert is_list(result.hunk_lines)
      assert length(result.hunk_lines) > 0
    end

    test "handles empty base (new file)" do
      result = DiffView.build("", "new content\nhere\n")
      lines = String.split(result.text, "\n")
      assert "new content" in lines

      added = Enum.filter(result.line_metadata, fn m -> m.type == :added end)
      assert length(added) > 0
    end

    test "handles empty current (deleted file)" do
      result = DiffView.build("old content\nhere\n", "")
      lines = String.split(result.text, "\n")
      assert "old content" in lines

      removed = Enum.filter(result.line_metadata, fn m -> m.type == :removed end)
      assert length(removed) > 0
    end
  end
end
