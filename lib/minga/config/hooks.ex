defmodule Minga.Config.Hooks do
  @moduledoc """
  Registry for lifecycle hooks.

  Hooks are functions registered for specific editor events (save, open,
  mode change). When an event fires, all registered hooks run asynchronously
  under `Minga.Eval.TaskSupervisor`, so a slow or crashing hook never blocks
  editing.

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

  ## Example

      Minga.Config.Hooks.register(:after_save, fn _buf, path ->
        System.cmd("mix", ["format", path])
      end)
  """

  use GenServer

  @valid_events [:after_save, :after_open, :on_mode_change]

  # Maps event bus topics to hook event names.
  @topic_to_event %{
    buffer_saved: :after_save,
    buffer_opened: :after_open,
    mode_changed: :on_mode_change
  }

  @typedoc "Valid event names."
  @type event :: :after_save | :after_open | :on_mode_change

  @typedoc "Hook state: event name → list of hook functions."
  @type state :: %{event() => [function()]}

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the hooks registry and subscribes to the event bus."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
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
  Fires all hooks for an event asynchronously.

  Each hook runs in a separate Task under `Minga.Eval.TaskSupervisor`.
  Crashes are logged but don't propagate. This is a fire-and-forget cast:
  it returns `:ok` immediately before hooks are dispatched. Prefer
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

  @doc "Removes all registered hooks."
  @spec reset() :: :ok
  @spec reset(GenServer.server()) :: :ok
  def reset, do: reset(__MODULE__)

  def reset(server) do
    GenServer.call(server, :reset)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    subscribe_to_events()
    {:ok, initial_state()}
  end

  @impl true
  def handle_call({:register, event, fun}, _from, state) do
    new_state = Map.update!(state, event, &[fun | &1])
    {:reply, :ok, new_state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, initial_state()}
  end

  @impl true
  def handle_cast({:run, event, args}, state) do
    do_run(state, event, args)
    {:noreply, state}
  end

  @impl true
  def handle_info({:minga_event, topic, payload}, state) do
    case Map.fetch(@topic_to_event, topic) do
      {:ok, event} ->
        args = payload_to_args(topic, payload)
        do_run(state, event, args)

      :error ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec subscribe_to_events() :: :ok
  defp subscribe_to_events do
    for topic <- Map.keys(@topic_to_event) do
      Minga.Events.subscribe(topic)
    end

    :ok
  end

  @spec payload_to_args(Minga.Events.topic(), Minga.Events.payload()) :: [term()]
  defp payload_to_args(:buffer_saved, %{buffer: buf, path: path}), do: [buf, path]
  defp payload_to_args(:buffer_opened, %{buffer: buf, path: path}), do: [buf, path]
  defp payload_to_args(:mode_changed, %{old: old_mode, new: new_mode}), do: [old_mode, new_mode]

  @spec do_run(state(), event(), [term()]) :: :ok
  defp do_run(state, event, args) do
    hooks = Map.get(state, event, []) |> Enum.reverse()

    for hook <- hooks do
      Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
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
      end)
    end

    :ok
  end

  @spec initial_state() :: state()
  defp initial_state do
    Map.new(@valid_events, &{&1, []})
  end
end
