defmodule Minga.SystemObserverTest do
  use ExUnit.Case, async: true

  alias Minga.SystemObserver
  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.RestartRecord

  defp unique_name, do: :"observer_#{System.unique_integer([:positive])}"

  describe "snapshot/1" do
    setup do
      name = unique_name()
      start_supervised!({SystemObserver, name: name})
      %{name: name}
    end

    test "returns nil when no samples collected", %{name: name} do
      assert SystemObserver.snapshot(name) == nil
    end

    test "returns process metrics after polling", %{name: name} do
      :ok = SystemObserver.subscribe(name)
      poll_once(name)

      snapshot = SystemObserver.snapshot(name)
      assert %{timestamp: timestamp, processes: processes} = snapshot
      assert is_integer(timestamp)
      assert map_size(processes) > 0

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
      name = unique_name()
      start_supervised!({SystemObserver, name: name})
      %{name: name}
    end

    test "returns empty list before polling", %{name: name} do
      assert SystemObserver.samples(name) == []
    end

    test "returns samples oldest-first", %{name: name} do
      :ok = SystemObserver.subscribe(name)

      for _ <- 1..3, do: poll_once(name)

      samples = SystemObserver.samples(name)
      assert samples != []
      timestamps = Enum.map(samples, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps)
    end
  end

  describe "restart_history/1" do
    setup do
      name = unique_name()
      start_supervised!({SystemObserver, name: name})
      %{name: name}
    end

    test "returns empty list initially", %{name: name} do
      assert SystemObserver.restart_history(name) == []
    end

    test "records supervisor DOWN events", %{name: name} do
      Minga.Events.subscribe(:supervisor_restarted)
      dummy_pid = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> if Process.alive?(dummy_pid), do: Process.exit(dummy_pid, :kill) end)
      monitor_as_supervisor(name, dummy_pid, :dummy_supervisor)

      Process.exit(dummy_pid, :kill)

      assert_receive {:minga_event, :supervisor_restarted, payload}, 1_000
      assert payload.name == :dummy_supervisor

      assert [%RestartRecord{} = record] = SystemObserver.restart_history(name)
      assert record.name == :dummy_supervisor
      assert record.reason == :killed
      assert %DateTime{} = record.wall_time
    end
  end

  describe "process tree walking" do
    setup do
      name = unique_name()
      start_supervised!({SystemObserver, name: name})
      %{name: name}
    end

    test "collected snapshots include registered process names", %{name: name} do
      :ok = SystemObserver.subscribe(name)
      poll_once(name)

      snapshot = SystemObserver.snapshot(name)

      named_processes =
        Enum.filter(snapshot.processes, fn {_pid, info} -> info.registered_name != nil end)

      assert named_processes != []
    end
  end

  defp poll_once(name) do
    send(name, :tick)
    :sys.get_state(name)
    :ok
  end

  defp monitor_as_supervisor(name, pid, supervisor_name) do
    :sys.replace_state(name, fn state ->
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, ref, supervisor_name)}
    end)
  end
end
