defmodule MingaEditor.State.RouteUsageTest do
  use ExUnit.Case, async: true

  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaAgent.InferenceRoute.Status
  alias MingaAgent.InferenceRoute.StatusChangedEvent
  alias MingaEditor.State.RouteUsage
  alias MingaEditor.StatusBar.PlanLimit

  @now ~U[2026-11-21 12:00:00Z]

  defp event(route_id, short_name, plan_usage) do
    %StatusChangedEvent{
      route_id: route_id,
      short_name: short_name,
      status: Status.with_plan_usage(Status.unknown(), plan_usage)
    }
  end

  defp window(utilization) do
    %PlanWindow{kind: "five_hour", utilization: utilization, resets_at: nil, status: :warning}
  end

  defp utc(at), do: at |> DateTime.to_naive() |> NaiveDateTime.to_erl()

  test "keeps each route's latest usage apart and reads only the requested route" do
    usage =
      %RouteUsage{}
      |> RouteUsage.record(event("claude", "Claude", [window(0.5)]))
      |> RouteUsage.record(event("other", "Other", [window(0.95)]))
      |> RouteUsage.record(event("claude", "Claude", [window(0.85)]))

    assert %PlanLimit{level: :warning, text: "Claude 85% · 5h"} =
             RouteUsage.plan_limit(usage, "claude", @now, &utc/1)

    assert %PlanLimit{text: "Other 95% · 5h"} =
             RouteUsage.plan_limit(usage, "other", @now, &utc/1)
  end

  test "no route, an unknown route, and a route that reported no usage show nothing" do
    usage =
      %RouteUsage{}
      |> RouteUsage.record(event("claude", "Claude", [window(0.9)]))
      |> RouteUsage.record(event("claude", "Claude", nil))

    assert usage == %RouteUsage{}
    assert RouteUsage.plan_limit(usage, nil, @now, &utc/1) == nil
    assert RouteUsage.plan_limit(usage, "claude", @now, &utc/1) == nil
    assert RouteUsage.plan_limit(usage, "missing", @now, &utc/1) == nil
  end
end
