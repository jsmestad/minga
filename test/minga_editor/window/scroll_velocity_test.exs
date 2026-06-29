defmodule MingaEditor.Window.ScrollVelocityTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Window.ScrollVelocity

  describe "tier/2" do
    test "new estimator returns :idle" do
      sv = ScrollVelocity.new()
      assert ScrollVelocity.tier(sv, 1000) == :idle
    end

    test "few events within a window returns :idle" do
      sv =
        ScrollVelocity.new()
        |> ScrollVelocity.record(1000, :down)
        |> ScrollVelocity.record(1010, :down)
        |> ScrollVelocity.record(1020, :down)

      assert ScrollVelocity.tier(sv, 1025) == :idle
    end

    test "exactly 5 events returns :medium" do
      sv =
        Enum.reduce(1..5, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 10, :down)
        end)

      assert ScrollVelocity.tier(sv, 1055) == :medium
    end

    test "4 events returns :idle (below medium threshold)" do
      sv =
        Enum.reduce(1..4, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 10, :down)
        end)

      assert ScrollVelocity.tier(sv, 1045) == :idle
    end

    test "exactly 10 events returns :fast" do
      sv =
        Enum.reduce(1..10, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5, :down)
        end)

      assert ScrollVelocity.tier(sv, 1055) == :fast
    end

    test "9 events returns :medium (below fast threshold)" do
      sv =
        Enum.reduce(1..9, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5, :down)
        end)

      assert ScrollVelocity.tier(sv, 1050) == :medium
    end

    test "decays to :idle after 200ms with no events" do
      sv =
        Enum.reduce(1..16, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5, :down)
        end)

      assert ScrollVelocity.tier(sv, 1082) == :fast
      assert ScrollVelocity.tier(sv, 1280) == :fast
      assert ScrollVelocity.tier(sv, 1283) == :idle
    end

    test "sustained scrolling across window reset maintains tier via prev_count" do
      sv =
        Enum.reduce(1..16, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5, :down)
        end)

      assert ScrollVelocity.tier(sv, 1082) == :fast

      sv = ScrollVelocity.record(sv, 1150, :down)
      assert sv.count == 1
      assert sv.prev_count == 16
      assert ScrollVelocity.tier(sv, 1155) == :fast
    end

    test "window resets after 100ms gap" do
      sv =
        Enum.reduce(1..9, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5, :down)
        end)

      assert ScrollVelocity.tier(sv, 1050) == :medium

      sv = ScrollVelocity.record(sv, 1200, :down)
      assert ScrollVelocity.tier(sv, 1205) == :medium
    end

    test "prev_count decays after two window resets with few events" do
      sv =
        Enum.reduce(1..16, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5, :down)
        end)

      assert ScrollVelocity.tier(sv, 1082) == :fast

      sv = ScrollVelocity.record(sv, 1200, :down)
      assert ScrollVelocity.tier(sv, 1205) == :fast

      sv = ScrollVelocity.record(sv, 1400, :down)
      assert ScrollVelocity.tier(sv, 1405) == :idle
    end

    test "works with negative monotonic timestamps" do
      sv =
        ScrollVelocity.new()
        |> ScrollVelocity.record(-5000, :down)
        |> ScrollVelocity.record(-4990, :down)
        |> ScrollVelocity.record(-4980, :down)
        |> ScrollVelocity.record(-4970, :down)
        |> ScrollVelocity.record(-4960, :down)

      assert ScrollVelocity.tier(sv, -4955) == :medium
    end
  end

  describe "direction/2" do
    test "new estimator returns :ambiguous" do
      sv = ScrollVelocity.new()
      assert ScrollVelocity.direction(sv, 1000) == :ambiguous
    end

    test "uniform down events return :down" do
      sv =
        Enum.reduce(1..5, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 10, :down)
        end)

      assert ScrollVelocity.direction(sv, 1055) == :down
    end

    test "uniform up events return :up" do
      sv =
        Enum.reduce(1..5, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 10, :up)
        end)

      assert ScrollVelocity.direction(sv, 1055) == :up
    end

    test "mixed events return :ambiguous" do
      sv =
        ScrollVelocity.new()
        |> ScrollVelocity.record(1000, :down)
        |> ScrollVelocity.record(1010, :down)
        |> ScrollVelocity.record(1020, :up)
        |> ScrollVelocity.record(1030, :up)
        |> ScrollVelocity.record(1040, :down)

      assert ScrollVelocity.direction(sv, 1045) == :ambiguous
    end

    test "4 of 5 down events returns :down" do
      sv =
        ScrollVelocity.new()
        |> ScrollVelocity.record(1000, :down)
        |> ScrollVelocity.record(1010, :down)
        |> ScrollVelocity.record(1020, :down)
        |> ScrollVelocity.record(1030, :down)
        |> ScrollVelocity.record(1040, :up)

      assert ScrollVelocity.direction(sv, 1045) == :down
    end

    test "4 of 5 up events returns :up" do
      sv =
        ScrollVelocity.new()
        |> ScrollVelocity.record(1000, :up)
        |> ScrollVelocity.record(1010, :up)
        |> ScrollVelocity.record(1020, :up)
        |> ScrollVelocity.record(1030, :up)
        |> ScrollVelocity.record(1040, :down)

      assert ScrollVelocity.direction(sv, 1045) == :up
    end

    test "direction decays to :ambiguous after 200ms" do
      sv =
        Enum.reduce(1..5, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 10, :down)
        end)

      assert ScrollVelocity.direction(sv, 1055) == :down
      assert ScrollVelocity.direction(sv, 1255) == :ambiguous
    end

    test "direction window is capped at 5 most recent events" do
      sv =
        Enum.reduce(1..5, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5, :down)
        end)

      assert ScrollVelocity.direction(sv, 1030) == :down

      sv =
        Enum.reduce(1..5, sv, fn i, acc ->
          ScrollVelocity.record(acc, 1030 + i * 5, :up)
        end)

      assert ScrollVelocity.direction(sv, 1060) == :up
    end
  end
end
