defmodule MingaAgent.Hooks.CommandRunner do
  @moduledoc """
  Executes shell-backed agent hooks.

  Commands run through `/bin/sh -c`. The hook payload is JSON on standard
  input, stdout is ignored, stderr is captured for veto messages, and each
  hook has an independent timeout.
  """

  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  @payload_dir_attempts 5
  @pgrep_paths ~w(/usr/bin/pgrep /bin/pgrep)
  @kill_paths ~w(/bin/kill /usr/bin/kill)

  @doc "Runs a `PreToolUse` shell hook for a payload."
  @spec run_pre_tool_use(Hook.t(), PreToolUsePayload.t()) :: Result.t()
  def run_pre_tool_use(%Hook{} = hook, %PreToolUsePayload{} = payload) do
    with {:ok, payload_json} <- encode_payload(payload),
         {:ok, payload_path} <- write_payload(payload_json) do
      try do
        run_shell(hook, payload_path)
      after
        cleanup_payload(payload_path)
      end
    else
      {:error, reason} -> payload_preparation_veto(hook, reason)
    end
  end

  @spec encode_payload(PreToolUsePayload.t()) :: {:ok, String.t()} | {:error, term()}
  defp encode_payload(%PreToolUsePayload{} = payload) do
    case Jason.encode(PreToolUsePayload.to_map(payload)) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, safe_encode_reason(reason)}
    end
  rescue
    e -> {:error, safe_encode_reason(e)}
  catch
    kind, _reason -> {:error, {:encode_failed, kind}}
  end

  @spec payload_preparation_veto(Hook.t(), term()) :: Result.t()
  defp payload_preparation_veto(hook, reason) do
    Result.veto(
      hook,
      "failed to prepare hook payload: #{format_prepare_reason(reason)}",
      {:failed_to_start, reason}
    )
  end

  @spec safe_encode_reason(Exception.t()) :: {:encode_failed, module()}
  defp safe_encode_reason(%Protocol.UndefinedError{protocol: protocol}) do
    {:encode_failed, protocol}
  end

  defp safe_encode_reason(%{__struct__: module}) when is_atom(module) do
    {:encode_failed, module}
  end

  @spec format_prepare_reason(term()) :: String.t()
  defp format_prepare_reason({:encode_failed, reason}) do
    "could not JSON encode payload with #{inspect(reason)}"
  end

  defp format_prepare_reason(reason), do: inspect(reason)

  @spec write_payload(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp write_payload(payload_json) do
    case create_payload_dir() do
      {:ok, dir} -> write_payload_file(dir, payload_json)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_payload_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp write_payload_file(dir, payload_json) do
    path = Path.join(dir, "payload.json")

    case write_private_file(path, payload_json) do
      :ok -> {:ok, path}
      {:error, reason} -> cleanup_failed_payload(path, dir, reason)
    end
  end

  @spec write_private_file(String.t(), String.t()) :: :ok | {:error, term()}
  defp write_private_file(path, payload_json) do
    case File.write(path, payload_json, [:binary]) do
      :ok -> File.chmod(path, 0o600)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_payload_dir(non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  defp create_payload_dir(attempts \\ @payload_dir_attempts)

  defp create_payload_dir(0), do: {:error, :payload_dir_collision}

  defp create_payload_dir(attempts) do
    dir = Path.join(System.tmp_dir!(), "minga-hook-#{random_suffix()}")

    case File.mkdir(dir) do
      :ok -> chmod_payload_dir(dir)
      {:error, :eexist} -> create_payload_dir(attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec chmod_payload_dir(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp chmod_payload_dir(dir) do
    case File.chmod(dir, 0o700) do
      :ok ->
        {:ok, dir}

      {:error, reason} ->
        File.rmdir(dir)
        {:error, reason}
    end
  end

  @spec random_suffix() :: String.t()
  defp random_suffix do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec cleanup_payload(String.t()) :: :ok
  defp cleanup_payload(path) do
    File.rm(path)
    File.rmdir(Path.dirname(path))
    :ok
  end

  @spec cleanup_failed_payload(String.t(), String.t(), term()) :: {:error, term()}
  defp cleanup_failed_payload(path, dir, reason) do
    File.rm(path)
    File.rmdir(dir)
    {:error, reason}
  end

  @spec run_shell(Hook.t(), String.t()) :: Result.t()
  defp run_shell(%Hook{} = hook, payload_path) do
    wrapper = "exec < #{shell_quote(payload_path)}; exec 1>/dev/null; #{hook.command}"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", wrapper]
      ])

    deadline = System.monotonic_time(:millisecond) + hook.timeout_ms
    collect_until(port, hook, "", deadline)
  rescue
    e ->
      Result.veto(
        hook,
        "failed to start hook command: #{Exception.message(e)}",
        {:failed_to_start, e}
      )
  catch
    kind, reason ->
      Result.veto(
        hook,
        "failed to start hook command: #{inspect(kind)} #{inspect(reason)}",
        {:failed_to_start, {kind, reason}}
      )
  end

  @spec collect_until(port(), Hook.t(), String.t(), integer()) :: Result.t()
  defp collect_until(port, hook, stderr, deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      timeout(hook, port)
    else
      receive do
        {^port, {:data, data}} ->
          collect_until(port, hook, stderr <> data, deadline_ms)

        {^port, {:exit_status, 0}} ->
          Result.allow(hook)

        {^port, {:exit_status, status}} ->
          Result.veto(hook, stderr, {:exit, status})
      after
        remaining_ms ->
          timeout(hook, port)
      end
    end
  end

  @spec timeout(Hook.t(), port()) :: Result.t()
  defp timeout(hook, port) do
    kill_port_process_tree(port)
    close_port(port)
    message = "PreToolUse hook timed out after #{hook.timeout_ms}ms and was killed"
    Result.veto(hook, message, :timeout)
  end

  @spec kill_port_process_tree(port()) :: :ok
  defp kill_port_process_tree(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> kill_process_tree(pid)
      _other -> :ok
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  @spec kill_process_tree(non_neg_integer()) :: :ok
  defp kill_process_tree(pid) do
    pid
    |> child_pids()
    |> Enum.each(&kill_process_tree/1)

    kill_pid(pid)
  end

  @spec child_pids(non_neg_integer()) :: [non_neg_integer()]
  defp child_pids(pid) do
    case executable_path(@pgrep_paths) do
      nil ->
        []

      pgrep ->
        case System.cmd(pgrep, ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
          {output, 0} -> parse_pids(output)
          {_output, _status} -> []
        end
    end
  rescue
    ErlangError -> []
  end

  @spec parse_pids(String.t()) :: [non_neg_integer()]
  defp parse_pids(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_pid/1)
  end

  @spec parse_pid(String.t()) :: [non_neg_integer()]
  defp parse_pid(raw) do
    case Integer.parse(String.trim(raw)) do
      {pid, ""} when pid >= 0 -> [pid]
      _other -> []
    end
  end

  @spec kill_pid(non_neg_integer()) :: :ok
  defp kill_pid(pid) do
    case executable_path(@kill_paths) do
      nil -> :ok
      kill -> System.cmd(kill, ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    ErlangError -> :ok
  end

  @spec executable_path([String.t()]) :: String.t() | nil
  defp executable_path(paths) do
    Enum.find(paths, &File.regular?/1)
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  @spec shell_quote(String.t()) :: String.t()
  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
