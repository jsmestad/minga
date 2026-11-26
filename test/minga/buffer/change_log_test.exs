defmodule Minga.Buffer.ChangeLogTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.ChangeLog
  alias Minga.Buffer.EditDelta

  defp delta(text) do
    EditDelta.insertion(0, {0, 0}, text, {0, byte_size(text)})
  end

  describe "record_change/2" do
    test "records changes in edit order" do
      log =
        ChangeLog.new()
        |> ChangeLog.record_change(delta("a"))
        |> ChangeLog.record_change(delta("b"))

      assert {:ok, 2, [a, b]} = ChangeLog.changes_since(log, 0)
      assert a.inserted_text == "a"
      assert b.inserted_text == "b"
    end

    test "keeps no more than the retained entries, however many changes are recorded" do
      log = Enum.reduce(1..1_500, ChangeLog.new(), &ChangeLog.record_change(&2, delta("d#{&1}")))

      assert ChangeLog.retained_count(log) == 1_000

      # Nothing else in the log holds a delta: a stream of appended output is not retained twice.
      assert :erts_debug.flat_size(log) <
               2 * :erts_debug.flat_size(elem(ChangeLog.changes_since(log, 500), 2))
    end
  end

  describe "record_changes/2" do
    test "matches recording each delta in turn, including retention past the cap" do
      prior = ChangeLog.record_change(ChangeLog.new(), delta("seed"))
      {:ok, cursor, []} = ChangeLog.changes_since(prior, ChangeLog.sequence(prior))

      for count <- [0, 1, 3, 1_000, 1_005] do
        deltas = for i <- 1..count//1, do: delta("d#{i}")
        batched = ChangeLog.record_changes(prior, deltas)
        one_by_one = Enum.reduce(deltas, prior, &ChangeLog.record_change(&2, &1))

        assert ChangeLog.sequence(batched) == ChangeLog.sequence(one_by_one)

        assert ChangeLog.changes_since(batched, cursor) ==
                 ChangeLog.changes_since(one_by_one, cursor)

        assert ChangeLog.changes_since(batched, 0) == ChangeLog.changes_since(one_by_one, 0)
      end
    end
  end

  describe "take_unseen_changes/2" do
    test "readers see their own unseen changes without stealing from each other" do
      log =
        ChangeLog.new()
        |> ChangeLog.record_change(delta("a"))
        |> ChangeLog.record_change(delta("b"))

      assert {{:ok, [lsp_a, lsp_b]}, log} = ChangeLog.take_unseen_changes(log, :lsp)

      assert {{:ok, [highlight_a, highlight_b]}, _log} =
               ChangeLog.take_unseen_changes(log, :highlight)

      assert Enum.map([lsp_a, lsp_b], & &1.inserted_text) == ["a", "b"]
      assert Enum.map([highlight_a, highlight_b], & &1.inserted_text) == ["a", "b"]
    end

    test "a reader only sees changes recorded after its last read" do
      log =
        ChangeLog.new()
        |> ChangeLog.record_change(delta("a"))
        |> ChangeLog.record_change(delta("b"))

      assert {{:ok, [_a, _b]}, log} = ChangeLog.take_unseen_changes(log, :lsp)

      log = ChangeLog.record_change(log, delta("c"))

      assert {{:ok, [c]}, log} = ChangeLog.take_unseen_changes(log, :lsp)
      assert c.inserted_text == "c"
      assert {{:ok, []}, _log} = ChangeLog.take_unseen_changes(log, :lsp)
    end

    test "entries are trimmed after all registered readers catch up" do
      log =
        ChangeLog.new()
        |> ChangeLog.record_change(delta("a"))
        |> ChangeLog.record_change(delta("b"))

      assert {{:ok, [_a, _b]}, log} = ChangeLog.take_unseen_changes(log, :lsp)
      assert ChangeLog.retained_count(log) == 2

      assert {{:ok, [_a, _b]}, log} = ChangeLog.take_unseen_changes(log, :highlight)
      assert ChangeLog.retained_count(log) == 0
      assert {:reset_required, _log} = ChangeLog.take_unseen_changes(log, :late_reader)
    end

    test "entries are capped while only one reader is registered" do
      log =
        Enum.reduce(1..1100, ChangeLog.new(), fn i, acc ->
          ChangeLog.record_change(acc, delta(Integer.to_string(i)))
        end)

      assert {:reset_required, log} = ChangeLog.take_unseen_changes(log, :lsp)
      assert ChangeLog.retained_count(log) == 1000
      assert {:reset_required, _log} = ChangeLog.take_unseen_changes(log, :late_reader)
    end
  end

  describe "changes_since/2" do
    test "is sequence-qualified and non-mutating" do
      log =
        ChangeLog.new()
        |> ChangeLog.record_change(delta("a"))
        |> ChangeLog.record_change(delta("b"))

      assert {:ok, 2, changes} = ChangeLog.changes_since(log, 0)
      assert Enum.map(changes, & &1.inserted_text) == ["a", "b"]
      assert {:ok, 2, ^changes} = ChangeLog.changes_since(log, 0)
      assert ChangeLog.sequence(log) == 2
      assert ChangeLog.horizon(log) == 1
    end

    test "clear advances the sequence and exposes an explicit gap" do
      log = ChangeLog.new() |> ChangeLog.record_change(delta("a"))
      cleared = ChangeLog.clear(log)

      assert {:reset_required, 2} = ChangeLog.changes_since(cleared, 1)
      assert ChangeLog.horizon(cleared) == 3
    end
  end

  describe "clear/1" do
    test "removes pending changes, retained entries, and reader positions" do
      log =
        ChangeLog.new()
        |> ChangeLog.record_change(delta("a"))
        |> ChangeLog.record_change(delta("b"))

      assert {{:ok, [_a, _b]}, log} = ChangeLog.take_unseen_changes(log, :lsp)

      log = ChangeLog.clear(log)

      assert {:reset_required, _log} = ChangeLog.take_unseen_changes(log, :lsp)
      assert ChangeLog.retained_count(log) == 0
    end
  end
end
