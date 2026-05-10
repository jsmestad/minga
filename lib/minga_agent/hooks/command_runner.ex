defmodule MingaAgent.Hooks.CommandRunner do
  @moduledoc """
  Executes shell-backed agent hooks through the `minga-hook-runner` helper.

  The helper runs `/bin/sh -c` in a dedicated POSIX process group, feeds the hook payload on stdin, discards stdout, captures bounded stderr, and enforces each hook's timeout. This module owns payload encoding and maps the helper's structured JSON result into `MingaAgent.Hooks.Result`.
  """

  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  @helper_name "minga-hook-runner"
  @guard_timeout_ms 1_000

  @typedoc "Options used by tests to inject helper behavior."
  @type run_opts :: [helper_path: String.t()]

  @doc "Runs a `PreToolUse` shell hook for a payload."
  @spec run_pre_tool_use(Hook.t(), PreToolUsePayload.t()) :: Result.t()
  def run_pre_tool_use(%Hook{} = hook, %PreToolUsePayload{} = payload) do
    run_pre_tool_use(hook, payload, [])
  end

  @doc false
  @spec run_pre_tool_use(Hook.t(), PreToolUsePayload.t(), run_opts()) :: Result.t()
  def run_pre_tool_use(%Hook{} = hook, %PreToolUsePayload{} = payload, opts) when is_list(opts) do
    with {:ok, payload_json} <- encode_payload(payload),
         {:ok, helper_path} <- helper_path(opts) do
      run_helper(hook, helper_path, payload_json)
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

  @spec helper_path(run_opts()) :: {:ok, String.t()} | {:error, term()}
  defp helper_path(opts) do
    case Keyword.get(opts, :helper_path) do
      nil -> discover_helper_path()
      path when is_binary(path) -> {:ok, path}
      other -> {:error, {:invalid_helper_path, other}}
    end
  end

  @spec discover_helper_path() :: {:ok, String.t()} | {:error, term()}
  defp discover_helper_path do
    candidates = [
      Path.join(:code.priv_dir(:minga), @helper_name),
      Path.join([File.cwd!(), "priv", @helper_name]),
      Path.join([File.cwd!(), "zig", "zig-out", "bin", @helper_name])
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> {:error, {:helper_not_found, candidates}}
      path -> {:ok, path}
    end
  end

  @spec run_helper(Hook.t(), String.t(), String.t()) :: Result.t()
  defp run_helper(%Hook{} = hook, helper_path, payload_json) do
    port =
      Port.open({:spawn_executable, helper_path}, [
        :binary,
        :exit_status,
        args: [
          Integer.to_string(hook.timeout_ms),
          Integer.to_string(byte_size(payload_json)),
          hook.command
        ]
      ])

    os_pid = port_os_pid(port)
    send_payload_to_helper(port, payload_json)
    guard_deadline_ms = System.monotonic_time(:millisecond) + hook.timeout_ms + @guard_timeout_ms
    collect_helper_result(port, hook, "", guard_deadline_ms, os_pid)
  rescue
    e ->
      Result.veto(
        hook,
        "failed to start hook runner: #{Exception.message(e)}",
        {:failed_to_start, e}
      )
  catch
    kind, reason ->
      Result.veto(
        hook,
        "failed to start hook runner: #{inspect(kind)} #{inspect(reason)}",
        {:failed_to_start, {kind, reason}}
      )
  end

  @spec send_payload_to_helper(port(), String.t()) :: :ok
  defp send_payload_to_helper(port, payload_json) do
    case Port.command(port, payload_json) do
      true -> :ok
      false -> :ok
    end
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  @spec collect_helper_result(port(), Hook.t(), String.t(), integer(), pos_integer() | nil) ::
          Result.t()
  defp collect_helper_result(port, hook, stdout, guard_deadline_ms, os_pid) do
    remaining_ms = guard_deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      helper_timeout(port, hook, os_pid)
    else
      receive do
        {^port, {:data, data}} ->
          collect_helper_result(port, hook, stdout <> data, guard_deadline_ms, os_pid)

        {^port, {:exit_status, 0}} ->
          decode_helper_result(hook, stdout)

        {^port, {:exit_status, status}} ->
          Result.veto(
            hook,
            "hook runner exited with status #{status}",
            {:failed_to_start, {:helper_exit, status}}
          )
      after
        remaining_ms -> helper_timeout(port, hook, os_pid)
      end
    end
  end

  @spec helper_timeout(port(), Hook.t(), pos_integer() | nil) :: Result.t()
  defp helper_timeout(port, hook, os_pid) do
    kill_helper_process(os_pid)
    close_port(port)

    Result.veto(
      hook,
      "hook runner timed out after #{hook.timeout_ms + @guard_timeout_ms}ms",
      {:failed_to_start, :helper_timeout}
    )
  end

  @spec port_os_pid(port()) :: pos_integer() | nil
  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _other -> nil
    end
  end

  @spec kill_helper_process(pos_integer() | nil) :: :ok
  defp kill_helper_process(nil), do: :ok

  defp kill_helper_process(pid) do
    pid_arg = Integer.to_string(pid)
    System.cmd("kill", ["-TERM", pid_arg], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", pid_arg], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  @spec decode_helper_result(Hook.t(), String.t()) :: Result.t()
  defp decode_helper_result(hook, stdout) do
    case Jason.decode(stdout) do
      {:ok, %{"status" => "allow"}} ->
        Result.allow(hook)

      {:ok, %{"status" => "veto", "reason" => %{"type" => "exit", "status" => status}} = result}
      when is_integer(status) and status >= 0 ->
        Result.veto(hook, result_stderr(result), {:exit, status})

      {:ok, %{"status" => "veto", "reason" => %{"type" => "timeout"}} = result} ->
        Result.veto(hook, timeout_stderr(hook, result_stderr(result)), :timeout)

      {:ok, %{"status" => "error", "message" => message}} when is_binary(message) ->
        Result.veto(hook, "hook runner failed: #{message}", {:failed_to_start, :helper_error})

      {:ok, _other} ->
        malformed_result(hook)

      {:error, _reason} ->
        malformed_result(hook)
    end
  end

  @spec result_stderr(map()) :: String.t()
  defp result_stderr(%{"stderr" => stderr}) when is_binary(stderr), do: stderr
  defp result_stderr(_result), do: ""

  @spec timeout_stderr(Hook.t(), String.t()) :: String.t()
  defp timeout_stderr(hook, stderr) do
    message = "PreToolUse hook timed out after #{hook.timeout_ms}ms and was killed"

    case String.trim(stderr) do
      "" -> message
      _non_empty -> stderr <> "\n" <> message
    end
  end

  @spec malformed_result(Hook.t()) :: Result.t()
  defp malformed_result(hook) do
    Result.veto(
      hook,
      "malformed hook runner result",
      {:failed_to_start, :malformed_helper_result}
    )
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
end
