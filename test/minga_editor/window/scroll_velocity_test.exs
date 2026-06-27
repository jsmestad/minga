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

    test "5+ events within 100ms returns :medium" do
      sv =
        Enum.reduce(1..6, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 10)
        end)

      assert ScrollVelocity.tier(sv, 1065) == :medium
    end

    test "15+ events within 100ms returns :fast" do
      sv =
        Enum.reduce(1..16, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1082) == :fast
    end

    test "decays to :idle after 200ms with no events" do
      sv =
        Enum.reduce(1..16, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1082) == :fast
      assert ScrollVelocity.tier(sv, 1300) == :idle
    end

    test "window resets after 100ms gap" do
      sv =
        Enum.reduce(1..10, ScrollVelocity.new(), fn i, acc ->
          ScrollVelocity.record(acc, 1000 + i * 5)
        end)

      assert ScrollVelocity.tier(sv, 1055) == :medium

      sv = ScrollVelocity.record(sv, 1200)
      assert ScrollVelocity.tier(sv, 1205) == :idle
    end
  end
end
