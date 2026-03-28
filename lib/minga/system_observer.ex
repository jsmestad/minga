defmodule Minga.SystemObserver do
  @moduledoc """
  Collects BEAM process metrics and serves multiple visualization features
  from a single data source.

  Three tiers of data collection, each with different cost profiles:

  1. **Always-on (trivially cheap):** Monitors named supervisors via
     `Process.monitor/1`. Tracks restart events and recovery times. Cost
     is one `handle_info({:DOWN, ...})` per supervisor crash, which is
     rare. This powers Resilience-as-UX (#1109).

  2. **On-demand polling (activated when subscribers exist):** Walks the
     supervision tree via `Supervisor.which_children/1`, calls
     `Process.info/2` for each process, and stores snapshots in a circular
     buffer (last 300 samples = 5 minutes at 1Hz). Activated when a UI
     panel subscribes, deactivated when all subscribers disconnect. This
     powers BEAM Observatory (#1081) and Living Architecture (#1098).

  3. **Domain state queries (no collection):** Downstream features read
     existing APIs (Agent.Session, etc.) directly. SystemObserver doesn't
     collect this data; it's listed here for completeness.

  ## Supervision placement

  Lives as the last child under `Minga.Supervisor` (top-level). This
  means it starts after Foundation, Services, and Runtime are all up,
  giving it full visibility into the process tree. With `rest_for_one`,
  a SystemObserver crash restarts nothing (nothing comes after it), and
  a Foundation/Services/Runtime crash restarts SystemObserver too (correct:
  re-establishes monitors).
  """

  use GenServer

  alias Minga.Events
  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.RestartRecord

  # ── Configuration ─────────────────────────────────────────────────────────

  @poll_interval_ms 1_000
  @max_samples 300
  @max_restart_history 50

  # Supervisors to monitor in the always-on tier.
  # These are named processes that exist unconditionally or conditionally.
  @monitored_supervisors [
    Minga.Foundation.Supervisor,
    Minga.Services.Supervisor,
    Minga.Services.Independent,
    Minga.LSP.Supervisor,
    Minga.Extension.Supervisor,
    Minga.Buffer.Supervisor,
    Minga.Agent.Supervisor,
    # Conditional (Runtime may not be started in test/headless mode)
    Minga.Runtime.Supervisor,
    Minga.Editor.Supervisor
  ]

  # ── Types ─────────────────────────────────────────────────────────────────

  @typedoc "A snapshot of process metrics for the entire supervision tree."
  @type process_tree_snapshot :: %{
          timestamp: integer(),
          processes: %{pid() => ProcessSnapshot.t()}
        }

  @typedoc "Internal state for the SystemObserver GenServer."
  @type t :: %{
          monitors: %{reference() => atom()},
          restart_history: [RestartRecord.t()],
          subscribers: MapSet.t(pid()),
          subscriber_monitors: %{reference() => pid()},
          samples: :queue.queue(process_tree_snapshot()),
          sample_count: non_neg_integer(),
          poll_timer: reference() | nil
        }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the SystemObserver GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Subscribes the calling process to process tree snapshots.

  While at least one subscriber exists, SystemObserver polls the process
  tree at 1Hz and stores snapshots. The subscriber receives no messages
  from SystemObserver directly; use `snapshot/0` or `samples/0` to read
  the collected data.

  The subscriber is automatically unsubscribed when it exits.
  """
  @spec subscribe() :: :ok
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Unsubscribes the calling process from process tree snapshots.

  If this was the last subscriber, polling stops.
  """
  @spec unsubscribe() :: :ok
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  @doc """
  Returns the latest process tree snapshot, or `nil` if no samples have
  been collected yet.

  This is a one-shot query. For continuous monitoring, subscribe and read
  `samples/0` periodically.
  """
  @spec snapshot() :: process_tree_snapshot() | nil
  @spec snapshot(GenServer.server()) :: process_tree_snapshot() | nil
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Returns all collected process tree samples as a list, oldest first.

  The maximum number of samples retained is #{@max_samples} (5 minutes
  at 1Hz). Returns an empty list if polling has not been activated.
  """
  @spec samples() :: [process_tree_snapshot()]
  @spec samples(GenServer.server()) :: [process_tree_snapshot()]
  def samples(server \\ __MODULE__) do
    GenServer.call(server, :samples)
  end

  @doc """
  Returns the restart history as a list, most recent first.

  The last #{@max_restart_history} restart events are retained. This is
  always available (always-on tier), regardless of subscriber count.
  """
  @spec restart_history() :: [RestartRecord.t()]
  @spec restart_history(GenServer.server()) :: [RestartRecord.t()]
  def restart_history(server \\ __MODULE__) do
    GenServer.call(server, :restart_history)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    monitors = establish_monitors()

    state = %{
      monitors: monitors,
      restart_history: [],
      subscribers: MapSet.new(),
      subscriber_monitors: %{},
      samples: :queue.new(),
      sample_count: 0,
      poll_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    if MapSet.member?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)

      state =
        state
        |> Map.update!(:subscribers, &MapSet.put(&1, pid))
        |> Map.update!(:subscriber_monitors, &Map.put(&1, ref, pid))
        |> maybe_start_polling()

      {:reply, :ok, state}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    state = remove_subscriber(state, pid)
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    result =
      if :queue.is_empty(state.samples) do
        nil
      else
        :queue.get_r(state.samples)
      end

    {:reply, result, state}
  end

  def handle_call(:samples, _from, state) do
    {:reply, :queue.to_list(state.samples), state}
  end

  def handle_call(:restart_history, _from, state) do
    {:reply, state.restart_history, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if MapSet.size(state.subscribers) > 0 do
      snapshot = collect_snapshot()

      {samples, sample_count} =
        enqueue_bounded(state.samples, state.sample_count, snapshot, @max_samples)

      timer = Process.send_after(self(), :tick, @poll_interval_ms)

      state = %{state | samples: samples, sample_count: sample_count, poll_timer: timer}
      {:noreply, state}
    else
      {:noreply, %{state | poll_timer: nil}}
    end
  end

  # A monitored supervisor went down
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        # Not a supervisor monitor; check if it's a subscriber
        case Map.pop(state.subscriber_monitors, ref) do
          {nil, _} ->
            {:noreply, state}

          {subscriber_pid, subscriber_monitors} ->
            state = %{state | subscriber_monitors: subscriber_monitors}
            state = remove_subscriber(state, subscriber_pid)
            {:noreply, state}
        end

      {supervisor_name, monitors} ->
        record = %RestartRecord{
          name: supervisor_name,
          pid: pid,
          reason: reason,
          timestamp: System.monotonic_time(:millisecond),
          wall_time: DateTime.utc_now()
        }

        restart_history =
          [record | state.restart_history]
          |> Enum.take(@max_restart_history)

        state = %{state | monitors: monitors, restart_history: restart_history}

        # Broadcast the restart event
        Events.broadcast(
          :supervisor_restarted,
          %Events.SupervisorRestartedEvent{
            name: supervisor_name,
            pid: pid,
            reason: reason,
            restarted_at: record.wall_time
          }
        )

        Minga.Log.warning(
          :editor,
          "[SystemObserver] Supervisor #{inspect(supervisor_name)} went down: #{inspect(reason)}"
        )

        # Try to re-establish the monitor after the supervisor restarts.
        # Use send_after to give the supervisor tree time to restart.
        Process.send_after(self(), {:remonitor, supervisor_name}, 500)

        {:noreply, state}
    end
  end

  def handle_info({:remonitor, supervisor_name}, state) do
    state =
      case Process.whereis(supervisor_name) do
        nil ->
          # Still not back. Try again later.
          Process.send_after(self(), {:remonitor, supervisor_name}, 1_000)
          state

        pid ->
          ref = Process.monitor(pid)
          %{state | monitors: Map.put(state.monitors, ref, supervisor_name)}
      end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec establish_monitors() :: %{reference() => atom()}
  defp establish_monitors do
    Enum.reduce(@monitored_supervisors, %{}, fn name, acc ->
      case Process.whereis(name) do
        nil ->
          acc

        pid ->
          ref = Process.monitor(pid)
          Map.put(acc, ref, name)
      end
    end)
  end

  @spec remove_subscriber(t(), pid()) :: t()
  defp remove_subscriber(state, pid) do
    # Find and demonitor the subscriber's monitor ref
    {ref_to_remove, remaining_monitors} =
      Enum.reduce(state.subscriber_monitors, {nil, %{}}, fn {ref, monitored_pid}, {found, acc} ->
        if monitored_pid == pid do
          {ref, acc}
        else
          {found, Map.put(acc, ref, monitored_pid)}
        end
      end)

    if ref_to_remove, do: Process.demonitor(ref_to_remove, [:flush])

    state
    |> Map.put(:subscribers, MapSet.delete(state.subscribers, pid))
    |> Map.put(:subscriber_monitors, remaining_monitors)
    |> maybe_stop_polling()
  end

  @spec maybe_start_polling(t()) :: t()
  defp maybe_start_polling(state) do
    if state.poll_timer == nil and MapSet.size(state.subscribers) > 0 do
      timer = Process.send_after(self(), :tick, 0)
      %{state | poll_timer: timer}
    else
      state
    end
  end

  @spec maybe_stop_polling(t()) :: t()
  defp maybe_stop_polling(state) do
    if MapSet.size(state.subscribers) == 0 and state.poll_timer != nil do
      Process.cancel_timer(state.poll_timer)
      %{state | poll_timer: nil}
    else
      state
    end
  end

  @spec collect_snapshot() :: process_tree_snapshot()
  defp collect_snapshot do
    processes = walk_supervision_tree(Minga.Supervisor)

    %{
      timestamp: System.monotonic_time(:millisecond),
      processes: processes
    }
  end

  @spec walk_supervision_tree(atom()) :: %{pid() => ProcessSnapshot.t()}
  defp walk_supervision_tree(supervisor_name) when is_atom(supervisor_name) do
    case Process.whereis(supervisor_name) do
      nil -> %{}
      pid -> walk_supervisor(pid, %{})
    end
  end

  # Walk a known supervisor: collect its own info, then recurse into children.
  # Uses the `type` field from `which_children` to distinguish :supervisor
  # children (recurse) from :worker children (collect info only, don't call
  # which_children on them since that would crash them or deadlock).
  @spec walk_supervisor(pid(), %{pid() => ProcessSnapshot.t()}) ::
          %{pid() => ProcessSnapshot.t()}
  defp walk_supervisor(sup_pid, acc) do
    acc = Map.put(acc, sup_pid, collect_process_info(sup_pid))

    children = Supervisor.which_children(sup_pid)

    Enum.reduce(children, acc, fn child, inner_acc ->
      collect_child(child, inner_acc)
    end)
  catch
    :exit, _ ->
      # Supervisor is shutting down or unreachable
      acc
  end

  @spec collect_child(
          {term(), pid() | :restarting | :undefined, :worker | :supervisor, [module()]},
          %{pid() => ProcessSnapshot.t()}
        ) :: %{pid() => ProcessSnapshot.t()}
  defp collect_child({_id, child_pid, :supervisor, _modules}, acc) when is_pid(child_pid) do
    walk_supervisor(child_pid, acc)
  end

  defp collect_child({_id, child_pid, :worker, _modules}, acc) when is_pid(child_pid) do
    Map.put(acc, child_pid, collect_process_info(child_pid))
  end

  defp collect_child({_id, _not_running, _type, _modules}, acc) do
    # Child is :restarting or :undefined
    acc
  end

  @spec collect_process_info(pid()) :: ProcessSnapshot.t()
  defp collect_process_info(pid) do
    info =
      Process.info(pid, [
        :memory,
        :message_queue_len,
        :reductions,
        :current_function,
        :registered_name
      ])

    case info do
      nil ->
        %ProcessSnapshot{
          memory: 0,
          message_queue_len: 0,
          reductions: 0,
          current_function: nil,
          registered_name: nil
        }

      info_list ->
        %ProcessSnapshot{
          memory: Keyword.get(info_list, :memory, 0),
          message_queue_len: Keyword.get(info_list, :message_queue_len, 0),
          reductions: Keyword.get(info_list, :reductions, 0),
          current_function: Keyword.get(info_list, :current_function),
          registered_name: Keyword.get(info_list, :registered_name)
        }
    end
  end

  @spec enqueue_bounded(:queue.queue(a), non_neg_integer(), a, pos_integer()) ::
          {:queue.queue(a), non_neg_integer()}
        when a: var
  defp enqueue_bounded(queue, count, item, max) do
    queue = :queue.in(item, queue)

    if count >= max do
      {_, queue} = :queue.out(queue)
      {queue, count}
    else
      {queue, count + 1}
    end
  end
end
