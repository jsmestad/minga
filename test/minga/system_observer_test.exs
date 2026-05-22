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
      assert first_process.child_type in [:supervisor, :worker]

      assert first_process.process_class in [
               :supervisor,
               :buffer,
               :agent_session,
               :lsp,
               :service,
               :worker
             ]
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

    test "collected snapshots include registered process names and hierarchy metadata", %{
      name: name
    } do
      :ok = SystemObserver.subscribe(name)
      poll_once(name)

      snapshot = SystemObserver.snapshot(name)

      named_processes =
        Enum.filter(snapshot.processes, fn {_pid, info} -> info.registered_name != nil end)

      child_processes =
        Enum.filter(snapshot.processes, fn {_pid, info} -> info.parent_pid != nil end)

      assert named_processes != []
      assert child_processes != []
      assert Enum.any?(snapshot.processes, fn {_pid, info} -> info.child_type == :supervisor end)
      assert Enum.all?(snapshot.processes, fn {_pid, info} -> info.process_class != nil end)
    end
  end

  describe "classify_process/2" do
    setup do
      name = unique_name()
      start_supervised!({SystemObserver, name: name})
      %{name: name}
    end

    test "classifies supervisors from child type" do
      assert SystemObserver.classify_process(Minga.Buffer.Process, :supervisor) == :supervisor
    end

    test "classifies known process families by registered name" do
      assert SystemObserver.classify_process(Minga.Buffer.Process, :worker) == :buffer
      assert SystemObserver.classify_process(MingaAgent.Session, :worker) == :agent_session
      assert SystemObserver.classify_process(Minga.LSP.Supervisor, :worker) == :lsp
      assert SystemObserver.classify_process(Minga.Config.Options, :worker) == :service
      assert SystemObserver.classify_process(Some.Other.Worker, :worker) == :worker
      assert SystemObserver.classify_process(nil, :worker) == :worker
    end

    test "collected snapshots include hierarchy fields for child processes", %{name: name} do
      :ok = SystemObserver.subscribe(name)
      poll_once(name)

      snapshot = SystemObserver.snapshot(name)
      root_pid = Process.whereis(Minga.Supervisor)
      root_snapshot = Map.fetch!(snapshot.processes, root_pid)

      assert root_snapshot.parent_pid == nil
      assert root_snapshot.child_type == :supervisor
      assert root_snapshot.process_class == :supervisor

      child_snapshots =
        Enum.reject(snapshot.processes, fn {_pid, info} -> info.parent_pid == nil end)

      assert child_snapshots != []

      assert Enum.all?(child_snapshots, fn {_pid, info} ->
               Map.has_key?(snapshot.processes, info.parent_pid)
             end)
    end
  end

  describe "classify_process/3" do
    test "classifies supervisors from child type" do
      assert SystemObserver.classify_process(self(), nil, :supervisor) == :supervisor
    end

    test "classifies registered buffer processes" do
      key = "buffer-#{System.unique_integer([:positive])}"
      Registry.register(Minga.Buffer.Registry, key, nil)
      on_exit(fn -> Registry.unregister(Minga.Buffer.Registry, key) end)

      assert SystemObserver.classify_process(self(), nil, :worker) == :buffer
    end

    test "classifies agent, lsp, service, and fallback workers from registered names" do
      assert SystemObserver.classify_process(MingaAgent.SessionManager, :worker) == :agent_session
      assert SystemObserver.classify_process(Minga.LSP.Supervisor, :worker) == :lsp
      assert SystemObserver.classify_process(Minga.Config.Options, :worker) == :service
      assert SystemObserver.classify_process(:some_unrelated_process, :worker) == :worker
    end

    test "classifies unnamed dynamic workers from supervisor child modules" do
      assert SystemObserver.classify_process(self(), nil, :worker, [Minga.Buffer]) == :buffer

      assert SystemObserver.classify_process(self(), nil, :worker, [MingaAgent.Session]) ==
               :agent_session

      assert SystemObserver.classify_process(self(), nil, :worker, [Minga.LSP.Client]) == :lsp
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
