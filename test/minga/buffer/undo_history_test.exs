defmodule Minga.Buffer.UndoHistoryTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.UndoPatch

  defp doc(text), do: Document.new(text)

  defp patch(before_text, after_text),
    do: UndoPatch.from_documents(doc(before_text), doc(after_text))

  describe "record_edit/4" do
    test "records an undo patch with source attribution" do
      history = UndoHistory.record_edit(UndoHistory.new(), 0, patch("before", "after"), :agent)

      assert UndoHistory.undo_count(history) == 1
      assert UndoHistory.redo_count(history) == 0
      assert UndoHistory.last_undo_source(history) == :agent
    end

    test "coalesces rapid edits into one undo entry with multiple patches" do
      history =
        UndoHistory.new()
        |> UndoHistory.record_edit(0, patch("", "a"), :user)
        |> UndoHistory.record_edit(1, patch("a", "ab"), :user)

      assert UndoHistory.undo_count(history) == 1
      assert {:ok, restore, _history} = UndoHistory.undo(history, 2, doc("ab"))
      assert Document.content(restore.document) == ""
    end

    test "break_coalescing makes the next edit create a new entry" do
      history =
        UndoHistory.new()
        |> UndoHistory.record_edit(0, patch("", "a"), :user)
        |> UndoHistory.break_coalescing()
        |> UndoHistory.record_edit(1, patch("a", "ab"), :user)

      assert UndoHistory.undo_count(history) == 2
    end

    test "different sources do not coalesce into one entry" do
      history =
        UndoHistory.new()
        |> UndoHistory.record_edit(0, patch("", "a"), :user)
        |> UndoHistory.record_edit(1, patch("a", "ab"), :agent)

      assert UndoHistory.undo_count(history) == 2
      assert UndoHistory.last_undo_source(history) == :agent
    end

    test "force recording bypasses coalescing and clears redo entries" do
      history =
        UndoHistory.record_edit_force(UndoHistory.new(), 0, patch("before", "after"), :agent)

      assert {:ok, restore, history} = UndoHistory.undo(history, 1, doc("after"))
      assert restore.source == :agent
      assert UndoHistory.redo_count(history) == 1

      history = UndoHistory.record_edit_force(history, 1, patch("before", "new"), :user)

      assert UndoHistory.undo_count(history) == 1
      assert UndoHistory.redo_count(history) == 0
      assert UndoHistory.last_undo_source(history) == :user
    end

    test "batch recording stores one undo entry" do
      patches = [patch("aXc", "abc"), patch("abc", "aXc")]
      history = UndoHistory.record_edit_batch(UndoHistory.new(), 0, patches, :lsp)

      assert UndoHistory.undo_count(history) == 1
      assert UndoHistory.last_undo_source(history) == :lsp
    end

    test "caps undo entries" do
      history =
        Enum.reduce(1..1100, UndoHistory.new(), fn version, history ->
          UndoHistory.record_edit_force(
            history,
            version,
            patch(Integer.to_string(version), Integer.to_string(version + 1)),
            :user
          )
        end)

      assert UndoHistory.undo_count(history) == 1000
    end
  end

  describe "undo/3 and redo/3" do
    test "undo returns the previous document and creates a redo entry" do
      history =
        UndoHistory.record_edit_force(UndoHistory.new(), 0, patch("before", "after"), :lsp)

      assert {:ok, restore, history} = UndoHistory.undo(history, 1, doc("after"))
      assert restore.version == 0
      assert restore.source == :lsp
      assert Document.content(restore.document) == "before"
      assert UndoHistory.undo_count(history) == 0
      assert UndoHistory.redo_count(history) == 1
      assert UndoHistory.last_redo_source(history) == :lsp
    end

    test "redo returns the next document and restores undo history" do
      history =
        UndoHistory.record_edit_force(UndoHistory.new(), 0, patch("before", "after"), :recovery)

      assert {:ok, restore, history} = UndoHistory.undo(history, 1, doc("after"))
      assert restore.source == :recovery

      assert {:ok, restore, history} = UndoHistory.redo(history, 0, doc("before"))
      assert restore.version == 1
      assert restore.source == :recovery
      assert Document.content(restore.document) == "after"
      assert UndoHistory.undo_count(history) == 1
      assert UndoHistory.redo_count(history) == 0
      assert UndoHistory.last_undo_source(history) == :recovery
    end

    test "empty history cannot undo or redo" do
      history = UndoHistory.new()

      assert :empty = UndoHistory.undo(history, 0, doc("current"))
      assert :empty = UndoHistory.redo(history, 0, doc("current"))
    end
  end

  describe "clear/1" do
    test "removes undo and redo entries" do
      history =
        UndoHistory.record_edit_force(UndoHistory.new(), 0, patch("before", "after"), :user)

      assert {:ok, restore, history} = UndoHistory.undo(history, 1, doc("after"))
      assert restore.source == :user

      history = UndoHistory.clear(history)

      assert UndoHistory.undo_count(history) == 0
      assert UndoHistory.redo_count(history) == 0
      assert UndoHistory.last_undo_source(history) == nil
      assert UndoHistory.last_redo_source(history) == nil
    end
  end
end
