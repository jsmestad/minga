defmodule MingaAgent.Session.PersistenceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.Persistence

  test "disabled persistence ignores transcript changes" do
    persistence = Persistence.new(false)

    assert {^persistence, nil} = Persistence.changed(persistence)
    refute Persistence.dirty?(persistence)
    refute Persistence.enabled?(persistence)
  end

  test "change, schedule, due, and success handle one correlated save" do
    token = make_ref()
    timer_ref = make_ref()

    {changed, nil} = Persistence.new(true) |> Persistence.changed()
    scheduled = Persistence.scheduled(changed, token, timer_ref)

    assert Persistence.dirty?(scheduled)
    assert scheduled.timer == {token, timer_ref}
    assert :stale = Persistence.save_due(scheduled, make_ref())
    assert {:save, saving} = Persistence.save_due(scheduled, token)
    assert saving.timer == nil

    saved = Persistence.saved(saving)
    refute Persistence.dirty?(saved)
    assert saved.retry_count == 0
  end

  test "failed saves remain dirty and use capped retry delays" do
    {persistence, nil} = Persistence.new(true) |> Persistence.changed()

    {persistence, first_delay} = Persistence.failed(persistence)
    {persistence, second_delay} = Persistence.failed(persistence)
    {persistence, third_delay} = Persistence.failed(persistence)

    assert [first_delay, second_delay, third_delay] == [5_000, 10_000, 20_000]
    assert Persistence.dirty?(persistence)
    assert persistence.retry_count == 3

    {capped, _persistence} =
      Enum.map_reduce(1..8, Persistence.new(true), fn _attempt, current ->
        {next, delay} = Persistence.failed(current)
        {delay, next}
      end)

    assert Enum.at(capped, -1) == 60_000
    assert Enum.max(capped) == 60_000
  end

  test "a newer change cancels the installed retry timer and resets retry count" do
    token = make_ref()
    timer_ref = make_ref()

    persistence = Persistence.new(true)
    {persistence, nil} = Persistence.changed(persistence)
    {persistence, _delay} = Persistence.failed(persistence)
    persistence = Persistence.scheduled(persistence, token, timer_ref)

    assert {changed, {^token, ^timer_ref}} = Persistence.changed(persistence)
    assert changed.retry_count == 0
    assert Persistence.dirty?(changed)
    assert changed.timer == nil
  end

  test "cancel and restore return timer effects while installing pure bookkeeping" do
    token = make_ref()
    timer_ref = make_ref()

    persistence = Persistence.new(true)
    {persistence, nil} = Persistence.changed(persistence)
    persistence = Persistence.scheduled(persistence, token, timer_ref)

    assert {canceled, {^token, ^timer_ref}} = Persistence.cancel(persistence)
    assert canceled.timer == nil
    assert Persistence.dirty?(canceled)

    rescheduled = Persistence.scheduled(canceled, token, timer_ref)
    assert {restored, {^token, ^timer_ref}} = Persistence.restored(rescheduled)
    refute Persistence.dirty?(restored)
    assert restored.timer == nil
  end
end
