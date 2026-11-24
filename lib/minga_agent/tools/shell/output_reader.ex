defmodule MingaAgent.Tools.Shell.OutputReader do
  @moduledoc """
  Demand-driven transport for retained shell output.

  A native companion reads a private FIFO only after one request. The original
  producer Port keeps its PID, cwd, environment and exit-status ownership. While
  ArtifactStore admits an append, no further read is requested, so a fast
  producer is backpressured by the finite FIFO rather than the BEAM mailbox.
  """

  alias MingaAgent.Tools.Shell.Operation

  @helper_name "minga-shell-output-reader"
  @bootstrap ~S(exec 3>&1; exec >"$1" 2>&1 || exit 125; printf '\001' >&3; exec 3>&-; exec "$2" -c "$3")
  @max_data_bytes 65_536
  @max_error_bytes 1_024

  @opaque t :: %__MODULE__{
            helper: port(),
            producer: port(),
            outstanding?: boolean(),
            eof?: boolean(),
            exit_status: non_neg_integer() | nil
          }
  @type next_result ::
          {:data, binary(), t()}
          | {:exit_status, non_neg_integer(), t()}
          | {:wait, t()}
          | {:error, term(), t()}
  @type env :: [{charlist(), charlist()}]

  @enforce_keys [:helper, :producer]
  defstruct [:helper, :producer, :exit_status, outstanding?: false, eof?: false]

  @doc "Starts the companion and validates bootstrap within the existing absolute deadline."
  @spec open(String.t(), String.t(), env(), integer(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def open(command, cwd, env, deadline, opts \\ []) do
    path = Keyword.get(opts, :helper_path, Path.join(:code.priv_dir(:minga), @helper_name))

    with {:ok, helper} <- open_helper(path) do
      case ready(helper, deadline) do
        {:ok, fifo} ->
          open_before_deadline(helper, fifo, command, cwd, env, deadline)

        {:error, reason} ->
          close_port(helper)
          {:error, reason}
      end
    end
  end

  @spec open_before_deadline(port(), String.t(), String.t(), String.t(), env(), integer()) ::
          {:ok, t()} | {:error, term()}
  defp open_before_deadline(helper, fifo, command, cwd, env, deadline) do
    if remaining(deadline) == 0 do
      close_port(helper)
      {:error, :timeout}
    else
      open_producer(helper, fifo, command, cwd, env, deadline)
    end
  end

  @doc "Requests at most one bounded chunk, preserving an outstanding demand across idle waits."
  @spec next(t(), non_neg_integer()) :: next_result()
  def next(%__MODULE__{eof?: true, exit_status: status} = reader, _wait_ms)
      when is_integer(status) do
    close(reader)
    {:exit_status, status, reader}
  end

  def next(%__MODULE__{} = reader, wait_ms) when is_integer(wait_ms) and wait_ms >= 0 do
    case demand(reader) do
      {:ok, reader} -> receive_next(reader, System.monotonic_time(:millisecond) + wait_ms)
      {:error, reason} -> {:error, reason, reader}
    end
  end

  @doc "Cancels an unfinished producer before closing the FIFO reader."
  @spec close(t()) :: :ok
  def close(%__MODULE__{producer: producer, helper: helper, exit_status: status}) do
    close_producer(producer, status)
    close_port(helper)
  end

  # Always cancel the operation regardless of exit status. Even after the shell
  # exits, orphaned background children may remain in the process group. The
  # cancel path sends the cleanup signal to the hook runner (or is a no-op if
  # the hook runner already exited after its own group cleanup).
  @spec close_producer(port(), non_neg_integer() | nil) :: :ok
  defp close_producer(producer, _status), do: Operation.cancel(producer)

  @spec open_helper(String.t()) :: {:ok, port()} | {:error, term()}
  defp open_helper(path) do
    {:ok, Port.open({:spawn_executable, path}, [:binary, :exit_status, :hide, packet: 4])}
  rescue
    error -> {:error, {:output_reader_unavailable, Exception.message(error)}}
  end

  @spec ready(port(), integer()) :: {:ok, String.t()} | {:error, term()}
  defp ready(helper, deadline) do
    receive do
      {^helper, {:data, <<1, path::binary>>}} -> validate_path(path)
      {^helper, {:data, <<4, reason::binary>>}} -> reader_error(reason)
      {^helper, {:data, _frame}} -> {:error, :invalid_output_reader_ready}
      {^helper, {:exit_status, status}} -> {:error, {:output_reader_exit, status}}
      {:EXIT, ^helper, reason} -> {:error, {:output_reader_closed, reason}}
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  @spec validate_path(binary()) :: {:ok, String.t()} | {:error, term()}
  defp validate_path(path) when byte_size(path) > 0 and byte_size(path) <= 4_096 do
    if String.valid?(path) and :binary.match(path, <<0>>) == :nomatch and
         Path.type(path) == :absolute do
      {:ok, path}
    else
      {:error, :invalid_output_reader_path}
    end
  end

  defp validate_path(_path), do: {:error, :invalid_output_reader_path}

  @spec open_producer(port(), String.t(), String.t(), String.t(), env(), integer()) ::
          {:ok, t()} | {:error, term()}
  defp open_producer(helper, fifo, command, cwd, env, deadline) do
    case producer_port(fifo, command, cwd, env) do
      {:ok, producer} ->
        reader = %__MODULE__{helper: helper, producer: producer}

        case bootstrap(reader, deadline) do
          :ok ->
            {:ok, reader}

          {:error, reason, reader} ->
            close(reader)
            {:error, reason}
        end

      {:error, reason} ->
        close_port(helper)
        {:error, reason}
    end
  end

  @spec producer_port(String.t(), String.t(), String.t(), env()) ::
          {:ok, port()} | {:error, term()}
  defp producer_port(fifo, command, cwd, env) do
    args = [@bootstrap, "minga-shell-output", fifo, "/bin/sh", command]

    case Operation.open(args, cwd, env, [:eof]) do
      {:ok, _port} = result -> result
      {:error, message} -> {:error, {:producer_start_failed, message}}
    end
  end

  @spec bootstrap(t(), integer()) :: :ok | {:error, term(), t()}
  defp bootstrap(%__MODULE__{producer: producer, helper: helper} = reader, deadline) do
    receive do
      {^producer, {:data, <<1>>}} ->
        :ok

      {^producer, {:data, _data}} ->
        {:error, :invalid_output_bootstrap, reader}

      {^producer, :eof} ->
        {:error, :output_bootstrap_closed, reader}

      {^producer, {:exit_status, status}} ->
        {:error, {:output_bootstrap_exit, status}, %{reader | exit_status: status}}

      {^helper, {:data, <<4, reason::binary>>}} ->
        {:error, error} = reader_error(reason)
        {:error, error, reader}

      {^helper, {:data, _frame}} ->
        {:error, :unexpected_output_reader_frame, reader}

      {^helper, {:exit_status, status}} ->
        {:error, {:output_reader_exit, status}, reader}

      {:EXIT, ^helper, reason} ->
        {:error, {:output_reader_closed, reason}, reader}

      {:EXIT, ^producer, reason} ->
        {:error, {:producer_closed, reason}, reader}
    after
      remaining(deadline) -> {:error, :timeout, reader}
    end
  end

  @spec demand(t()) :: {:ok, t()} | {:error, term()}
  defp demand(%__MODULE__{eof?: true} = reader), do: {:ok, reader}
  defp demand(%__MODULE__{outstanding?: true} = reader), do: {:ok, reader}

  defp demand(%__MODULE__{helper: helper} = reader) do
    if Port.command(helper, <<5>>) do
      {:ok, %{reader | outstanding?: true}}
    else
      {:error, :output_reader_closed}
    end
  rescue
    ArgumentError -> {:error, :output_reader_closed}
  end

  @spec receive_next(t(), integer()) :: next_result()
  defp receive_next(%__MODULE__{eof?: true, exit_status: status} = reader, _deadline)
       when is_integer(status) do
    close(reader)
    {:exit_status, status, reader}
  end

  defp receive_next(%__MODULE__{helper: helper, producer: producer} = reader, deadline) do
    receive do
      {^helper, {:data, frame}} ->
        frame(reader, frame, deadline)

      {^helper, {:exit_status, 0}} when reader.eof? ->
        receive_next(reader, deadline)

      {^helper, {:exit_status, status}} ->
        {:error, {:output_reader_exit, status}, reader}

      {^producer, {:exit_status, status}} ->
        receive_next(%{reader | exit_status: status}, deadline)

      {^producer, :eof} ->
        receive_next(reader, deadline)

      {^producer, {:data, _data}} ->
        {:error, :unexpected_producer_output, reader}

      {:EXIT, ^helper, :normal} when reader.eof? ->
        receive_next(reader, deadline)

      {:EXIT, ^helper, reason} ->
        {:error, {:output_reader_closed, reason}, reader}

      {:EXIT, ^producer, :normal} ->
        receive_next(reader, deadline)

      {:EXIT, ^producer, reason} ->
        {:error, {:producer_closed, reason}, reader}
    after
      remaining(deadline) -> {:wait, reader}
    end
  end

  @spec frame(t(), binary(), integer()) :: next_result()
  defp frame(%__MODULE__{outstanding?: true} = reader, <<2, bytes::binary>>, _deadline)
       when byte_size(bytes) > 0 and byte_size(bytes) <= @max_data_bytes do
    {:data, bytes, %{reader | outstanding?: false}}
  end

  defp frame(%__MODULE__{outstanding?: true, producer: producer} = reader, <<3>>, deadline) do
    Port.command(producer, <<2>>)
    receive_next(%{reader | outstanding?: false, eof?: true}, deadline)
  rescue
    ArgumentError -> {:error, :producer_closed_before_output_eof, reader}
  end

  defp frame(reader, <<4, reason::binary>>, _deadline) do
    {:error, error} = reader_error(reason)
    {:error, error, reader}
  end

  defp frame(reader, _frame, _deadline), do: {:error, :invalid_output_reader_frame, reader}

  @spec reader_error(binary()) :: {:error, term()}
  defp reader_error(reason) when byte_size(reason) <= @max_error_bytes do
    {:error, {:output_reader_error, String.replace_invalid(reason)}}
  end

  defp reader_error(_reason), do: {:error, :invalid_output_reader_error}

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain_port(port)
  end

  @spec drain_port(port()) :: :ok
  defp drain_port(port) do
    receive do
      {^port, _message} -> drain_port(port)
      {:EXIT, ^port, _reason} -> drain_port(port)
    after
      0 -> :ok
    end
  end

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
