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

  @doc "Runs a `PreToolUse` shell hook for a payload."
  @spec run_pre_tool_use(Hook.t(), PreToolUsePayload.t()) :: Result.t()
  def run_pre_tool_use(%Hook{} = hook, %PreToolUsePayload{} = payload) do
    payload_json = Jason.encode!(PreToolUsePayload.to_map(payload))

    case write_payload(payload_json) do
      {:ok, payload_path} ->
        try do
          run_shell(hook, payload_path)
        after
          File.rm(payload_path)
        end

      {:error, reason} ->
        Result.veto(
          hook,
          "failed to prepare hook payload: #{inspect(reason)}",
          {:failed_to_start, reason}
        )
    end
  end

  @spec write_payload(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp write_payload(payload_json) do
    path = Path.join(System.tmp_dir!(), "minga-hook-#{:erlang.unique_integer([:positive])}.json")

    case File.write(path, payload_json) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
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

    collect(port, hook, "")
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

  @spec collect(port(), Hook.t(), String.t()) :: Result.t()
  defp collect(port, hook, stderr) do
    receive do
      {^port, {:data, data}} ->
        collect(port, hook, stderr <> data)

      {^port, {:exit_status, 0}} ->
        Result.allow(hook)

      {^port, {:exit_status, status}} ->
        Result.veto(hook, stderr, {:exit, status})
    after
      hook.timeout_ms ->
        close_port(port)
        message = "PreToolUse hook timed out after #{hook.timeout_ms}ms and was killed"
        Result.veto(hook, message, :timeout)
    end
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
