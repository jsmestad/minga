defmodule Minga.Agent.ContextBarTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.View.DashboardRenderer

  describe "context_fill_pct/2" do
    test "returns nil for unknown models" do
      usage = %MingaAgent.TurnUsage{input: 1000, output: 500}
      assert DashboardRenderer.context_fill_pct(usage, "unknown-model") == nil
    end

    test "returns 0% when no tokens used" do
      usage = %MingaAgent.TurnUsage{input: 0, output: 0}
      assert DashboardRenderer.context_fill_pct(usage, "claude-sonnet-4") == 0
    end

    test "calculates correct percentage for known model" do
      # claude-sonnet-4 has 200k limit
      usage = %MingaAgent.TurnUsage{input: 50_000, output: 50_000}
      assert DashboardRenderer.context_fill_pct(usage, "claude-sonnet-4") == 50
    end

    test "caps at 100%" do
      usage = %MingaAgent.TurnUsage{input: 200_000, output: 100_000}
      assert DashboardRenderer.context_fill_pct(usage, "claude-sonnet-4") == 100
    end

    test "small usage shows low percentage" do
      usage = %MingaAgent.TurnUsage{input: 100, output: 50}
      pct = DashboardRenderer.context_fill_pct(usage, "claude-sonnet-4")
      assert pct == 0
    end

    test "high usage shows high percentage" do
      usage = %MingaAgent.TurnUsage{input: 170_000, output: 10_000}
      pct = DashboardRenderer.context_fill_pct(usage, "claude-sonnet-4")
      assert pct == 90
    end
  end
end
