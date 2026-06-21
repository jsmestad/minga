defmodule MingaAgent.StatusCommand do
  @moduledoc """
  Caches user-provided agent status modeline text.

  The command runs outside the render path. Render code only updates the latest
  context and reads the last successful stdout value.
  """

  use GenServer

  alias Minga.Config.Options

  @min_interval_ms 1_000
  @default_timeout_ms 1_000
  @tick :tick

  @type context :: %{
          optional(:session_id) => String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:status) => atom() | String.t() | nil,
          optional(:workdir) => String.t() | nil
        }

  @type state :: %{
          command: String.t() | nil,
          interval_ms: pos_integer(),
          context: context(),
          value: String.t() | nil,
          task: Task.t() | nil,
          timer: reference() | nil,
          next_run_at_ms: integer() | nil,
          failure_reported?: boolean(),
          task_supervisor: module(),
          config_server: Options.server()
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the last successful command output, or nil for built-in status."
  @spec content(context(), GenServer.server()) :: String.t() | nil
  def content(context, server \\ __MODULE__) when is_map(context) do
    if server_alive?(server) do
      GenServer.call(server, {:content, context}, 100)
    else
      nil
    end
  catch
    :exit, _ -> nil
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    state = %{
      command: nil,
      interval_ms: @min_interval_ms,
      context: %{},
      value: nil,
      task: nil,
      timer: nil,
      next_run_at_ms: nil,
      failure_reported?: false,
      task_supervisor: Keyword.get(opts, :task_supervisor, Minga.Eval.TaskSupervisor),
      config_server: Keyword.get(opts, :config_server, Options.default_server())
    }

    {:ok, schedule(refresh_config(state), 0)}
  end

  @impl true
  def handle_call({:content, context}, _from, state) do
    state =
      state
      |> Map.put(:context, normalize_context(context))
      |> refresh_config()
      |> maybe_start_task()
      |> schedule_current_interval()

    {:reply, state.value, state}
  end

  @impl true
  def handle_info(@tick, state) do
    state =
      state
      |> Map.put(:timer, nil)
      |> refresh_config()
      |> maybe_start_task()
      |> schedule_current_interval()

    {:noreply, state}
  end

  def handle_info({ref, {:ok, output}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil, value: output, failure_reported?: false}}
  end

  def handle_info({ref, {:error, reason}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, command_failed(%{state | task: nil}, reason)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, command_failed(%{state | task: nil}, reason)}
  end

  def handle_info({:command_timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, command_failed(%{state | task: nil}, :timeout)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec refresh_config(state()) :: state()
  defp refresh_config(state) do
    command = configured_command(state)
    interval_ms = configured_interval_ms(state)

    if command == state.command and interval_ms == state.interval_ms do
      state
    else
      state
      |> cancel_timer()
      |> cancel_task()
      |> Map.merge(%{
        command: command,
        interval_ms: interval_ms,
        value: nil,
        next_run_at_ms: nil,
        failure_reported?: false
      })
      |> schedule(0)
    end
  end

  @spec configured_command(state()) :: String.t() | nil
  defp configured_command(%{config_server: config_server}) do
    case Options.get(config_server, :agent_status_command) do
      command when is_binary(command) -> String.trim(command) |> blank_to_nil()
      _other -> nil
    end
  end

  @spec configured_interval_ms(state()) :: pos_integer()
  defp configured_interval_ms(%{config_server: config_server}) do
    case Options.get(config_server, :agent_status_interval_ms) do
      value when is_integer(value) -> max(value, @min_interval_ms)
      _other -> 5_000
    end
  end

  @spec blank_to_nil(String.t()) :: String.t() | nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @spec maybe_start_task(state()) :: state()
  defp maybe_start_task(%{command: nil} = state), do: %{state | value: nil}
  defp maybe_start_task(%{context: context} = state) when map_size(context) == 0, do: state
  defp maybe_start_task(%{task: %Task{}} = state), do: state
  defp maybe_start_task(%{next_run_at_ms: nil} = state), do: start_task(state, now_ms())

  defp maybe_start_task(%{next_run_at_ms: next_run_at_ms} = state) do
    now = now_ms()

    if now >= next_run_at_ms do
      start_task(state, now)
    else
      state
    end
  end

  @spec start_task(state(), integer()) :: state()
  defp start_task(%{command: command, context: context, task_supervisor: supervisor} = state, now) do
    task = Task.Supervisor.async_nolink(supervisor, fn -> run_command(command, context) end)
    Process.send_after(self(), {:command_timeout, task.ref}, @default_timeout_ms)
    %{state | task: task, next_run_at_ms: now + state.interval_ms}
  catch
    :exit, reason -> command_failed(state, reason)
  end

  @spec run_command(String.t(), context()) :: {:ok, String.t()} | {:error, term()}
  defp run_command(command, context) do
    workdir = Map.get(context, :workdir) || File.cwd!()

    case System.cmd("sh", ["-c", command],
           cd: workdir,
           env: env(context),
           stderr_to_stdout: false
         ) do
      {output, 0} -> command_output(output)
      {_output, status} -> {:error, {:exit_status, status}}
    end
  rescue
    error -> {:error, error}
  end

  @spec command_output(String.t()) :: {:ok, String.t()} | {:error, :empty_output}
  defp command_output(output) do
    case String.trim(output) do
      "" -> {:error, :empty_output}
      text -> {:ok, text}
    end
  end

  @spec env(context()) :: [{String.t(), String.t()}]
  defp env(context) do
    [
      {"MINGA_SESSION_ID", env_value(Map.get(context, :session_id))},
      {"MINGA_MODEL", env_value(Map.get(context, :model))},
      {"MINGA_STATUS", env_value(Map.get(context, :status))},
      {"MINGA_WORKDIR", env_value(Map.get(context, :workdir) || File.cwd!())}
    ]
  end

  @spec env_value(term()) :: String.t()
  defp env_value(nil), do: ""
  defp env_value(value) when is_atom(value), do: Atom.to_string(value)
  defp env_value(value), do: to_string(value)

  @spec now_ms() :: integer()
  defp now_ms, do: System.monotonic_time(:millisecond)

  @spec command_failed(state(), term()) :: state()
  defp command_failed(state, reason) do
    unless state.failure_reported? do
      Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
        text: "Agent status command failed, using built-in modeline: #{inspect(reason)}",
        level: :info
      })
    end

    %{state | value: nil, failure_reported?: true}
  end

  @spec schedule_current_interval(state()) :: state()
  defp schedule_current_interval(state), do: schedule(state, state.interval_ms)

  @spec schedule(state(), non_neg_integer()) :: state()
  defp schedule(%{timer: nil} = state, delay_ms) do
    %{state | timer: Process.send_after(self(), @tick, delay_ms)}
  end

  defp schedule(state, _delay_ms), do: state

  @spec cancel_timer(state()) :: state()
  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  @spec cancel_task(state()) :: state()
  defp cancel_task(%{task: nil} = state), do: state

  defp cancel_task(%{task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | task: nil}
  end

  @spec normalize_context(map()) :: context()
  defp normalize_context(context) do
    %{
      session_id: Map.get(context, :session_id),
      model: Map.get(context, :model),
      status: Map.get(context, :status),
      workdir: Map.get(context, :workdir)
    }
  end

  @spec server_alive?(GenServer.server()) :: boolean()
  defp server_alive?(server) when is_pid(server), do: Process.alive?(server)
  defp server_alive?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp server_alive?(_server), do: false
end
