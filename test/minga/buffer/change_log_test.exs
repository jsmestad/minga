defmodule Minga.Buffer.ChangeLogTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.ChangeLog
  alias Minga.Buffer.EditDelta

  defp delta(text) do
    EditDelta.insertion(0, {0, 0}, text, {0, byte_size(text)})
  end

  describe "record_change/2" do
    test "records pending changes in edit order" do
      log =
        ChangeLog.new()
        |> ChangeLog.record_change(delta("a"))
        |> ChangeLog.record_change(delta("b"))

      assert {[a, b], log} = ChangeLog.drain_pending_changes(log)
      assert a.inserted_text == "a"
      assert b.inserted_text == "b"
      assert {[], _log} = ChangeLog.drain_pending_changes(log)
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

      assert {{:ok, changes}, log} = ChangeLog.take_unseen_changes(log, :lsp)
      assert length(changes) == 1100
      assert ChangeLog.retained_count(log) == 1000

      assert {:reset_required, _log} = ChangeLog.take_unseen_changes(log, :late_reader)
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

      assert {[], log} = ChangeLog.drain_pending_changes(log)
      assert {:reset_required, _log} = ChangeLog.take_unseen_changes(log, :lsp)
      assert ChangeLog.retained_count(log) == 0
    end
  end
end
