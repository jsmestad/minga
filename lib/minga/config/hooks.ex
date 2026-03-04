defmodule Minga.Config.Hooks do
  @moduledoc """
  Registry for lifecycle hooks.

  Hooks are functions registered for specific editor events (save, open,
  mode change). When an event fires, all registered hooks run asynchronously
  under `Minga.Eval.TaskSupervisor`, so a slow or crashing hook never blocks
  editing.

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

  use Agent

  require Logger

  @valid_events [:after_save, :after_open, :on_mode_change]

  @typedoc "Valid event names."
  @type event :: :after_save | :after_open | :on_mode_change

  @typedoc "Hook state: event name → list of hook functions."
  @type state :: %{event() => [function()]}

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the hooks registry."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    Agent.start_link(fn -> initial_state() end, name: name)
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
      Agent.update(server, fn state ->
        Map.update!(state, event, &[fun | &1])
      end)
    else
      {:error, "unknown event: #{inspect(event)}. Valid events: #{inspect(@valid_events)}"}
    end
  end

  @doc """
  Fires all hooks for an event asynchronously.

  Each hook runs in a separate Task under `Minga.Eval.TaskSupervisor`.
  Crashes are logged but don't propagate.
  """
  @spec run(event(), [term()]) :: :ok
  @spec run(GenServer.server(), event(), [term()]) :: :ok
  def run(event, args) when is_atom(event) and is_list(args),
    do: run(__MODULE__, event, args)

  def run(server, event, args) when is_atom(event) and is_list(args) do
    hooks = Agent.get(server, &Map.get(&1, event, [])) |> Enum.reverse()

    for hook <- hooks do
      Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
        try do
          apply(hook, args)
        rescue
          e ->
            Logger.warning("Hook #{event} failed: #{Exception.message(e)}")
        catch
          kind, reason ->
            Logger.warning("Hook #{event} crashed: #{inspect(kind)} #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  @doc "Returns the list of valid event names."
  @spec valid_events() :: [event()]
  def valid_events, do: @valid_events

  @doc "Removes all registered hooks."
  @spec reset() :: :ok
  @spec reset(GenServer.server()) :: :ok
  def reset, do: reset(__MODULE__)
  def reset(server), do: Agent.update(server, fn _ -> initial_state() end)

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec initial_state() :: state()
  defp initial_state do
    Map.new(@valid_events, &{&1, []})
  end
end
