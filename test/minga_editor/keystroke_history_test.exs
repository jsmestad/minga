defmodule MingaEditor.KeystrokeHistoryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias MingaEditor.KeystrokeHistory

  defp make_entry(opts \\ []) do
    %{
      key: Keyword.get(opts, :key, {?j, 0}),
      mode_before: Keyword.get(opts, :mode_before, :normal),
      mode_after: Keyword.get(opts, :mode_after, :normal),
      timestamp: Keyword.get(opts, :timestamp, 1_000_000)
    }
  end

  describe "new/0" do
    test "creates empty history with default max size" do
      h = KeystrokeHistory.new()
      assert h.entries == []
      assert h.count == 0
      assert h.max_size == 200
    end
  end

  describe "new/1" do
    test "creates empty history with custom max size" do
      h = KeystrokeHistory.new(5)
      assert h.max_size == 5
      assert h.count == 0
    end
  end

  describe "record/2" do
    test "adds an entry" do
      h = KeystrokeHistory.new() |> KeystrokeHistory.record(make_entry())
      assert KeystrokeHistory.size(h) == 1
    end

    test "preserves entry data" do
      entry = make_entry(key: {?k, 0x02}, mode_before: :insert, mode_after: :normal)
      h = KeystrokeHistory.new() |> KeystrokeHistory.record(entry)
      [recorded] = KeystrokeHistory.entries(h)
      assert recorded.key == {?k, 0x02}
      assert recorded.mode_before == :insert
      assert recorded.mode_after == :normal
    end

    test "multiple entries accumulate" do
      h =
        KeystrokeHistory.new()
        |> KeystrokeHistory.record(make_entry(key: {?a, 0}))
        |> KeystrokeHistory.record(make_entry(key: {?b, 0}))
        |> KeystrokeHistory.record(make_entry(key: {?c, 0}))

      assert KeystrokeHistory.size(h) == 3
    end
  end

  describe "entries/1" do
    test "returns entries in chronological order" do
      h =
        KeystrokeHistory.new()
        |> KeystrokeHistory.record(make_entry(key: {?a, 0}, timestamp: 1))
        |> KeystrokeHistory.record(make_entry(key: {?b, 0}, timestamp: 2))
        |> KeystrokeHistory.record(make_entry(key: {?c, 0}, timestamp: 3))

      keys = Enum.map(KeystrokeHistory.entries(h), & &1.key)
      assert keys == [{?a, 0}, {?b, 0}, {?c, 0}]
    end

    test "empty history returns empty list" do
      assert KeystrokeHistory.entries(KeystrokeHistory.new()) == []
    end
  end

  describe "ring buffer truncation" do
    test "truncates oldest entries when exceeding max_size" do
      h = KeystrokeHistory.new(3)

      h =
        Enum.reduce(1..5, h, fn i, acc ->
          KeystrokeHistory.record(acc, make_entry(key: {i, 0}, timestamp: i))
        end)

      assert KeystrokeHistory.size(h) == 3
      keys = Enum.map(KeystrokeHistory.entries(h), & &1.key)
      assert keys == [{3, 0}, {4, 0}, {5, 0}]
    end

    test "stays at max_size after many insertions" do
      h = KeystrokeHistory.new(5)

      h =
        Enum.reduce(1..100, h, fn i, acc ->
          KeystrokeHistory.record(acc, make_entry(key: {i, 0}))
        end)

      assert KeystrokeHistory.size(h) == 5
    end
  end

  describe "size/1" do
    test "returns 0 for empty history" do
      assert KeystrokeHistory.size(KeystrokeHistory.new()) == 0
    end

    test "returns correct count" do
      h =
        KeystrokeHistory.new()
        |> KeystrokeHistory.record(make_entry())
        |> KeystrokeHistory.record(make_entry())

      assert KeystrokeHistory.size(h) == 2
    end
  end
end
