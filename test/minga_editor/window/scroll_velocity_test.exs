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
        |> ScrollVelocity.record(1000)
        |> ScrollVelocity.record(1010)
        |> ScrollVelocity.record(1020)

      assert ScrollVelocity.tier(sv, 1025) == :idle
    end

    test "exactly 5 events returns :medium" do
      sv =
        Enum.reduce(1..5, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 10)
        end)

      assert ScrollVelocity.tier(sv, 1055) == :medium
    end

    test "4 events returns :idle (below medium threshold)" do
      sv =
        Enum.reduce(1..4, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 10)
        end)

      assert ScrollVelocity.tier(sv, 1045) == :idle
    end

    test "exactly 15 events returns :fast" do
      sv =
        Enum.reduce(1..15, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1080) == :fast
    end

    test "14 events returns :medium (below fast threshold)" do
      sv =
        Enum.reduce(1..14, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1075) == :medium
    end

    test "decays to :idle after 200ms with no events" do
      sv =
        Enum.reduce(1..16, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1082) == :fast
      assert ScrollVelocity.tier(sv, 1280) == :fast
      assert ScrollVelocity.tier(sv, 1283) == :idle
    end

    test "sustained scrolling across window reset maintains tier via prev_count" do
      sv =
        Enum.reduce(1..16, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1082) == :fast

      sv = ScrollVelocity.record(sv, 1150)
      assert sv.count == 1
      assert sv.prev_count == 16
      assert ScrollVelocity.tier(sv, 1155) == :fast
    end

    test "window resets after 100ms gap" do
      sv =
        Enum.reduce(1..10, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1055) == :medium

      sv = ScrollVelocity.record(sv, 1200)
      assert ScrollVelocity.tier(sv, 1205) == :medium
    end

    test "prev_count decays after two window resets with few events" do
      sv =
        Enum.reduce(1..16, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1082) == :fast

      sv = ScrollVelocity.record(sv, 1200)
      assert ScrollVelocity.tier(sv, 1205) == :fast

      sv = ScrollVelocity.record(sv, 1400)
      assert ScrollVelocity.tier(sv, 1405) == :idle
    end

    test "works with negative monotonic timestamps" do
      sv =
        ScrollVelocity.new()
        |> ScrollVelocity.record(-5000)
        |> ScrollVelocity.record(-4990)
        |> ScrollVelocity.record(-4980)
        |> ScrollVelocity.record(-4970)
        |> ScrollVelocity.record(-4960)

      assert ScrollVelocity.tier(sv, -4955) == :medium
    end
  end
end
