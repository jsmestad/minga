defmodule MingaAgent.SessionTaskEventsTest do
  @moduledoc "The session events the tasks drawer reads: a retry's wait and the task's goal."

  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.Session

  @event_timeout 5_000

  test "a provider retry reaches subscribers as waiting, with its delay and reason" do
    session =
      start_supervised!(
        {Session,
         provider: Minga.Test.SessionContinuationProvider,
         provider_opts: [test_pid: self()],
         persist?: false}
      )

    assert :ok = Session.subscribe(session, self())
    assert :ok = Session.send_prompt(session, "retry turn")
    assert_receive {:continuation_request, _request}, @event_timeout

    Minga.Test.SessionCase.send_provider_event(
      session,
      %Event.RetryScheduled{attempt: 1, delay_ms: 40_000, reason: "HTTP 429"}
    )

    assert_receive {:agent_event, ^session, {:retry_scheduled, 40_000, "HTTP 429"}},
                   @event_timeout
  end

  test "the first prompt of an untitled conversation is announced as its goal, once" do
    session =
      start_supervised!(
        {Session,
         provider: Minga.Test.SessionContinuationProvider,
         provider_opts: [test_pid: self()],
         persist?: false}
      )

    assert :ok = Session.subscribe(session, self())
    assert :ok = Session.send_prompt(session, "Add tests for the classifier\nwith a table")

    assert_receive {:agent_event, ^session, {:title_changed, "Add tests for the classifier"}},
                   @event_timeout
  end
end
