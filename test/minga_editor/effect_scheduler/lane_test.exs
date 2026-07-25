defmodule MingaEditor.EffectScheduler.LaneTest do
  use ExUnit.Case, async: true

  alias Minga.Test.EffectProbe
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler.Lane

  defp request(label, resource \\ :resource, policy \\ Policy.fifo(2)) do
    EffectProbe.request(self(), label, resource, policy, :wait)
  end

  defp labels(queue), do: queue |> :queue.to_list() |> Enum.map(& &1.effect.label)

  defp queue_positions(queue_action),
    do:
      elem(queue_action, 1)
      |> Enum.map(fn {request, position, total} -> {request.effect.label, position, total} end)

  defp assert_pure(actions, lane) do
    refute inspect({actions, lane}) =~ "MingaEditor.Effect.Outcome"
    refute inspect({actions, lane}) =~ "%Task{"
    refute Enum.any?(actions, &match?(%Outcome{}, &1))
  end

  test "fifo admission starts the first request, queues the second, and rejects overflow unchanged" do
    policy = Policy.fifo(1)
    first = request(:first, :resource, policy)
    second = request(:second, :resource, policy)
    third = request(:third, :resource, policy)

    assert {{:ok, first_id, :running}, lane, [{:start, ^first}]} = Lane.admit(nil, first, true)
    assert first_id == first.id
    assert lane.running == first

    assert {{:ok, second_id, :queued}, lane, [{:queue, positions}]} =
             Lane.admit(lane, second, true)

    assert second_id == second.id
    assert lane.running == first
    assert queue_positions({:queue, positions}) == [{:second, 1, 1}]

    assert {{:error, :queue_full}, same_lane, []} = Lane.admit(lane, third, true)
    assert same_lane == lane
    assert_pure([{:start, first}, {:queue, positions}], lane)
  end

  test "capacity and policy errors do not create actions or mutate the lane" do
    fifo = Policy.fifo(0)
    first = request(:first, :resource, fifo)
    second = request(:second, :resource, fifo)
    other_policy = Policy.coalescing(1)
    other = request(:other, :resource, other_policy)

    assert {{:error, :scheduler_full}, nil, []} = Lane.admit(nil, first, false)
    assert {{:ok, first_id, :running}, lane, _actions} = Lane.admit(nil, first, true)
    assert first_id == first.id
    assert {{:error, :queue_full}, ^lane, []} = Lane.admit(lane, second, false)
    assert {{:error, :policy_mismatch}, ^lane, []} = Lane.admit(lane, other, true)
  end

  test "fifo queued cancellation refreshes the remaining queue without touching running work" do
    first = request(:first)
    second = request(:second)
    third = request(:third)
    {{:ok, _, :running}, lane, _actions} = Lane.admit(nil, first, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, second, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, third, true)

    assert {:ok, lane, [{:candidate, ^second, {:canceled, :requested}}, {:queue, positions}]} =
             Lane.cancel_request(lane, second.id)

    assert lane.running == first
    assert labels(lane.queue) == [:third]
    assert queue_positions({:queue, positions}) == [{:third, 1, 1}]
  end

  test "explicit running cancellation holds the lane until Engine requests promotion" do
    first = request(:first)
    second = request(:second)
    third = request(:third)
    {{:ok, _, :running}, lane, _actions} = Lane.admit(nil, first, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, second, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, third, true)

    assert {:ok, canceled_lane, [{:stop, ^first}, {:candidate, ^first, {:canceled, :requested}}]} =
             Lane.cancel_request(lane, first.id)

    assert canceled_lane.running == first

    assert {released_lane, []} = Lane.finalize_current(canceled_lane, first)
    assert released_lane.running == nil
    assert labels(released_lane.queue) == [:second, :third]

    assert {promoted_lane, [{:queue, positions}, {:start, ^second}]} =
             Lane.finish_current(released_lane)

    assert promoted_lane.running == second
    assert queue_positions({:queue, positions}) == [{:third, 1, 1}]
  end

  test "finalizing a queued request leaves the current lane unchanged" do
    first = request(:first)
    second = request(:second)
    third = request(:third)
    {{:ok, _, :running}, lane, _actions} = Lane.admit(nil, first, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, second, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, third, true)

    assert {same_lane, []} = Lane.finalize_current(lane, second)
    assert same_lane == lane
  end

  test "matching cancellation stops matching running work, terminalizes matches, and preserves fifo order" do
    policy = Policy.fifo(3)
    first = request(:first, :resource, policy)
    second = request(:second, :resource, policy)
    third = request(:third, :other, policy) |> Map.put(:resource, :resource)
    fourth = request(:fourth, :resource, policy)
    {{:ok, _, :running}, lane, _actions} = Lane.admit(nil, first, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, second, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, third, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, fourth, true)

    {lane, actions, true} =
      Lane.cancel_matching(lane, &(&1.effect.label in [:first, :third]), :source_canceled)

    assert lane.running == nil
    assert labels(lane.queue) == [:second, :fourth]

    assert [
             {:stop, ^first},
             {:terminal, ^first, {:canceled, :source_canceled}},
             {:terminal, ^third, {:canceled, :source_canceled}},
             {:queue, positions}
           ] = actions

    assert queue_positions({:queue, positions}) == [{:second, 1, 2}, {:fourth, 2, 2}]

    assert {promoted_lane, [{:queue, positions}, {:start, ^second}]} = Lane.finish_current(lane)
    assert promoted_lane.running == second
    assert queue_positions({:queue, positions}) == [{:fourth, 1, 1}]
  end

  test "latest wins supersedes running and queued work with terminal cancellation actions" do
    policy = Policy.latest_wins()
    first = request(:first, :resource, policy)
    second = request(:second, :resource, policy)
    replacement = request(:replacement, :resource, policy)
    {{:ok, _, :running}, lane, _actions} = Lane.admit(nil, first, true)
    lane = %{lane | queue: :queue.from_list([second])}

    assert {{:ok, replacement_id, :running}, lane, actions} = Lane.admit(lane, replacement, true)
    assert replacement_id == replacement.id
    assert lane.running == replacement
    assert :queue.is_empty(lane.queue)

    assert actions == [
             {:stop, first},
             {:terminal, first, {:canceled, :superseded}},
             {:terminal, second, {:canceled, :superseded}},
             {:start, replacement}
           ]
  end

  test "coalescing full queue replaces only the tail and marks the older tail stale" do
    policy = Policy.coalescing(1)
    running = request(:running, :resource, policy)
    older = request(:older, :resource, policy)
    newer = request(:newer, :resource, policy)
    {{:ok, _, :running}, lane, _actions} = Lane.admit(nil, running, true)
    {{:ok, _, :queued}, lane, _actions} = Lane.admit(lane, older, true)

    assert {{:ok, newer_id, :queued}, lane,
            [{:terminal, ^older, {:stale, :coalesced}}, {:queue, positions}]} =
             Lane.admit(lane, newer, true)

    assert newer_id == newer.id
    assert lane.running == running
    assert [%Request{id: id, effect: effect}] = :queue.to_list(lane.queue)
    assert id == newer.id
    assert effect.payloads == [:older, :newer]
    assert queue_positions({:queue, positions}) == [{:newer, 1, 1}]
  end

  test "finish_current deletes empty lanes or promotes the head while preserving queue storage" do
    policy = Policy.fifo(2)
    first = request(:first, :resource, policy)
    second = request(:second, :resource, policy)
    assert {:empty, []} = Lane.finish_current(Lane.new(policy))

    lane = %Lane{Lane.new(policy) | queue: :queue.from_list([first, second])}
    assert {lane, [{:queue, positions}, {:start, ^first}]} = Lane.finish_current(lane)
    assert lane.running == first
    assert labels(lane.queue) == [:second]
    assert queue_positions({:queue, positions}) == [{:second, 1, 1}]
  end
end
