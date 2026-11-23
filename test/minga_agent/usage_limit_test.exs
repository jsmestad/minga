defmodule MingaAgent.UsageLimitTest do
  use ExUnit.Case, async: true

  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaAgent.UsageLimit

  # The body ChatGPT Pro returned on 2026-11-23 when its weekly limit was reached.
  @recorded_body %{
    "eligible_promo" => nil,
    "limit_window_minutes" => 10_080,
    "message" => "The usage limit has been reached",
    "plan_type" => "pro",
    "resets_at" => 1_795_626_066,
    "resets_in_seconds" => 172_541,
    "type" => "usage_limit_reached"
  }

  @observed_at ~U[2026-11-23 17:05:25Z]

  # A fixed UTC-7 local clock, like the machine that recorded the body, keeps dates deterministic.
  defp local(%DateTime{} = at),
    do: at |> DateTime.add(-7 * 3_600) |> DateTime.to_naive() |> NaiveDateTime.to_erl()

  describe "from_response/5" do
    test "reads a usage limit only from a 429 that reports one" do
      without_reset = Map.drop(@recorded_body, ["resets_at", "resets_in_seconds"])
      only_countdown = Map.delete(@recorded_body, "resets_at")

      cases = [
        {"the recorded ChatGPT Pro body", 429, "usage_limit_reached", @recorded_body,
         {:ok,
          %UsageLimit{
            service: "ChatGPT",
            plan: "pro",
            window_minutes: 10_080,
            resets_at: DateTime.from_unix!(1_795_626_066)
          }}},
        {"the body wrapped under error, without a provider code", 429, nil,
         %{"error" => @recorded_body},
         {:ok,
          %UsageLimit{
            service: "ChatGPT",
            plan: "pro",
            window_minutes: 10_080,
            resets_at: DateTime.from_unix!(1_795_626_066)
          }}},
        {"a reset given only as a countdown", 429, nil, only_countdown,
         {:ok,
          %UsageLimit{
            service: "ChatGPT",
            plan: "pro",
            window_minutes: 10_080,
            resets_at: DateTime.add(@observed_at, 172_541)
          }}},
        {"a missing reset is not invented", 429, nil, without_reset,
         {:ok,
          %UsageLimit{service: "ChatGPT", plan: "pro", window_minutes: 10_080, resets_at: nil}}},
        {"malformed fields stay unknown", 429, nil,
         %{
           "type" => "usage_limit_reached",
           "plan_type" => "",
           "limit_window_minutes" => "weekly",
           "resets_at" => "soon",
           "resets_in_seconds" => -5
         }, {:ok, UsageLimit.unknown("ChatGPT")}},
        {"only the provider code names the limit", 429, "usage_limit_reached", "not json",
         {:ok, UsageLimit.unknown("ChatGPT")}},
        {"a plain 429", 429, nil, %{"type" => "rate_limit_error", "message" => "Slow down"},
         :none},
        {"an Anthropic 429 that sends Retry-After", 429, "rate_limit_error",
         %{"type" => "rate_limit_error", "message" => "Number of request tokens has exceeded"},
         :none},
        {"a malformed body", 429, nil, "<html>Too Many Requests</html>", :none},
        {"no body", 429, nil, nil, :none},
        {"the usage-limit type on another status", 403, "usage_limit_reached", @recorded_body,
         :none}
      ]

      for {name, status, provider_code, body, expected} <- cases do
        assert UsageLimit.from_response("ChatGPT", status, provider_code, body, @observed_at) ==
                 expected,
               name
      end
    end
  end

  describe "message/3" do
    test "names the plan and the local reset, with the date when it is not today" do
      limit = %UsageLimit{
        service: "ChatGPT",
        plan: "pro",
        window_minutes: 10_080,
        resets_at: ~U[2026-11-25 17:01:06Z]
      }

      assert UsageLimit.message(limit, @observed_at, &local/1) ==
               "Your ChatGPT Pro usage limit is reached. It resets Wed, Nov 25 at 10:01 AM. Choose another model with /model to continue now."

      assert UsageLimit.message(
               %{limit | resets_at: ~U[2026-11-23 21:40:00Z]},
               @observed_at,
               &local/1
             ) ==
               "Your ChatGPT Pro usage limit is reached. It resets at 2:40 PM. Choose another model with /model to continue now."
    end

    test "leaves out what the provider did not report" do
      assert UsageLimit.message(UsageLimit.unknown("Claude"), @observed_at, &local/1) ==
               "Your Claude usage limit is reached. Choose another model with /model to continue now."

      assert UsageLimit.message(
               %UsageLimit{service: "ChatGPT", plan: "team_plus"},
               @observed_at,
               &local/1
             ) ==
               "Your ChatGPT Team Plus usage limit is reached. Choose another model with /model to continue now."
    end
  end

  test "a limit stays in force until its reset passes, or indefinitely without one" do
    limit = %UsageLimit{service: "ChatGPT", resets_at: ~U[2026-11-25 17:01:06Z]}

    assert UsageLimit.in_force?(limit, @observed_at)
    refute UsageLimit.in_force?(limit, ~U[2026-11-25 17:01:06Z])
    assert UsageLimit.in_force?(UsageLimit.unknown("ChatGPT"), ~U[2030-01-01 00:00:00Z])
  end

  test "a limit converts to and from a refusing plan window" do
    resets_at = ~U[2026-11-25 17:01:06Z]

    for {minutes, kind} <- [
          {300, "five_hour"},
          {10_080, "seven_day"},
          {2_880, "2d"},
          {120, "2h"},
          {45, "45m"},
          {nil, "plan"}
        ] do
      limit = %UsageLimit{service: "ChatGPT", window_minutes: minutes, resets_at: resets_at}

      assert UsageLimit.plan_window(limit) == %PlanWindow{
               kind: kind,
               utilization: 1.0,
               resets_at: resets_at,
               status: :rejected
             }
    end

    window = %PlanWindow{
      kind: "five_hour",
      utilization: 1.0,
      resets_at: resets_at,
      status: :rejected
    }

    assert UsageLimit.from_plan_window("Claude", window) ==
             %UsageLimit{service: "Claude", window_minutes: 300, resets_at: resets_at}
  end
end
