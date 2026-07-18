defmodule Minga.Extension.DisposableBeam do
  @moduledoc false

  alias Minga.Extension.ArtifactValidator
  alias Minga.Extension.IsolatedCompiler
  alias Minga.Extension.SecureFile

  @max_request_bytes 256 * 1024
  @max_output_bytes 64 * 1024
  @line_bytes 1_024
  @startup_attempts 2

  @type mode :: :compiler | :validator
  @type run_error ::
          :executable_unavailable
          | :output_limit_exceeded
          | :request_too_large
          | :timeout
          | {:exit_status, non_neg_integer()}
          | {:port_failed, term()}
          | {:request_write_failed, term()}

  @doc "Runs one allowlisted worker in a standalone disposable BEAM OS process."
  @spec run(mode(), map(), String.t(), timeout()) :: :ok | {:error, run_error()}
  def run(mode, request, request_parent, timeout)
      when mode in [:compiler, :validator] and is_map(request) and is_binary(request_parent) and
             is_integer(timeout) and timeout > 0 do
    request_path = Path.join(request_parent, ".beam-request-#{unique_suffix()}.json")
    binary = JSON.encode!(request)

    result =
      with :ok <- request_size(binary),
           :ok <- write_request(request_path, binary),
           {:ok, executable} <- executable() do
        run_port(executable, mode, request_path, timeout, @startup_attempts)
      end

    File.rm(request_path)
    result
  end

  @doc false
  @spec main() :: no_return()
  def main do
    status =
      case :init.get_plain_arguments() do
        [mode, request_path] -> run_worker(to_string(mode), to_string(request_path))
        _other -> 64
      end

    :erlang.halt(status)
  end

  @spec run_worker(String.t(), String.t()) :: non_neg_integer()
  defp run_worker(mode, request_path) do
    with {:ok, binary} <- SecureFile.read(request_path, @max_request_bytes),
         {:ok, request} when is_map(request) <- JSON.decode(binary),
         :ok <- dispatch(mode, request) do
      0
    else
      _other -> 65
    end
  rescue
    _error -> 70
  catch
    _kind, _reason -> 70
  end

  @spec dispatch(String.t(), map()) :: :ok
  defp dispatch("compiler", request), do: IsolatedCompiler.run_disposable(request)
  defp dispatch("validator", request), do: ArtifactValidator.run_disposable(request)
  defp dispatch(_mode, _request), do: :invalid_mode

  @spec request_size(binary()) :: :ok | {:error, :request_too_large}
  defp request_size(binary) when byte_size(binary) <= @max_request_bytes, do: :ok
  defp request_size(_binary), do: {:error, :request_too_large}

  @spec write_request(String.t(), binary()) :: :ok | {:error, run_error()}
  defp write_request(path, binary) do
    case File.write(path, binary, [:binary, :exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_write_failed, reason}}
    end
  end

  @spec executable() :: {:ok, String.t()} | {:error, :executable_unavailable}
  defp executable do
    case System.find_executable("erl") do
      nil -> {:error, :executable_unavailable}
      path -> {:ok, path}
    end
  end

  @spec open_port(String.t(), mode(), String.t()) ::
          {:ok, port()} | {:error, {:port_failed, term()}}
  defp open_port(executable, mode, request_path) do
    arguments = beam_arguments(mode, request_path)

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          {:line, @line_bytes},
          {:args, arguments}
        ]
      )

    {:ok, port}
  rescue
    error -> {:error, {:port_failed, Exception.message(error)}}
  end

  @spec run_port(String.t(), mode(), String.t(), timeout(), pos_integer()) ::
          :ok | {:error, run_error()}
  defp run_port(executable, mode, request_path, timeout, attempts) do
    with {:ok, port} <- open_port(executable, mode, request_path) do
      case await_exit(port, timeout, 0) do
        {:error, {:exit_status, _status}} when attempts > 1 ->
          safe_close(port)
          flush_port(port)
          run_port(executable, mode, request_path, timeout, attempts - 1)

        result ->
          result
      end
    end
  end

  @spec beam_arguments(mode(), String.t()) :: [String.t()]
  defp beam_arguments(mode, request_path) do
    code_paths =
      :code.get_path()
      |> Enum.map(&(&1 |> to_string() |> Path.expand()))
      |> Enum.uniq()
      |> Enum.flat_map(&["-pa", &1])

    ["+S", "2:2", "+A", "1", "-noshell", "-noinput"] ++
      code_paths ++
      [
        "-eval",
        "'Elixir.Minga.Extension.DisposableBeam':main().",
        "-extra",
        Atom.to_string(mode),
        request_path
      ]
  end

  @spec await_exit(port(), timeout(), non_neg_integer()) :: :ok | {:error, run_error()}
  defp await_exit(port, timeout, output_bytes) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_port(port, deadline, output_bytes)
  end

  @spec await_port(port(), integer(), non_neg_integer()) :: :ok | {:error, run_error()}
  defp await_port(port, deadline, output_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        next = output_bytes + output_size(data)
        continue_after_output(port, deadline, next)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}

      {^port, :eof} ->
        await_port(port, deadline, output_bytes)

      {:EXIT, ^port, reason} ->
        {:error, {:port_failed, reason}}
    after
      remaining ->
        kill(port)
        {:error, :timeout}
    end
  end

  @spec continue_after_output(port(), integer(), non_neg_integer()) ::
          :ok | {:error, run_error()}
  defp continue_after_output(port, _deadline, output_bytes)
       when output_bytes > @max_output_bytes do
    kill(port)
    {:error, :output_limit_exceeded}
  end

  defp continue_after_output(port, deadline, output_bytes),
    do: await_port(port, deadline, output_bytes)

  @spec output_size(binary() | {:eol | :noeol, binary()}) :: non_neg_integer()
  defp output_size(binary) when is_binary(binary), do: byte_size(binary)
  defp output_size({_line_status, binary}), do: byte_size(binary)

  @spec kill(port()) :: :ok
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> kill_os_pid(pid)
      nil -> :ok
    end

    safe_close(port)
    flush_port(port)
  end

  @spec safe_close(port()) :: :ok
  defp safe_close(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  @spec kill_os_pid(non_neg_integer()) :: :ok
  defp kill_os_pid(pid) do
    case System.find_executable("kill") do
      nil ->
        :ok

      executable ->
        _ = System.cmd(executable, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        :ok
    end
  rescue
    _error -> :ok
  end

  @spec flush_port(port()) :: :ok
  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
      {:EXIT, ^port, _reason} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  @spec unique_suffix() :: String.t()
  defp unique_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
