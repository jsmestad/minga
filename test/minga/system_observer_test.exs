defmodule Minga.SystemObserverTest do
  use ExUnit.Case, async: true

  alias Minga.SystemObserver
  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.RestartRecord

  describe "start_link/1" do
    test "starts the GenServer with a custom name" do
      observer =
        start_supervised!(
          {SystemObserver, name: :"observer_#{System.unique_integer([:positive])}"}
        )

      assert Process.alive?(observer)
    end
  end

  describe "subscribe/unsubscribe" do
    setup do
      name = :"observer_#{System.unique_integer([:positive])}"
      observer = start_supervised!({SystemObserver, name: name})
      %{observer: observer, name: name}
    end

    test "subscribing starts polling", %{name: name} do
      :ok = SystemObserver.subscribe(name)

      # Send :tick directly and use :sys.get_state as sync barrier
      send(name, :tick)
      :sys.get_state(name)

      snapshot = SystemObserver.snapshot(name)
      assert snapshot != nil
      assert is_map(snapshot.processes)
      assert is_integer(snapshot.timestamp)
    end

    test "unsubscribing when last subscriber stops polling", %{name: name} do
      :ok = SystemObserver.subscribe(name)
      # Send a tick and sync
      send(name, :tick)
      :sys.get_state(name)

      :ok = SystemObserver.unsubscribe(name)
      state = :sys.get_state(name)
      assert state.poll_timer == nil
    end

    test "duplicate subscribe is idempotent", %{name: name} do
      :ok = SystemObserver.subscribe(name)
      :ok = SystemObserver.subscribe(name)

      state = :sys.get_state(name)
      assert MapSet.size(state.subscribers) == 1
    end

    test "subscriber process exit triggers auto-unsubscribe", %{name: name} do
      task =
        Task.async(fn ->
          SystemObserver.subscribe(name)
          :subscribed
        end)

      assert Task.await(task) == :subscribed

      # :sys.get_state acts as a synchronization barrier, ensuring the
      # DOWN message from the exited task process has been processed.
      :sys.get_state(name)

      state = :sys.get_state(name)
      assert MapSet.size(state.subscribers) == 0
    end
  end

  describe "snapshot/1" do
    setup do
      name = :"observer_#{System.unique_integer([:positive])}"
      observer = start_supervised!({SystemObserver, name: name})
      %{observer: observer, name: name}
    end

    test "returns nil when no samples collected", %{name: name} do
      assert SystemObserver.snapshot(name) == nil
    end

    test "returns the latest snapshot after polling starts", %{name: name} do
      :ok = SystemObserver.subscribe(name)
      # Send :tick directly instead of waiting for the timer
      send(name, :tick)
      :sys.get_state(name)

      snapshot = SystemObserver.snapshot(name)
      assert snapshot != nil
      assert %{timestamp: _, processes: processes} = snapshot
      assert is_map(processes)

      # Should have at least the observer itself
      assert map_size(processes) > 0

      # Verify process snapshot structure
      {_pid, first_process} = Enum.at(processes, 0)
      assert %ProcessSnapshot{} = first_process
      assert is_integer(first_process.memory)
      assert first_process.memory >= 0
      assert is_integer(first_process.message_queue_len)
      assert is_integer(first_process.reductions)
    end
  end

  describe "samples/1" do
    setup do
      name = :"observer_#{System.unique_integer([:positive])}"
      observer = start_supervised!({SystemObserver, name: name})
      %{observer: observer, name: name}
    end

    test "returns empty list when no polling has occurred", %{name: name} do
      assert SystemObserver.samples(name) == []
    end

    test "returns samples oldest-first", %{name: name} do
      :ok = SystemObserver.subscribe(name)
      # Send multiple ticks directly
      for _ <- 1..3 do
        send(name, :tick)
        :sys.get_state(name)
      end

      samples = SystemObserver.samples(name)
      assert samples != []

      timestamps = Enum.map(samples, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps)
    end
  end

  describe "restart_history/1" do
    setup do
      name = :"observer_#{System.unique_integer([:positive])}"
      observer = start_supervised!({SystemObserver, name: name})
      %{observer: observer, name: name}
    end

    test "returns empty list initially", %{name: name} do
      assert SystemObserver.restart_history(name) == []
    end

    test "records supervisor DOWN events", %{name: name} do
      # Subscribe to the restart event for synchronization
      Minga.Events.subscribe(:supervisor_restarted)

      # Spawn a standalone process (not start_supervised!) so we control its lifecycle
      dummy_pid = spawn(fn -> Process.sleep(:infinity) end)

      # Inject a monitor into the observer's state, as if establish_monitors found it
      :sys.replace_state(name, fn state ->
        ref = Process.monitor(dummy_pid)
        %{state | monitors: Map.put(state.monitors, ref, :dummy_supervisor)}
      end)

      # Kill the dummy process
      Process.exit(dummy_pid, :kill)

      # Wait for the event broadcast as synchronization
      assert_receive {:minga_event, :supervisor_restarted, payload}, 1_000
      assert payload.name == :dummy_supervisor

      history = SystemObserver.restart_history(name)
      assert [record] = history
      assert %RestartRecord{} = record
      assert record.name == :dummy_supervisor
      assert record.reason == :killed
      assert %DateTime{} = record.wall_time
    end
  end

  describe "process tree walking" do
    setup do
      name = :"observer_#{System.unique_integer([:positive])}"
      observer = start_supervised!({SystemObserver, name: name})
      %{observer: observer, name: name}
    end

    test "collected snapshots contain registered names when available", %{name: name} do
      :ok = SystemObserver.subscribe(name)
      send(name, :tick)
      :sys.get_state(name)

      snapshot = SystemObserver.snapshot(name)
      assert snapshot != nil

      # Find processes with registered names
      named_processes =
        Enum.filter(snapshot.processes, fn {_pid, info} -> info.registered_name != nil end)

      # There should be at least some named processes in a running BEAM
      assert named_processes != []
    end
  end

  describe "circular buffer bounds" do
    test "enqueue_bounded respects max size" do
      name = :"observer_#{System.unique_integer([:positive])}"
      _observer = start_supervised!({SystemObserver, name: name})

      # Manually push samples into state to test bounding
      :sys.replace_state(name, fn state ->
        # Simulate 300 samples already collected
        samples =
          Enum.reduce(1..300, :queue.new(), fn i, q ->
            :queue.in(%{timestamp: i, processes: %{}}, q)
          end)

        %{state | samples: samples, sample_count: 300}
      end)

      # Subscribe and send a tick directly
      :ok = SystemObserver.subscribe(name)
      send(name, :tick)
      :sys.get_state(name)

      state = :sys.get_state(name)
      # Should not exceed 300
      assert state.sample_count <= 300
    end
  end
end
