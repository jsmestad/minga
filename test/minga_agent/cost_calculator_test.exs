defmodule MingaAgent.CostCalculatorTest do
  use ExUnit.Case, async: true

  alias MingaAgent.CostCalculator
  alias MingaAgent.TurnUsage

  describe "ensure_cost/3" do
    test "preserves existing non-zero cost" do
      usage = %TurnUsage{input: 1000, output: 500, cache_read: 0, cache_write: 0, cost: 0.05}

      result = CostCalculator.ensure_cost(usage, "claude-sonnet-4-20250514", :anthropic)
      assert result.cost == 0.05
    end

    test "calculates cost when existing cost is zero" do
      usage = %TurnUsage{
        input: 1_000_000,
        output: 500_000,
        cache_read: 0,
        cache_write: 0,
        cost: 0.0
      }

      result = CostCalculator.ensure_cost(usage, "claude-sonnet-4-20250514", :anthropic)
      # input: 1M tokens * $3/MTok = $3.00
      # output: 500k tokens * $15/MTok = $7.50
      # Total: $10.50
      assert result.cost > 0.0
    end
  end

  describe "calculate_cost/3" do
    test "returns zero for unknown model" do
      usage = %TurnUsage{input: 1000, output: 500}

      assert CostCalculator.calculate_cost(usage, "nonexistent-model", :unknown) == 0.0
    end

    test "includes cache read and write costs" do
      usage = %TurnUsage{input: 0, output: 0, cache_read: 1_000_000, cache_write: 1_000_000}

      cost = CostCalculator.calculate_cost(usage, "claude-sonnet-4-20250514", :anthropic)
      # cache_read: 1M * $0.30/MTok = $0.30
      # cache_write: 1M * $3.75/MTok = $3.75
      assert cost > 0.0
    end
  end
end
