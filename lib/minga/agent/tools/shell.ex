defmodule Minga.Agent.Tools.Shell do
  @moduledoc """
  Runs a shell command in the project root directory.

  Commands execute via `System.cmd/3` with a configurable timeout.
  Stdout and stderr are merged into a single output string. The exit code
  is included in the result so the caller knows if the command succeeded.
  """

  @doc """
  Runs `command` in the given `cwd` with a `timeout_secs` limit.

  The command is passed to `/bin/sh -c` for shell expansion (pipes, globs, etc.).
  Returns `{:ok, output}` with the combined stdout/stderr and exit code.
  """
  @spec execute(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(command, cwd, timeout_secs)
      when is_binary(command) and is_binary(cwd) and is_integer(timeout_secs) do
    timeout_ms = timeout_secs * 1_000

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command],
          cd: cwd,
          stderr_to_stdout: true,
          env: safe_env()
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        result =
          if exit_code == 0 do
            output
          else
            "#{output}\n[exit code: #{exit_code}]"
          end

        {:ok, String.trim_trailing(result)}

      nil ->
        {:error, "command timed out after #{timeout_secs}s: #{command}"}
    end
  rescue
    e ->
      {:error, "command failed: #{Exception.message(e)}"}
  end

  # Pass through the user's environment minus anything that could cause trouble
  # with interactive prompts or pagers.
  @spec safe_env() :: [{String.t(), String.t()}]
  defp safe_env do
    [
      {"PAGER", "cat"},
      {"GIT_PAGER", "cat"},
      {"TERM", "dumb"}
    ]
  end
end
