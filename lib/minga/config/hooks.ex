defmodule Minga.Config.Hooks do
  @moduledoc """
  Registry for lifecycle hooks with sequential effect ordering.

  Hooks are functions registered for specific editor events (save, open,
  mode change). When an event fires, all registered hooks execute their
  observable effects in registration order inside a single supervised runner
  task. A crashing hook is logged and isolated; later hooks for the same
  event continue in order.

  Each event type has at most one active runner at a time. When an event
  fires while a runner is already active for that type, the invocation is
  queued. The queue depth per event type is bounded by `max_pending`
  (default #{64}). When the queue is full, the new invocation is dropped
  and a warning is logged. Different event types run their runners
  concurrently since they have independent ordering contracts.

  Hooks subscribes to the `Minga.Events` bus on startup. When a bus event
  arrives (e.g. `:buffer_saved`), it maps the topic to the corresponding
  hook event (`:after_save`) and fires all registered hooks. Direct
  invocation via `run/2` is still supported for backward compatibility.

  ## Supported events

  | Event            | Arguments                  | Fires when                |
  |------------------|----------------------------|---------------------------|
  | `:after_save`    | `[buffer_pid, file_path]`  | After a successful save   |
  | `:after_open`    | `[buffer_pid, file_path]`  | After opening a file      |
  | `:on_mode_change`| `[old_mode, new_mode]`     | When the editor mode changes |

  ## Admission policy

  Each event type admits at most `max_pending` queued invocations while a
  runner is active. When the queue is full, the newest invocation is dropped.
  Already-admitted invocations are honored in FIFO order.

  ## Example

      Minga.Config.Hooks.register(:after_save, fn _buf, path ->
        System.cmd("mix", ["format", path])
      end)
  """

  use GenServer

  @valid_events [:after_save, :after_open, :on_mode_change]
  @default_max_pending 64
  @default_task_supervisor Minga.Eval.TaskSupervisor

  # Maps event bus topics to hook event names.
  @topic_to_event %{
    buffer_saved: :after_save,
    buffer_opened: :after_open,
    mode_changed: :on_mode_change
  }

  @typedoc "Valid event names."
  @type event :: :after_save | :after_open | :on_mode_change

  @typedoc "Registered hooks keyed by event name."
  @type hooks :: %{event() => [function()]}

  @typedoc "Hook server state."
  @type state :: %{
          hooks: hooks(),
          events_registry: Minga.Events.registry(),
          task_supervisor: atom(),
          max_pending: pos_integer(),
          runners: %{event() => reference()},
          queues: %{event() => :queue.queue([term()])}
        }

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the hooks registry and subscribes to the event bus."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a hook function for an event.

  Hooks fire in registration order. Returns `:ok` or `{:error, reason}`.
  """
  @spec register(event(), function()) :: :ok | {:error, String.t()}
  @spec register(GenServer.server(), event(), function()) :: :ok | {:error, String.t()}
  def register(event, fun) when is_atom(event) and is_function(fun),
    do: register(__MODULE__, event, fun)

  def register(server, event, fun) when is_atom(event) and is_function(fun) do
    if event in @valid_events do
      GenServer.call(server, {:register, event, fun})
    else
      {:error, "unknown event: #{inspect(event)}. Valid events: #{inspect(@valid_events)}"}
    end
  end

  @doc """
  Fires all hooks for an event with sequential effect ordering.

  Each admitted event starts at most one runner task per event type under
  the configured TaskSupervisor. Hooks execute sequentially in registration
  order inside the runner. A crashing hook is logged but does not prevent
  later hooks from running. If a runner is already active for this event
  type, the invocation is queued up to `max_pending` depth; excess
  invocations are dropped.

  This is a fire-and-forget cast: it returns `:ok` immediately. Prefer
  broadcasting through `Minga.Events` over calling this directly.
  """
  @spec run(event(), [term()]) :: :ok
  @spec run(GenServer.server(), event(), [term()]) :: :ok
  def run(event, args) when is_atom(event) and is_list(args),
    do: run(__MODULE__, event, args)

  def run(server, event, args) when is_atom(event) and is_list(args) do
    GenServer.cast(server, {:run, event, args})
  end

  @doc "Returns the list of valid event names."
  @spec valid_events() :: [event()]
  def valid_events, do: @valid_events

  @doc "Removes all registered hooks and drains pending queues."
  @spec reset() :: :ok
  @spec reset(GenServer.server()) :: :ok
  def reset, do: reset(__MODULE__)

  def reset(server) do
    GenServer.call(server, :reset)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    events_registry = Keyword.get(opts, :events_registry, Minga.Events.default_registry())
    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)
    max_pending = Keyword.get(opts, :max_pending, @default_max_pending)
    state = initial_state(events_registry, task_supervisor, max_pending)
    subscribe_to_events(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:register, event, fun}, _from, state) do
    new_state = %{state | hooks: Map.update!(state.hooks, event, &[fun | &1])}
    {:reply, :ok, new_state}
  end

  def handle_call(:reset, _from, state) do
    demonitor_all_runners(state.runners)
    {:reply, :ok, initial_state(state.events_registry, state.task_supervisor, state.max_pending)}
  end

  @impl true
  def handle_cast({:run, event, args}, state) do
    {:noreply, dispatch_event(state, event, args)}
  end

  @impl true
  def handle_info({:minga_event, topic, payload}, state) do
    case Map.fetch(@topic_to_event, topic) do
      {:ok, event} ->
        args = payload_to_args(topic, payload)
        {:noreply, dispatch_event(state, event, args)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_event_for_runner(state.runners, ref) do
      {:ok, event} ->
        if reason not in [:normal, :shutdown] do
          Minga.Log.warning(:config, "Hook runner for #{event} exited: #{inspect(reason)}")
        end

        state = %{state | runners: Map.delete(state.runners, event)}
        {:noreply, maybe_drain_queue(state, event)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec dispatch_event(state(), event(), [term()]) :: state()
  defp dispatch_event(state, event, args) do
    hooks = state.hooks |> Map.get(event, []) |> Enum.reverse()

    if hooks == [] do
      state
    else
      if Map.has_key?(state.runners, event) do
        enqueue_or_drop(state, event, args)
      else
        start_runner(state, event, hooks, args)
      end
    end
  end

  @spec enqueue_or_drop(state(), event(), [term()]) :: state()
  defp enqueue_or_drop(state, event, args) do
    queue = Map.fetch!(state.queues, event)

    if :queue.len(queue) >= state.max_pending do
      Minga.Log.warning(
        :config,
        "Hook queue for #{event} full (#{state.max_pending}), dropping event"
      )

      state
    else
      %{state | queues: Map.put(state.queues, event, :queue.in(args, queue))}
    end
  end

  @spec start_runner(state(), event(), [function()], [term()]) :: state()
  defp start_runner(state, event, hooks, args) do
    {:ok, pid} =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        run_hooks_sequentially(hooks, event, args)
      end)

    ref = Process.monitor(pid)
    %{state | runners: Map.put(state.runners, event, ref)}
  end

  @spec run_hooks_sequentially([function()], event(), [term()]) :: :ok
  defp run_hooks_sequentially(hooks, event, args) do
    for hook <- hooks do
      try do
        apply(hook, args)
      rescue
        e ->
          Minga.Log.warning(:config, "Hook #{event} failed: #{Exception.message(e)}")
      catch
        kind, reason ->
          Minga.Log.warning(
            :config,
            "Hook #{event} crashed: #{inspect(kind)} #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  @spec maybe_drain_queue(state(), event()) :: state()
  defp maybe_drain_queue(state, event) do
    queue = Map.fetch!(state.queues, event)

    case :queue.out(queue) do
      {{:value, args}, rest} ->
        hooks = state.hooks |> Map.get(event, []) |> Enum.reverse()
        state = %{state | queues: Map.put(state.queues, event, rest)}

        if hooks == [] do
          maybe_drain_queue(state, event)
        else
          start_runner(state, event, hooks, args)
        end

      {:empty, _} ->
        state
    end
  end

  @spec find_event_for_runner(%{event() => reference()}, reference()) ::
          {:ok, event()} | :error
  defp find_event_for_runner(runners, ref) do
    case Enum.find(runners, fn {_event, r} -> r == ref end) do
      {event, _ref} -> {:ok, event}
      nil -> :error
    end
  end

  @spec demonitor_all_runners(%{event() => reference()}) :: :ok
  defp demonitor_all_runners(runners) do
    for {_event, ref} <- runners do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  @spec subscribe_to_events(state()) :: :ok
  defp subscribe_to_events(state) do
    for topic <- Map.keys(@topic_to_event) do
      Minga.Events.subscribe(topic, registry: state.events_registry)
    end

    :ok
  end

  @spec payload_to_args(Minga.Events.topic(), Minga.Events.payload()) :: [term()]
  defp payload_to_args(_topic, %Minga.Events.BufferEvent{buffer: buf, path: path}),
    do: [buf, path]

  defp payload_to_args(_topic, %Minga.Events.ModeEvent{old: old_mode, new: new_mode}),
    do: [old_mode, new_mode]

  @spec initial_state(Minga.Events.registry(), atom(), pos_integer()) :: state()
  defp initial_state(events_registry, task_supervisor, max_pending) do
    %{
      hooks: Map.new(@valid_events, &{&1, []}),
      events_registry: events_registry,
      task_supervisor: task_supervisor,
      max_pending: max_pending,
      runners: %{},
      queues: Map.new(@valid_events, &{&1, :queue.new()})
    }
  end
end
