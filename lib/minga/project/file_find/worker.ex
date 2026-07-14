defmodule Minga.Project.FileFind.Worker do
  @moduledoc """
  Owns one external project-file discovery process.

  The worker monitors its requester and terminates the external process tree when cancelled or when the requester exits. Port output is accumulated asynchronously so project root switches and shutdown never leave a blocked `System.cmd/3` caller behind.
  """

  use GenServer

  @enforce_keys [:owner, :owner_ref, :port, :parser]
  defstruct [:owner, :owner_ref, :port, :parser, output: []]

  @typedoc "An external command with an executable, arguments, and working directory."
  @type command :: {executable :: String.t(), args :: [String.t()], directory :: String.t()}

  @typedoc "Transforms command output and exit status into a discovery result."
  @type parser :: (String.t(), non_neg_integer() -> term())

  @typedoc "Worker state."
  @type t :: %__MODULE__{
          owner: pid(),
          owner_ref: reference(),
          port: port() | nil,
          parser: parser(),
          output: [binary()]
        }

  @doc "Starts an unlinked discovery worker monitored by its owner."
  @spec start(pid(), command(), parser()) :: GenServer.on_start()
  def start(owner, command, parser) when is_pid(owner) and is_function(parser, 2) do
    GenServer.start(__MODULE__, {owner, command, parser})
  end

  @doc "Cancels discovery and terminates its external process tree."
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    GenServer.cast(pid, :cancel)
  end

  @impl true
  @spec init({pid(), command(), parser()}) :: {:ok, t()} | {:stop, term()}
  def init({owner, {executable, args, directory}, parser}) do
    owner_ref = Process.monitor(owner)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:cd, String.to_charlist(directory)}
        ]
      )

    {:ok, %__MODULE__{owner: owner, owner_ref: owner_ref, port: port, parser: parser}}
  rescue
    error -> {:stop, error}
  end

  @impl true
  @spec handle_cast(term(), t()) :: {:noreply, t()} | {:stop, term(), t()}
  def handle_cast(:cancel, state), do: {:stop, :normal, state}
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()} | {:stop, term(), t()}
  def handle_info({port, {:data, data}}, %__MODULE__{port: port} = state) do
    {:noreply, %{state | output: [data | state.output]}}
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    output = state.output |> Enum.reverse() |> IO.iodata_to_binary()
    result = state.parser.(output, status)
    send(state.owner, {:file_find_done, self(), result})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, owner, _reason},
        %__MODULE__{owner: owner, owner_ref: ref} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), t()) :: :ok
  def terminate(_reason, %__MODULE__{port: nil}), do: :ok

  def terminate(_reason, %__MODULE__{port: port}) do
    terminate_process_tree(port)
    :ok
  end

  @spec terminate_process_tree(port()) :: :ok
  defp terminate_process_tree(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> terminate_os_processes([os_pid | descendant_pids(os_pid)])
      nil -> :ok
    end

    close_port(port)
  end

  @spec descendant_pids(pos_integer()) :: [pos_integer()]
  defp descendant_pids(root_pid) do
    case System.find_executable("ps") do
      nil -> []
      ps -> descendants_from_ps(ps, root_pid)
    end
  end

  @spec descendants_from_ps(String.t(), pos_integer()) :: [pos_integer()]
  defp descendants_from_ps(ps, root_pid) do
    case System.cmd(ps, ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} -> output |> parse_process_table() |> collect_descendants([root_pid], [])
      {_output, _status} -> []
    end
  end

  @spec parse_process_table(String.t()) :: %{pos_integer() => [pos_integer()]}
  defp parse_process_table(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, &add_process_row/2)
  end

  @spec add_process_row(String.t(), %{pos_integer() => [pos_integer()]}) ::
          %{pos_integer() => [pos_integer()]}
  defp add_process_row(row, table) do
    case String.split(row, ~r/\s+/, trim: true) do
      [pid, parent_pid] ->
        Map.update(
          table,
          String.to_integer(parent_pid),
          [String.to_integer(pid)],
          &[String.to_integer(pid) | &1]
        )

      _other ->
        table
    end
  end

  @spec collect_descendants(%{pos_integer() => [pos_integer()]}, [pos_integer()], [pos_integer()]) ::
          [pos_integer()]
  defp collect_descendants(_table, [], descendants), do: descendants

  defp collect_descendants(table, [parent | pending], descendants) do
    children = Map.get(table, parent, [])
    collect_descendants(table, children ++ pending, children ++ descendants)
  end

  @spec terminate_os_processes([pos_integer(), ...]) :: :ok
  defp terminate_os_processes(pids) do
    signal_processes("-TERM", pids)
    signal_processes("-KILL", pids)
  end

  @spec signal_processes(String.t(), [pos_integer()]) :: :ok
  defp signal_processes(signal, pids) do
    case System.find_executable("kill") do
      nil -> :ok
      kill -> run_kill(kill, signal, pids)
    end
  end

  @spec run_kill(String.t(), String.t(), [pos_integer()]) :: :ok
  defp run_kill(kill, signal, pids) do
    args = [signal | Enum.map(pids, &Integer.to_string/1)]
    _result = System.cmd(kill, args, stderr_to_stdout: true)
    :ok
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end
end
