defmodule Minga.Project.FileFind.Worker do
  @moduledoc """
  Owns one external project-file discovery process.

  The worker monitors its requester and terminates the external process tree when cancelled or when the requester exits. Port output is accumulated asynchronously with byte and file-count bounds so project discovery cannot exhaust the VM.
  """

  use GenServer

  @cancel_timeout_ms 5_000
  @default_max_output_bytes 16 * 1024 * 1024
  @default_max_file_count 1_000_000

  @enforce_keys [:owner, :owner_ref, :port, :parser]
  defstruct [
    :owner,
    :owner_ref,
    :port,
    :parser,
    output: [],
    output_bytes: 0,
    file_count: 0,
    max_output_bytes: @default_max_output_bytes,
    max_file_count: @default_max_file_count
  ]

  @typedoc "An external command with an executable, arguments, and working directory."
  @type command :: {executable :: String.t(), args :: [String.t()], directory :: String.t()}

  @typedoc "Transforms command output and exit status into a discovery result."
  @type parser :: (String.t(), non_neg_integer() -> term())

  @typedoc "Worker options."
  @type option :: {:max_output_bytes, pos_integer()} | {:max_file_count, pos_integer()}

  @typedoc "Worker state."
  @type t :: %__MODULE__{
          owner: pid(),
          owner_ref: reference(),
          port: port() | nil,
          parser: parser(),
          output: [binary()],
          output_bytes: non_neg_integer(),
          file_count: non_neg_integer(),
          max_output_bytes: pos_integer(),
          max_file_count: pos_integer()
        }

  @typedoc "Cancellation result."
  @type cancel_result :: :ok | {:error, String.t()}

  @doc "Starts an unlinked discovery worker monitored by its owner."
  @spec start(pid(), command(), parser(), [option()]) :: GenServer.on_start()
  def start(owner, command, parser, opts \\ [])
      when is_pid(owner) and is_function(parser, 2) and is_list(opts) do
    GenServer.start(__MODULE__, {owner, command, parser, opts})
  end

  @doc "Cancels discovery and waits for its external process tree to terminate."
  @spec cancel(pid()) :: cancel_result()
  def cancel(pid) when is_pid(pid) do
    GenServer.call(pid, :cancel, @cancel_timeout_ms)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:normal, _call} -> :ok
    :exit, reason -> {:error, "Discovery cancellation failed: #{inspect(reason)}"}
  end

  @impl true
  @spec init({pid(), command(), parser(), [option()]}) :: {:ok, t()} | {:stop, term()}
  def init({owner, {executable, args, directory}, parser, opts}) do
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

    {:ok,
     %__MODULE__{
       owner: owner,
       owner_ref: owner_ref,
       port: port,
       parser: parser,
       max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes),
       max_file_count: Keyword.get(opts, :max_file_count, @default_max_file_count)
     }}
  rescue
    error -> {:stop, error}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), t()) ::
          {:reply, term(), t()} | {:stop, term(), term(), t()}
  def handle_call(:cancel, _from, state) do
    {result, state} = stop_external_process(state)
    {:stop, :normal, result, state}
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :unsupported}, state}

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()} | {:stop, term(), t()}
  def handle_info({port, {:data, data}}, %__MODULE__{port: port} = state) do
    output_bytes = state.output_bytes + byte_size(data)
    file_count = state.file_count + newline_count(data)

    handle_output_chunk(state, data, output_bytes, file_count)
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
  def terminate(_reason, state) do
    {result, _state} = stop_external_process(state)
    log_termination_error(result)
  end

  @spec handle_output_chunk(t(), binary(), non_neg_integer(), non_neg_integer()) ::
          {:noreply, t()} | {:stop, :normal, t()}
  defp handle_output_chunk(state, _data, output_bytes, _file_count)
       when output_bytes > state.max_output_bytes do
    stop_for_limit(state, "byte")
  end

  defp handle_output_chunk(state, _data, _output_bytes, file_count)
       when file_count > state.max_file_count do
    stop_for_limit(state, "file-count")
  end

  defp handle_output_chunk(state, data, output_bytes, file_count) do
    {:noreply,
     %{
       state
       | output: [data | state.output],
         output_bytes: output_bytes,
         file_count: file_count
     }}
  end

  @spec stop_for_limit(t(), String.t()) :: {:stop, :normal, t()}
  defp stop_for_limit(state, limit_name) do
    send(
      state.owner,
      {:file_find_done, self(),
       {:error, "Project file discovery exceeded the #{limit_name} limit"}}
    )

    {:stop, :normal, state}
  end

  @spec newline_count(binary()) :: non_neg_integer()
  defp newline_count(data), do: length(:binary.matches(data, "\n"))

  @spec stop_external_process(t()) :: {cancel_result(), t()}
  defp stop_external_process(%__MODULE__{port: nil} = state), do: {:ok, state}

  defp stop_external_process(%__MODULE__{port: port} = state) do
    result = terminate_process_tree(port)
    {result, %{state | port: nil}}
  end

  @spec terminate_process_tree(port()) :: cancel_result()
  defp terminate_process_tree(port) do
    result =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> terminate_os_processes(os_pid)
        nil -> :ok
      end

    close_port(port)
    result
  end

  @spec terminate_os_processes(pos_integer()) :: cancel_result()
  defp terminate_os_processes(root_pid) do
    with {:ok, descendants} <- descendant_pids(root_pid),
         pids = [root_pid | descendants],
         :ok <- signal_processes("-TERM", pids) do
      signal_processes("-KILL", pids)
    end
  end

  @spec descendant_pids(pos_integer()) :: {:ok, [pos_integer()]} | {:error, String.t()}
  defp descendant_pids(root_pid) do
    case System.find_executable("ps") do
      nil -> {:error, "Cannot inspect discovery descendants: ps not found"}
      ps -> descendants_from_ps(ps, root_pid)
    end
  end

  @spec descendants_from_ps(String.t(), pos_integer()) ::
          {:ok, [pos_integer()]} | {:error, String.t()}
  defp descendants_from_ps(ps, root_pid) do
    case System.cmd(ps, ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        descendants = output |> parse_process_table() |> collect_descendants([root_pid], [])
        {:ok, descendants}

      {output, status} ->
        {:error,
         "Cannot inspect discovery descendants (ps status #{status}): #{String.trim(output)}"}
    end
  rescue
    error -> {:error, "Cannot inspect discovery descendants: #{Exception.message(error)}"}
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

  @spec signal_processes(String.t(), [pos_integer()]) :: cancel_result()
  defp signal_processes(signal, pids) do
    case System.find_executable("kill") do
      nil -> {:error, "Cannot signal discovery processes: kill not found"}
      kill -> run_kill(kill, signal, pids)
    end
  end

  @spec run_kill(String.t(), String.t(), [pos_integer()]) :: cancel_result()
  defp run_kill(kill, signal, pids) do
    args = [signal | Enum.map(pids, &Integer.to_string/1)]

    case System.cmd(kill, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> normalize_kill_failure(signal, status, output)
    end
  rescue
    error ->
      {:error, "Failed to signal discovery processes with #{signal}: #{Exception.message(error)}"}
  end

  @spec normalize_kill_failure(String.t(), non_neg_integer(), String.t()) :: cancel_result()
  defp normalize_kill_failure(signal, status, output) do
    errors = String.split(output, "\n", trim: true)

    normalize_kill_errors(
      Enum.all?(errors, &no_such_process?/1) and errors != [],
      signal,
      status,
      output
    )
  end

  @spec normalize_kill_errors(boolean(), String.t(), non_neg_integer(), String.t()) ::
          cancel_result()
  defp normalize_kill_errors(true, _signal, _status, _output), do: :ok

  defp normalize_kill_errors(false, signal, status, output) do
    {:error,
     "Failed to signal discovery processes with #{signal} (status #{status}): #{String.trim(output)}"}
  end

  @spec no_such_process?(String.t()) :: boolean()
  defp no_such_process?(line), do: String.contains?(String.downcase(line), "no such process")

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @spec log_termination_error(cancel_result()) :: :ok
  defp log_termination_error(:ok), do: :ok

  defp log_termination_error({:error, reason}) do
    Minga.Log.error(:editor, reason)
    :ok
  end
end
