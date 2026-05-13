defmodule Minga.Core.DiffViewTest do
  @moduledoc "Tests for Minga.Core.DiffView: unified diff view builder."
  use ExUnit.Case, async: true

  alias Minga.Core.DiffView

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
      assert [_ | _] = added_meta
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
      assert [_ | _] = removed_meta
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
      assert [_ | _] = removed
      assert [_ | _] = added
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
      assert [_ | _] = fold_meta

      # The fold should indicate how many lines were hidden
      fold = hd(fold_meta)
      assert fold.fold_count > 0
    end

    test "tracks hunk line indices" do
      base = "aaa\nbbb\nccc\n"
      current = "aaa\nXXX\nccc\n"

      result = DiffView.build(base, current)
      assert is_list(result.hunk_lines)
      assert [_ | _] = result.hunk_lines
    end

    test "handles empty base (new file)" do
      result = DiffView.build("", "new content\nhere\n")
      lines = String.split(result.text, "\n")
      assert "new content" in lines

      added = Enum.filter(result.line_metadata, fn m -> m.type == :added end)
      assert [_ | _] = added
    end

    test "handles empty current (deleted file)" do
      result = DiffView.build("old content\nhere\n", "")
      lines = String.split(result.text, "\n")
      assert "old content" in lines

      removed = Enum.filter(result.line_metadata, fn m -> m.type == :removed end)
      assert [_ | _] = removed
    end
  end

  describe "word_changes in metadata" do
    test "modified lines carry word_changes in metadata" do
      base = "line1\nhello world\nline3\n"
      current = "line1\nhello earth\nline3\n"

      result = DiffView.build(base, current)

      removed_meta =
        Enum.filter(result.line_metadata, fn m ->
          m.type == :removed and m.word_changes != nil
        end)

      added_meta =
        Enum.filter(result.line_metadata, fn m ->
          m.type == :added and m.word_changes != nil
        end)

      # The modified hunk should produce paired lines with word_changes
      assert [_ | _] = removed_meta
      assert [_ | _] = added_meta

      # Each word_changes entry should be a list of {start, end} tuples
      [removed_line | _] = removed_meta
      assert is_list(removed_line.word_changes)

      Enum.each(removed_line.word_changes, fn {start_col, end_col} ->
        assert is_integer(start_col)
        assert is_integer(end_col)
        assert end_col > start_col
      end)
    end

    test "inserted lines inside multi-line modified hunks are not paired with unrelated old lines" do
      base = "foo one\nbar two\n"
      current = "foo uno\nINSERTED\nbar dos\n"

      result = DiffView.build(base, current)
      lines_with_meta = Enum.zip(String.split(result.text, "\n"), result.line_metadata)

      assert Enum.any?(lines_with_meta, fn
               {"foo uno", %{type: :added, word_changes: [_ | _]}} -> true
               _ -> false
             end)

      assert Enum.any?(lines_with_meta, fn
               {"INSERTED", %{type: :added, word_changes: nil}} -> true
               _ -> false
             end)

      assert Enum.any?(lines_with_meta, fn
               {"bar dos", %{type: :added, word_changes: [_ | _]}} -> true
               _ -> false
             end)
    end

    test "deleted lines inside multi-line modified hunks are not paired with unrelated new lines" do
      base = "foo one\nREMOVED\nbar two\n"
      current = "foo uno\nbar dos\n"

      result = DiffView.build(base, current)
      lines_with_meta = Enum.zip(String.split(result.text, "\n"), result.line_metadata)

      assert Enum.any?(lines_with_meta, fn
               {"foo one", %{type: :removed, word_changes: [_ | _]}} -> true
               _ -> false
             end)

      assert Enum.any?(lines_with_meta, fn
               {"REMOVED", %{type: :removed, word_changes: nil}} -> true
               _ -> false
             end)

      assert Enum.any?(lines_with_meta, fn
               {"bar two", %{type: :removed, word_changes: [_ | _]}} -> true
               _ -> false
             end)
    end

    test "large uneven modified hunks fall back to full-line changes" do
      base = Enum.map_join(1..21, "\n", &"old #{&1}")
      current = Enum.map_join(1..20, "\n", &"new #{&1}")

      result = DiffView.build(base, current)
      changed_meta = Enum.filter(result.line_metadata, fn m -> m.type in [:added, :removed] end)

      assert length(changed_meta) == 41
      assert Enum.all?(changed_meta, fn m -> m.word_changes == nil end)
    end

    test "added-only lines have nil word_changes" do
      base = "line1\n"
      current = "line1\nnew line\n"

      result = DiffView.build(base, current)

      added_meta = Enum.filter(result.line_metadata, fn m -> m.type == :added end)
      assert [_ | _] = added_meta

      # Pure additions (not from a modified hunk) have nil word_changes
      Enum.each(added_meta, fn m ->
        assert m.word_changes == nil
      end)
    end

    test "deleted-only lines have nil word_changes" do
      base = "line1\nold line\n"
      current = "line1\n"

      result = DiffView.build(base, current)

      removed_meta = Enum.filter(result.line_metadata, fn m -> m.type == :removed end)
      assert [_ | _] = removed_meta

      Enum.each(removed_meta, fn m ->
        assert m.word_changes == nil
      end)
    end

    test "context and fold lines have nil word_changes" do
      # Create content with a fold region
      base_lines = Enum.map(1..20, &"line #{&1}")
      current_lines = List.replace_at(base_lines, 0, "changed line 1")
      current_lines = List.replace_at(current_lines, 19, "changed line 20")

      base = Enum.join(base_lines, "\n")
      current = Enum.join(current_lines, "\n")

      result = DiffView.build(base, current)

      context_meta = Enum.filter(result.line_metadata, fn m -> m.type == :context end)
      fold_meta = Enum.filter(result.line_metadata, fn m -> m.type == :fold end)

      Enum.each(context_meta, fn m -> assert m.word_changes == nil end)
      Enum.each(fold_meta, fn m -> assert m.word_changes == nil end)
    end

    test "all metadata entries include word_changes key" do
      base = "aaa\nbbb\nccc\n"
      current = "aaa\nXXX\nccc\n"

      result = DiffView.build(base, current)

      Enum.each(result.line_metadata, fn m ->
        assert Map.has_key?(m, :word_changes)
      end)
    end
  end
end
