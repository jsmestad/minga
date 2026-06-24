defmodule MingaAgent.TurnUsageTest do
  use ExUnit.Case, async: true

  alias MingaAgent.TurnUsage

  describe "new/0" do
    test "creates a zero-value usage record" do
      u = TurnUsage.new()
      assert u.input == 0
      assert u.output == 0
      assert u.cache_read == 0
      assert u.cache_write == 0
      assert u.cost == 0.0
    end
  end

  describe "new/5" do
    test "creates a usage record with given values" do
      u = TurnUsage.new(100, 50, 200, 10, 0.05)
      assert u.input == 100
      assert u.output == 50
      assert u.cache_read == 200
      assert u.cache_write == 10
      assert u.cost == 0.05
    end
  end

  describe "add/2" do
    test "sums two usage records" do
      a = TurnUsage.new(100, 50, 10, 5, 0.01)
      b = TurnUsage.new(200, 100, 20, 10, 0.02)
      sum = TurnUsage.add(a, b)

      assert sum.input == 300
      assert sum.output == 150
      assert sum.cache_read == 30
      assert sum.cache_write == 15
      assert_in_delta sum.cost, 0.03, 0.0001
    end

    test "adding zero is identity" do
      a = TurnUsage.new(100, 50, 0, 0, 0.01)
      zero = TurnUsage.new()
      assert TurnUsage.add(a, zero) == a
    end
  end

  describe "format_short/1" do
    test "formats as short summary" do
      u = TurnUsage.new(100, 50, 0, 0, 0.01)
      assert TurnUsage.format_short(u) == "↑100 ↓50 $0.01"
    end
  end

  describe "cache_hit_rate/1" do
    test "reports the cached share of input tokens" do
      u = TurnUsage.new(1_000, 50, 750, 100, 0.01)
      assert TurnUsage.cache_hit_rate(u) == 0.75
    end

    test "returns zero when no input tokens were reported" do
      assert TurnUsage.cache_hit_rate(TurnUsage.new()) == 0.0
    end
  end

  describe "format_cost_report/1" do
    test "includes input output cache and cost fields for parity comparisons" do
      u = TurnUsage.new(1_000, 50, 750, 100, 0.01)

      assert TurnUsage.format_cost_report(u) ==
               "input=1000 output=50 cache_read=750 cache_write=100 cache_hit_rate=75.0% cost=$0.01"
    end
  end
end
