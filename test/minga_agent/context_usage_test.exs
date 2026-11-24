defmodule MingaAgent.ContextUsageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias MingaAgent.Event

  # ── AC4: ContextUsage distinguishes reported vs estimated ───────────────────

  describe "ContextUsage event" do
    test "default estimation_method is :estimated" do
      event = %Event.ContextUsage{estimated_tokens: 100}
      assert event.estimation_method == :estimated
      assert event.reported_tokens == nil
    end

    test "reported usage carries :reported method and reported_tokens" do
      event = %Event.ContextUsage{
        estimated_tokens: 500,
        context_limit: 4096,
        reported_tokens: 480,
        estimation_method: :reported
      }

      assert event.estimation_method == :reported
      assert event.reported_tokens == 480
      assert event.estimated_tokens == 500
    end

    test "unknown estimation method is valid" do
      event = %Event.ContextUsage{
        estimated_tokens: 0,
        estimation_method: :unknown
      }

      assert event.estimation_method == :unknown
    end
  end
end
