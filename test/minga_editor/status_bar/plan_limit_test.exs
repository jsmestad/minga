defmodule MingaEditor.StatusBar.PlanLimitTest do
  use ExUnit.Case, async: true

  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaEditor.StatusBar.PlanLimit

  @now ~U[2026-11-21 12:00:00Z]
  @later ~U[2026-11-21 15:40:00Z]

  defp window(attrs) do
    struct!(
      PlanWindow,
      Keyword.merge(
        [kind: "five_hour", utilization: 0.5, resets_at: @later, status: :allowed],
        attrs
      )
    )
  end

  describe "from_usage/4" do
    test "shows nothing under 80%, a quiet percentage at 80% or more, and nothing without data" do
      cases = [
        {"no data", nil, nil},
        {"empty list", [], nil},
        {"79%", [window(utilization: 0.799, status: :warning)], nil},
        {"80%", [window(utilization: 0.8, status: :warning)], {:warning, "Claude 80% · 5h"}},
        {"82%", [window(utilization: 0.82)], {:warning, "Claude 82% · 5h"}},
        {"unknown kind keeps its name", [window(kind: "monthly", utilization: 0.9)],
         {:warning, "Claude 90% · monthly"}},
        {"the busiest window wins",
         [
           window(kind: "five_hour", utilization: 0.81),
           window(kind: "seven_day", utilization: 0.93)
         ], {:warning, "Claude 93% · 7d"}},
        {"a busy window below the threshold is still quiet",
         [
           window(kind: "five_hour", utilization: 0.2),
           window(kind: "seven_day", utilization: 0.6)
         ], nil}
      ]

      for {label, windows, expected} <- cases do
        assert project(PlanLimit.from_usage("Claude", windows, @now, &utc/1)) == expected, label
      end
    end

    test "a refusing window reports the limit and when it resets, ahead of busier windows" do
      rejected = window(kind: "five_hour", utilization: 0.7, status: :rejected)

      assert %PlanLimit{level: :rejected, text: text} =
               PlanLimit.from_usage(
                 "Claude",
                 [window(kind: "seven_day", utilization: 0.95), rejected],
                 @now,
                 &utc/1
               )

      assert text == "Claude limit · resets 3:40 PM"
    end

    test "a refusing window without a reset time says only that the limit is reached" do
      windows = [window(utilization: 1.0, status: :rejected, resets_at: nil)]

      assert %PlanLimit{level: :rejected, text: "Claude limit"} =
               PlanLimit.from_usage("Claude", windows, @now, &utc/1)
    end

    test "windows whose reset time has passed no longer show" do
      expired = [
        window(utilization: 0.95, resets_at: @now),
        window(
          kind: "seven_day",
          utilization: 1.0,
          status: :rejected,
          resets_at: ~U[2026-11-21 11:00:00Z]
        )
      ]

      assert PlanLimit.from_usage("Claude", expired, @now, &utc/1) == nil

      assert project(
               PlanLimit.from_usage(
                 "Claude",
                 [
                   window(utilization: 0.99, resets_at: @now),
                   window(kind: "seven_day", utilization: 0.85)
                 ],
                 @now,
                 &utc/1
               )
             ) == {:warning, "Claude 85% · 7d"}
    end
  end

  # Reads reset times in UTC so labels do not depend on the machine's zone.
  defp utc(at), do: at |> DateTime.to_naive() |> NaiveDateTime.to_erl()

  defp project(nil), do: nil
  defp project(%PlanLimit{level: level, text: text}), do: {level, text}
end
