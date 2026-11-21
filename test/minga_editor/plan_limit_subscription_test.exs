defmodule MingaEditor.PlanLimitSubscriptionTest do
  use Minga.Test.EditorCase, async: true

  test "the Editor listens for route status changes so the plan segment updates without polling" do
    ctx = start_editor("hello")

    assert ctx.editor in Minga.Events.subscribers(
             :inference_route_status_changed,
             ctx.events_registry
           )
  end
end
