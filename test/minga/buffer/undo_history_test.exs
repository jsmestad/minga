defmodule Minga.Buffer.UndoHistoryTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Document
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.UndoPatch

  # Recording calls take a monotonic timestamp, so tests drive the coalescing clock instead of sleeping.
  @t0 1_000
  @window UndoHistory.coalesce_ms()

  defp doc(text), do: Document.new(text)

  defp patch(before_text, after_text),
    do: UndoPatch.from_documents(doc(before_text), doc(after_text))

  defp force(history, version, before_text, after_text, source, at \\ @t0),
    do:
      UndoHistory.record_edit_force(history, version, patch(before_text, after_text), source, at)

  describe "record_edit/5" do
    test "records an undo patch with source attribution" do
      history =
        UndoHistory.record_edit(UndoHistory.new(), 0, patch("before", "after"), :agent, @t0)

      assert UndoHistory.undo_count(history) == 1
      assert UndoHistory.redo_count(history) == 0
      assert UndoHistory.last_undo_source(history) == :agent
    end

    test "coalesces same-source edits inside the window into one undo entry" do
      history =
        UndoHistory.new()
        |> UndoHistory.record_edit(0, patch("", "a"), :user, @t0)
        |> UndoHistory.record_edit(1, patch("a", "ab"), :user, @t0 + @window - 1)

      assert UndoHistory.undo_count(history) == 1
      assert {:ok, restore, _history} = UndoHistory.undo(history, 2, doc("ab"))
      assert Document.content(restore.document) == ""
    end

    test "an edit at or after the window boundary starts a new undo entry" do
      history =
        UndoHistory.new()
        |> UndoHistory.record_edit(0, patch("", "a"), :user, @t0)
        |> UndoHistory.record_edit(1, patch("a", "ab"), :user, @t0 + @window)

      assert UndoHistory.undo_count(history) == 2
    end

    test "the window is measured from the last recorded edit, not the first" do
      history =
        UndoHistory.new()
        |> UndoHistory.record_edit(0, patch("", "a"), :user, @t0)
        |> UndoHistory.record_edit(1, patch("a", "ab"), :user, @t0 + @window - 1)
        |> UndoHistory.record_edit(2, patch("ab", "abc"), :user, @t0 + 2 * @window - 2)

      assert UndoHistory.undo_count(history) == 1
    end

    test "break_coalescing makes the next edit create a new entry" do
      history =
        UndoHistory.new()
        |> UndoHistory.record_edit(0, patch("", "a"), :user, @t0)
        |> UndoHistory.break_coalescing()
        |> UndoHistory.record_edit(1, patch("a", "ab"), :user, @t0 + 1)

      assert UndoHistory.undo_count(history) == 2
    end

    test "different sources do not coalesce into one entry" do
      history =
        UndoHistory.new()
        |> UndoHistory.record_edit(0, patch("", "a"), :user, @t0)
        |> UndoHistory.record_edit(1, patch("a", "ab"), :agent, @t0 + 1)

      assert UndoHistory.undo_count(history) == 2
      assert UndoHistory.last_undo_source(history) == :agent
    end

    test "force recording bypasses coalescing and clears redo entries" do
      history = force(UndoHistory.new(), 0, "before", "after", :agent)

      assert {:ok, restore, history} = UndoHistory.undo(history, 1, doc("after"))
      assert restore.source == :agent
      assert UndoHistory.redo_count(history) == 1

      history = force(history, 1, "before", "new", :user)

      assert UndoHistory.undo_count(history) == 1
      assert UndoHistory.redo_count(history) == 0
      assert UndoHistory.last_undo_source(history) == :user
    end

    test "a forced entry still anchors the coalescing window for following edits" do
      history =
        UndoHistory.new()
        |> force(0, "", "a", :user)
        |> UndoHistory.record_edit(1, patch("a", "ab"), :user, @t0 + 1)

      assert UndoHistory.undo_count(history) == 1
    end

    test "batch recording stores one undo entry" do
      patches = [patch("aXc", "abc"), patch("abc", "aXc")]
      history = UndoHistory.record_edit_batch(UndoHistory.new(), 0, patches, :lsp, @t0)

      assert UndoHistory.undo_count(history) == 1
      assert UndoHistory.last_undo_source(history) == :lsp
    end

    test "caps undo entries" do
      history =
        Enum.reduce(1..1100, UndoHistory.new(), fn version, history ->
          force(
            history,
            version,
            Integer.to_string(version),
            Integer.to_string(version + 1),
            :user,
            @t0 + version
          )
        end)

      assert UndoHistory.undo_count(history) == 1000
    end
  end

  describe "undo/3 and redo/3" do
    test "undo returns the previous document and creates a redo entry" do
      history = force(UndoHistory.new(), 0, "before", "after", :lsp)

      assert {:ok, restore, history} = UndoHistory.undo(history, 1, doc("after"))
      assert restore.version == 0
      assert restore.source == :lsp
      assert Document.content(restore.document) == "before"
      assert UndoHistory.undo_count(history) == 0
      assert UndoHistory.redo_count(history) == 1
      assert UndoHistory.last_redo_source(history) == :lsp
    end

    test "redo returns the next document and restores undo history" do
      history = force(UndoHistory.new(), 0, "before", "after", :recovery)

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

  describe "undo_agent_session/3" do
    test "undoes all consecutive agent entries from top of stack" do
      history =
        UndoHistory.new()
        |> force(0, "", "user typed", :user)
        |> force(1, "user typed", "user typed\nagent line 1", :agent)
        |> force(2, "user typed\nagent line 1", "user typed\nagent line 1\nagent line 2", :agent)

      assert {:ok, restore, new_history, 2} =
               UndoHistory.undo_agent_session(
                 history,
                 3,
                 doc("user typed\nagent line 1\nagent line 2")
               )

      assert Document.content(restore.document) == "user typed"
      assert restore.source == :agent
      assert UndoHistory.undo_count(new_history) == 1
      assert UndoHistory.redo_count(new_history) == 2
      assert UndoHistory.last_undo_source(new_history) == :user
    end

    test "returns :empty when top entry is not agent-sourced" do
      history = force(UndoHistory.new(), 0, "", "user typed", :user)

      assert :empty = UndoHistory.undo_agent_session(history, 1, doc("user typed"))
    end

    test "returns :empty on empty history" do
      assert :empty = UndoHistory.undo_agent_session(UndoHistory.new(), 0, doc(""))
    end

    test "stops at first non-agent entry" do
      history =
        UndoHistory.new()
        |> force(0, "", "lsp edit", :lsp)
        |> force(1, "lsp edit", "lsp edit\nagent edit", :agent)

      assert {:ok, restore, new_history, 1} =
               UndoHistory.undo_agent_session(history, 2, doc("lsp edit\nagent edit"))

      assert Document.content(restore.document) == "lsp edit"
      assert UndoHistory.undo_count(new_history) == 1
      assert UndoHistory.last_undo_source(new_history) == :lsp
    end

    test "undoes single agent entry" do
      history = force(UndoHistory.new(), 0, "original", "agent modified", :agent)

      assert {:ok, restore, _new_history, 1} =
               UndoHistory.undo_agent_session(history, 1, doc("agent modified"))

      assert Document.content(restore.document) == "original"
    end
  end

  describe "clear/1" do
    test "removes undo and redo entries" do
      history = force(UndoHistory.new(), 0, "before", "after", :user)

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
