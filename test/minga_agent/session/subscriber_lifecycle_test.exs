defmodule MingaAgent.Session.SubscriberLifecycleTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.SubscriberAttachment
  alias MingaAgent.Session.SubscriberLifecycle

  test "canonical attachments derive subscriber membership and one driver" do
    driver = self()
    viewer = Process.whereis(:init)
    requested_driver = Process.whereis(:code_server)

    lifecycle =
      SubscriberLifecycle.new()
      |> attach(driver, :driver, make_ref())
      |> attach(viewer, :viewer, make_ref())
      |> attach(requested_driver, :driver, make_ref())

    assert MapSet.new(SubscriberLifecycle.subscribers(lifecycle)) ==
             MapSet.new([driver, viewer, requested_driver])

    assert SubscriberLifecycle.driver(lifecycle) == driver
    assert SubscriberLifecycle.role(lifecycle, driver) == :driver
    assert SubscriberLifecycle.role(lifecycle, viewer) == :viewer
    assert SubscriberLifecycle.role(lifecycle, requested_driver) == :viewer
    assert SubscriberLifecycle.default_role(lifecycle) == :viewer
    assert SubscriberLifecycle.driver?(lifecycle, driver)
  end

  test "subscription completion distinguishes initial, viewer, and replacement roles" do
    initial = SubscriberLifecycle.new()

    assert {:monitor, initial_driver} =
             SubscriberLifecycle.prepare_subscribe(initial, self(), :driver)

    assert {:ok, _with_driver, :driver_initialized, nil} =
             SubscriberLifecycle.complete_subscribe(initial, initial_driver, make_ref())

    viewer = Process.whereis(:init)

    assert {:monitor, initial_viewer} =
             SubscriberLifecycle.prepare_subscribe(initial, viewer, :viewer)

    assert {:ok, viewer_only, :viewer_attached, nil} =
             SubscriberLifecycle.complete_subscribe(initial, initial_viewer, make_ref())

    assert {:monitor, replacement_driver} =
             SubscriberLifecycle.prepare_subscribe(viewer_only, self(), :driver)

    assert {:ok, _with_replacement, :driver_changed, nil} =
             SubscriberLifecycle.complete_subscribe(
               viewer_only,
               replacement_driver,
               make_ref()
             )
  end

  test "subscription preparation rejects invalid roles and preserves an existing attachment" do
    driver = self()
    lifecycle = attach(SubscriberLifecycle.new(), driver, :driver, make_ref())

    assert {:error, :invalid_role} =
             SubscriberLifecycle.prepare_subscribe(lifecycle, Process.whereis(:init), :owner)

    assert {:already_attached, ^lifecycle} =
             SubscriberLifecycle.prepare_subscribe(lifecycle, driver, :viewer)

    assert SubscriberLifecycle.role(lifecycle, driver) == :driver
  end

  test "monitor completion rejects a stale preparation and leaves the acquired reference unowned" do
    lifecycle = SubscriberLifecycle.new()
    subscriber = self()
    other = Process.whereis(:init)
    monitor_ref = make_ref()

    assert {:monitor, preparation} =
             SubscriberLifecycle.prepare_subscribe(lifecycle, subscriber, :driver)

    changed = attach(lifecycle, other, :viewer, make_ref())

    assert {:error, :stale_preparation} =
             SubscriberLifecycle.complete_subscribe(changed, preparation, monitor_ref)

    refute monitor_ref in monitor_refs(changed)
  end

  test "driver claims are exhaustive across absent, occupied, vacant, and unchanged states" do
    driver = self()
    viewer = Process.whereis(:init)

    states = [
      {:empty, SubscriberLifecycle.new(), {:error, :not_subscribed}},
      {:viewer_only, attach(SubscriberLifecycle.new(), viewer, :viewer, make_ref()),
       {:changed, :viewer}},
      {:driver_occupied,
       SubscriberLifecycle.new()
       |> attach(driver, :driver, make_ref())
       |> attach(viewer, :viewer, make_ref()), {:error, :driver_taken}}
    ]

    for {name, lifecycle, expected} <- states do
      case {name, SubscriberLifecycle.claim_driver(lifecycle, viewer), expected} do
        {:viewer_only, {:changed, next}, {:changed, :viewer}} ->
          assert SubscriberLifecycle.driver(next) == viewer
          assert SubscriberLifecycle.role(next, viewer) == :driver

        {_name, actual, expected} ->
          assert actual == expected
      end
    end

    occupied = attach(SubscriberLifecycle.new(), driver, :driver, make_ref())
    assert :unchanged = SubscriberLifecycle.claim_driver(occupied, driver)
  end

  test "driver DOWN leaves viewers attached without automatic promotion" do
    driver = self()
    viewer = Process.whereis(:init)
    driver_ref = make_ref()
    viewer_ref = make_ref()

    lifecycle =
      SubscriberLifecycle.new()
      |> attach(driver, :driver, driver_ref)
      |> attach(viewer, :viewer, viewer_ref)

    assert {:error, :stale_monitor} =
             SubscriberLifecycle.subscriber_down(lifecycle, driver, make_ref())

    assert {:removed, without_driver, %SubscriberAttachment{monitor_ref: ^driver_ref}} =
             SubscriberLifecycle.subscriber_down(lifecycle, driver, driver_ref)

    assert SubscriberLifecycle.driver(without_driver) == nil
    assert SubscriberLifecycle.role(without_driver, viewer) == :viewer
    assert {:changed, claimed} = SubscriberLifecycle.claim_driver(without_driver, viewer)
    assert SubscriberLifecycle.driver(claimed) == viewer
  end

  test "viewer DOWN does not affect the current driver" do
    driver = self()
    viewer = Process.whereis(:init)
    viewer_ref = make_ref()

    lifecycle =
      SubscriberLifecycle.new()
      |> attach(driver, :driver, make_ref())
      |> attach(viewer, :viewer, viewer_ref)

    assert {:removed, next, %SubscriberAttachment{pid: ^viewer}} =
             SubscriberLifecycle.subscriber_down(lifecycle, viewer, viewer_ref)

    assert SubscriberLifecycle.driver(next) == driver
    assert SubscriberLifecycle.role(next, viewer) == nil
  end

  test "detach returns the exact monitor identity once" do
    subscriber = self()
    monitor_ref = make_ref()
    lifecycle = attach(SubscriberLifecycle.new(), subscriber, :driver, monitor_ref)

    assert {:removed, detached, %SubscriberAttachment{monitor_ref: ^monitor_ref}} =
             SubscriberLifecycle.detach(lifecycle, subscriber)

    assert SubscriberLifecycle.subscribers(detached) == []
    assert :unchanged = SubscriberLifecycle.detach(detached, subscriber)

    assert {:error, :stale_monitor} =
             SubscriberLifecycle.subscriber_down(detached, subscriber, monitor_ref)
  end

  test "reclaim scheduling installs and cancels exact OTP timer identity" do
    lifecycle = SubscriberLifecycle.new()
    timer_ref = make_ref()

    assert {:start_timer, preparation} =
             SubscriberLifecycle.reconcile_reclaim(lifecycle, true, true)

    assert {:ok, scheduled} =
             SubscriberLifecycle.complete_reclaim_schedule(lifecycle, preparation, timer_ref)

    assert SubscriberLifecycle.reclaim_timer(scheduled) == timer_ref
    assert :unchanged = SubscriberLifecycle.reconcile_reclaim(scheduled, true, true)

    assert {:cancel_timer, ^timer_ref, cancelled} =
             SubscriberLifecycle.reconcile_reclaim(scheduled, true, false)

    assert SubscriberLifecycle.reclaim_timer(cancelled) == nil
  end

  test "timer completion rejects stale, occupied, and already scheduled lifecycle states" do
    lifecycle = SubscriberLifecycle.new()
    subscriber = self()

    assert {:start_timer, preparation} =
             SubscriberLifecycle.reconcile_reclaim(lifecycle, true, true)

    attached = attach(lifecycle, subscriber, :driver, make_ref())

    assert {:error, :stale_preparation} =
             SubscriberLifecycle.complete_reclaim_schedule(attached, preparation, make_ref())

    assert {:error, :subscriber_attached} =
             SubscriberLifecycle.complete_reclaim_schedule(attached, attached, make_ref())

    scheduled = install_timer(lifecycle, make_ref())

    assert {:error, :timer_already_installed} =
             SubscriberLifecycle.complete_reclaim_schedule(scheduled, scheduled, make_ref())
  end

  test "reattach invalidates the prior timer before stale timeout delivery" do
    timer_ref = make_ref()
    scheduled = install_timer(SubscriberLifecycle.new(), timer_ref)
    subscriber = self()

    assert {:monitor, preparation} =
             SubscriberLifecycle.prepare_subscribe(scheduled, subscriber, :driver)

    assert {:ok, attached, :driver_initialized, ^timer_ref} =
             SubscriberLifecycle.complete_subscribe(scheduled, preparation, make_ref())

    assert SubscriberLifecycle.reclaim_timer(attached) == nil
    assert {:error, :stale_timer} = SubscriberLifecycle.reclaim_timeout(attached, timer_ref, true)
  end

  test "timeout accepts only the installed timer and rechecks turn activity" do
    timer_ref = make_ref()
    scheduled = install_timer(SubscriberLifecycle.new(), timer_ref)

    assert {:error, :stale_timer} =
             SubscriberLifecycle.reclaim_timeout(scheduled, make_ref(), true)

    assert {:keep, kept} = SubscriberLifecycle.reclaim_timeout(scheduled, timer_ref, false)
    assert SubscriberLifecycle.reclaim_timer(kept) == nil

    scheduled = install_timer(SubscriberLifecycle.new(), timer_ref)
    assert {:reclaim, reclaimed} = SubscriberLifecycle.reclaim_timeout(scheduled, timer_ref, true)
    assert SubscriberLifecycle.reclaim_timer(reclaimed) == nil
  end

  test "stop returns every owned cleanup identity and clears lifecycle" do
    first_ref = make_ref()
    second_ref = make_ref()

    attached =
      SubscriberLifecycle.new()
      |> attach(self(), :driver, first_ref)
      |> attach(Process.whereis(:init), :viewer, second_ref)

    {stopped, nil, monitor_refs} = SubscriberLifecycle.stop(attached)

    assert MapSet.new(monitor_refs) == MapSet.new([first_ref, second_ref])
    assert SubscriberLifecycle.subscribers(stopped) == []

    timer_ref = make_ref()
    scheduled = install_timer(SubscriberLifecycle.new(), timer_ref)
    {stopped, ^timer_ref, []} = SubscriberLifecycle.stop(scheduled)
    assert SubscriberLifecycle.reclaim_timer(stopped) == nil
  end

  defp attach(lifecycle, pid, role, monitor_ref) do
    assert {:monitor, preparation} = SubscriberLifecycle.prepare_subscribe(lifecycle, pid, role)

    assert {:ok, next, _subscription_change, _timer_ref} =
             SubscriberLifecycle.complete_subscribe(lifecycle, preparation, monitor_ref)

    next
  end

  defp install_timer(lifecycle, timer_ref) do
    assert {:start_timer, preparation} =
             SubscriberLifecycle.reconcile_reclaim(lifecycle, true, true)

    assert {:ok, next} =
             SubscriberLifecycle.complete_reclaim_schedule(lifecycle, preparation, timer_ref)

    next
  end

  defp monitor_refs(lifecycle) do
    {_stopped, _timer_ref, monitor_refs} = SubscriberLifecycle.stop(lifecycle)
    monitor_refs
  end
end
