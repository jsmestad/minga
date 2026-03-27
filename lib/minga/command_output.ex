defmodule Minga.CommandOutput do
  @moduledoc """
  Runs a shell command and streams its output into a dedicated buffer.

  Each named output (e.g., `"*test*"`) is a GenServer that owns an Erlang
  Port running the command. stdout and stderr are streamed line-by-line
  into a `:nowrite` Buffer. If a command with the same name is already
  running, it is killed before starting the new one.

  This is a generic primitive reusable for test runners, build commands,
  lint, or any "run a shell command, show output in a buffer" workflow.
  """

  use GenServer

  alias Minga.Buffer

  @type t :: %__MODULE__{
          name: String.t(),
          buffer: pid() | nil,
          buffer_monitor: reference() | nil,
          port: port() | nil,
          command: String.t() | nil,
          cwd: String.t() | nil,
          exit_code: non_neg_integer() | nil,
          running?: boolean()
        }

  defstruct name: nil,
            buffer: nil,
            buffer_monitor: nil,
            port: nil,
            command: nil,
            cwd: nil,
            exit_code: nil,
            running?: false

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Starts a CommandOutput server with the given name.

  The name is used as both the GenServer registration name and the
  buffer label (e.g., `"*test*"`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  @doc """
  Runs a command, streaming output into the named buffer.

  If a command is already running under this name, it is killed first.
  The buffer is cleared before the new command starts.

  Options:
    - `:cwd` - working directory for the command (default: project root)
  """
  @spec run(String.t(), String.t(), keyword()) :: :ok
  def run(name, command, opts \\ []) do
    case lookup(name) do
      {:ok, pid} ->
        GenServer.call(pid, {:run, command, opts})

      :error ->
        {:ok, pid} =
          DynamicSupervisor.start_child(
            Minga.Buffer.Supervisor,
            {__MODULE__, name: name}
          )

        GenServer.call(pid, {:run, command, opts})
    end
  end

  @doc "Returns the buffer pid for the named output, or nil."
  @spec buffer(String.t()) :: pid() | nil
  def buffer(name) do
    case lookup(name) do
      {:ok, pid} -> GenServer.call(pid, :buffer)
      :error -> nil
    end
  end

  @doc "Returns true if the named output has a command currently running."
  @spec running?(String.t()) :: boolean()
  def running?(name) do
    case lookup(name) do
      {:ok, pid} -> GenServer.call(pid, :running?)
      :error -> false
    end
  end

  @doc "Kills the running command (if any) for the named output."
  @spec kill(String.t()) :: :ok
  def kill(name) do
    case lookup(name) do
      {:ok, pid} -> GenServer.call(pid, :kill)
      :error -> :ok
    end
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    {:ok, %__MODULE__{name: name}}
  end

  @impl true
  def handle_call({:run, command, opts}, _from, state) do
    state = kill_if_running(state)
    state = ensure_buffer(state)

    # Clear the buffer and write a header
    cwd = Keyword.get(opts, :cwd, Minga.Project.root() || ".")
    Buffer.replace_content_force(state.buffer, "$ #{command}\n\n")

    port =
      Port.open({:spawn, command}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        {:cd, cwd},
        {:env, []}
      ])

    {:reply, :ok,
     %{state | port: port, command: command, cwd: cwd, exit_code: nil, running?: true}}
  end

  def handle_call(:buffer, _from, state) do
    state = ensure_buffer(state)
    {:reply, state.buffer, state}
  end

  def handle_call(:running?, _from, state) do
    {:reply, state.running?, state}
  end

  def handle_call(:kill, _from, state) do
    {:reply, :ok, kill_if_running(state)}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    if state.buffer, do: Buffer.append(state.buffer, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    if state.buffer do
      Buffer.append(state.buffer, "\n\n[Process exited with code #{code}]")
    end

    Minga.Events.broadcast(
      :command_done,
      %Minga.Events.CommandDoneEvent{name: state.name, exit_code: code}
    )

    {:noreply, %{state | port: nil, exit_code: code, running?: false}}
  end

  # Buffer died — clear the stale pid so we recreate on next use.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{buffer_monitor: ref} = state) do
    {:noreply, %{state | buffer: nil, buffer_monitor: nil}}
  end

  # Ignore messages from old ports or stale monitors
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ────────────────────────────────────────────────────────────────

  @spec kill_if_running(t()) :: t()
  defp kill_if_running(%{port: nil} = state), do: state

  defp kill_if_running(%{port: port} = state) do
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    %{state | port: nil, running?: false}
  end

  @spec ensure_buffer(t()) :: t()
  defp ensure_buffer(%{buffer: buf} = state) when is_pid(buf) do
    Buffer.buffer_name(buf)
    state
  catch
    # Liveness probe: the monitor handles the common case, but there's a narrow
    # race where the buffer dies between monitor delivery and this call.
    # Targeted catch per AGENTS.md rule 4.
    :exit, _ -> create_buffer(state)
  end

  defp ensure_buffer(state), do: create_buffer(state)

  @spec create_buffer(t()) :: t()
  defp create_buffer(state) do
    if state.buffer_monitor, do: Process.demonitor(state.buffer_monitor, [:flush])

    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {Minga.Buffer,
            buffer_name: state.name,
            content: "",
            read_only: true,
            unlisted: true,
            persistent: true}
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{state | buffer: pid, buffer_monitor: ref}

      _ ->
        %{state | buffer: nil, buffer_monitor: nil}
    end
  end

  @spec via(String.t()) :: {:via, Registry, {Minga.CommandOutput.Registry, String.t()}}
  defp via(name), do: {:via, Registry, {Minga.CommandOutput.Registry, name}}

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  defp lookup(name) do
    case Registry.lookup(Minga.CommandOutput.Registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end
end
