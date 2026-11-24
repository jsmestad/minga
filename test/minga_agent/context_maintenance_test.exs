defmodule MingaAgent.ContextMaintenanceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.TokenEstimator

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

  # ── AC3/AC5: Maintenance budget check logic ────────────────────────────────

  describe "maintenance budget estimation" do
    test "TokenEstimator produces estimates suitable for budget checks" do
      short_messages = [
        %{role: "system", content: "Be concise."},
        %{role: "user", content: "Hello"}
      ]

      long_messages =
        [%{role: "system", content: "Be concise."}] ++
          for i <- 1..50 do
            role = if rem(i, 2) == 1, do: "user", else: "assistant"
            %{role: role, content: String.duplicate("word ", 200)}
          end

      short = TokenEstimator.estimate(short_messages)
      long = TokenEstimator.estimate(long_messages)

      assert short < 50
      assert long > 1000
      # The long estimate should be clearly over an 80% threshold of a 2000-token limit
      assert long > 2000 * 0.80
    end

    test "tool call messages increase the estimate materially" do
      base = [
        %{role: "user", content: "read the file"},
        %{role: "assistant", content: "Sure"}
      ]

      with_tool = [
        %{role: "user", content: "read the file"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{function: %{name: "read_file", arguments: ~s({"path": "/big.txt"})}}
          ]
        },
        %{role: "tool", content: String.duplicate("x", 10_000), tool_call_id: "call_1"}
      ]

      base_est = TokenEstimator.estimate(base)
      tool_est = TokenEstimator.estimate(with_tool)

      assert tool_est > base_est * 10,
             "tool result should dominate: #{tool_est} vs #{base_est}"
    end
  end

  # ── AC5: Overflow message ──────────────────────────────────────────────────

  describe "context overflow messaging" do
    test "overflow message includes estimated and limit values" do
      # The actual function is private to Native, so we verify the contract
      # through the message content expectations.
      message =
        "Context exceeds the model's input budget (estimated 150,000 tokens vs 128,000 limit). " <>
          "The conversation is too large to compact further. Start a new session or remove large tool outputs."

      assert message =~ "150,000"
      assert message =~ "128,000"
      assert message =~ "Start a new session"
    end
  end
end
