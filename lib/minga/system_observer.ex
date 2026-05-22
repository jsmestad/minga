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
    MingaAgent.Supervisor,
    # Conditional (Runtime may not be started in test/headless mode)
    Minga.Runtime.Supervisor,
    MingaEditor.Supervisor
  ]

  # ── Types ─────────────────────────────────────────────────────────────────

  @typedoc "A snapshot of process metrics for the entire supervision tree."
  @type process_tree_snapshot :: %{
          timestamp: integer(),
          processes: %{pid() => ProcessSnapshot.t()}
        }

  @type child_type :: ProcessSnapshot.child_type()
  @type child_modules :: [module()] | :dynamic
  @type process_class :: ProcessSnapshot.process_class()

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

  @doc """
  Classifies a process for Observatory rendering.
  """
  @spec classify_process(pid(), atom() | nil, child_type()) :: process_class()
  def classify_process(pid, registered_name, child_type) when is_pid(pid) do
    classify_process(pid, registered_name, child_type, [])
  end

  @doc """
  Classifies a process for Observatory rendering using supervisor child modules when available.
  """
  @spec classify_process(pid(), atom() | nil, child_type(), child_modules()) :: process_class()
  def classify_process(pid, registered_name, child_type, child_modules) when is_pid(pid) do
    classify_by_child_type(child_type) ||
      classify_buffer_process(pid) ||
      classify_by_modules(child_modules) ||
      classify_by_registered_name(registered_name) ||
      :worker
  end

  @doc """
  Classifies a process by registered name and child type.
  """
  @spec classify_process(atom() | nil, child_type()) :: process_class()
  def classify_process(registered_name, child_type) do
    classify_by_child_type(child_type) || classify_by_registered_name(registered_name) || :worker
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
      pid -> walk_supervisor(pid, nil, %{})
    end
  end

  # Walk a known supervisor: collect its own info, then recurse into children.
  # Uses the `type` field from `which_children` to distinguish :supervisor
  # children (recurse) from :worker children (collect info only, don't call
  # which_children on them since that would crash them or deadlock).
  @spec walk_supervisor(pid(), pid() | nil, %{pid() => ProcessSnapshot.t()}) ::
          %{pid() => ProcessSnapshot.t()}
  defp walk_supervisor(sup_pid, parent_pid, acc) do
    acc =
      Map.put(
        acc,
        sup_pid,
        collect_process_info(sup_pid, parent_pid, :supervisor, [Minga.Supervisor])
      )

    children = Supervisor.which_children(sup_pid)

    Enum.reduce(children, acc, fn child, inner_acc ->
      collect_child(child, sup_pid, inner_acc)
    end)
  catch
    :exit, _ ->
      # Supervisor is shutting down or unreachable
      acc
  end

  @spec collect_child(
          {term(), pid() | :restarting | :undefined, :worker | :supervisor, child_modules()},
          pid(),
          %{pid() => ProcessSnapshot.t()}
        ) :: %{pid() => ProcessSnapshot.t()}
  defp collect_child({_id, child_pid, :supervisor, _modules}, parent_pid, acc)
       when is_pid(child_pid) do
    walk_supervisor(child_pid, parent_pid, acc)
  end

  defp collect_child({_id, child_pid, :worker, modules}, parent_pid, acc)
       when is_pid(child_pid) do
    Map.put(acc, child_pid, collect_process_info(child_pid, parent_pid, :worker, modules))
  end

  defp collect_child({_id, _not_running, _type, _modules}, _parent_pid, acc) do
    # Child is :restarting or :undefined
    acc
  end

  @spec collect_process_info(pid(), pid() | nil, child_type(), child_modules()) ::
          ProcessSnapshot.t()
  defp collect_process_info(pid, parent_pid, child_type, child_modules) do
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
        build_snapshot(pid, [], parent_pid, child_type, child_modules)

      info_list ->
        build_snapshot(pid, info_list, parent_pid, child_type, child_modules)
    end
  end

  @spec build_snapshot(pid(), keyword(), pid() | nil, child_type(), child_modules()) ::
          ProcessSnapshot.t()
  defp build_snapshot(pid, info_list, parent_pid, child_type, child_modules) do
    registered_name = normalize_registered_name(Keyword.get(info_list, :registered_name))

    %ProcessSnapshot{
      memory: Keyword.get(info_list, :memory, 0),
      message_queue_len: Keyword.get(info_list, :message_queue_len, 0),
      reductions: Keyword.get(info_list, :reductions, 0),
      current_function: Keyword.get(info_list, :current_function),
      registered_name: registered_name,
      parent_pid: parent_pid,
      child_type: child_type,
      process_class: classify_process(pid, registered_name, child_type, child_modules)
    }
  end

  @spec normalize_registered_name(term()) :: atom() | nil
  defp normalize_registered_name(name) when is_atom(name), do: name
  defp normalize_registered_name(_name), do: nil

  @spec classify_by_child_type(child_type()) :: process_class() | nil
  defp classify_by_child_type(:supervisor), do: :supervisor
  defp classify_by_child_type(_child_type), do: nil

  @spec classify_buffer_process(pid()) :: :buffer | nil
  defp classify_buffer_process(pid) do
    case buffer_registry_keys(pid) do
      [] -> nil
      _keys -> :buffer
    end
  end

  @spec buffer_registry_keys(pid()) :: [term()]
  defp buffer_registry_keys(pid) do
    Registry.keys(Minga.Buffer.Registry, pid)
  rescue
    ArgumentError -> []
  end

  @spec classify_by_modules(child_modules()) :: process_class() | nil
  defp classify_by_modules(:dynamic), do: nil
  defp classify_by_modules([]), do: nil

  defp classify_by_modules([module | rest]) when is_atom(module) do
    classify_by_module(module) || classify_by_modules(rest)
  end

  @spec classify_by_module(module()) :: process_class() | nil
  defp classify_by_module(module) do
    module
    |> Atom.to_string()
    |> classify_by_name_string()
  end

  @spec classify_by_registered_name(atom() | nil) :: process_class() | nil
  defp classify_by_registered_name(nil), do: nil

  defp classify_by_registered_name(registered_name) when is_atom(registered_name) do
    registered_name
    |> Atom.to_string()
    |> classify_by_name_string()
  end

  @spec classify_by_name_string(String.t()) :: process_class() | nil
  defp classify_by_name_string("Elixir.Minga.Buffer"), do: :buffer
  defp classify_by_name_string("Elixir.Minga.Buffer." <> _suffix), do: :buffer
  defp classify_by_name_string("Elixir.MingaAgent." <> _suffix), do: :agent_session
  defp classify_by_name_string("Elixir.Minga.LSP." <> _suffix), do: :lsp
  defp classify_by_name_string("Elixir.Minga.Config." <> _suffix), do: :service
  defp classify_by_name_string("Elixir.Minga.Events"), do: :service
  defp classify_by_name_string("Elixir.Minga.Foundation." <> _suffix), do: :service
  defp classify_by_name_string("Elixir.Minga.Language." <> _suffix), do: :service
  defp classify_by_name_string("Elixir.Minga.Command." <> _suffix), do: :service
  defp classify_by_name_string("Elixir.Minga.Extension." <> _suffix), do: :service
  defp classify_by_name_string("Elixir.Minga.Git." <> _suffix), do: :service
  defp classify_by_name_string("Elixir.Minga.Project." <> _suffix), do: :service
  defp classify_by_name_string("Elixir.Minga.Services." <> _suffix), do: :service
  defp classify_by_name_string(_registered_name), do: nil

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
