defmodule Minga.Agent.Tools.Shell do
  @moduledoc """
  Runs a shell command in the project root directory.

  Commands execute via a BEAM Port for incremental output streaming.
  When a `on_output` callback is provided, output is streamed in chunks
  as it arrives (debounced to avoid flooding). Stdout and stderr are
  merged. The exit code is included in the result so the caller knows
  if the command succeeded.
  """

  @typedoc "Options for shell execution."
  @type execute_opts :: [on_output: (String.t() -> :ok)]

  @doc """
  Runs `command` in the given `cwd` with a `timeout_secs` limit.

  The command is passed to `/bin/sh -c` for shell expansion (pipes, globs, etc.).
  Returns `{:ok, output}` with the combined stdout/stderr and exit code.

  Options:
    - `:on_output` — callback function invoked with each chunk of output as
      it arrives. Used for streaming output to the UI in real time.
  """
  @spec execute(String.t(), String.t(), pos_integer(), execute_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(command, cwd, timeout_secs, opts \\ [])
      when is_binary(command) and is_binary(cwd) and is_integer(timeout_secs) do
    on_output = Keyword.get(opts, :on_output)
    timeout_ms = timeout_secs * 1_000

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-c", command],
          cd: cwd,
          env: safe_env_charlist()
        ]
      )

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_output(port, deadline, on_output, [])
  rescue
    e ->
      {:error, "command failed: #{Exception.message(e)}"}
  end

  # Collect output from the Port until it exits or times out.
  @spec collect_output(port(), integer(), (String.t() -> :ok) | nil, [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp collect_output(port, deadline, on_output, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if on_output, do: on_output.(data)
        collect_output(port, deadline, on_output, [data | acc])

      {^port, {:exit_status, exit_code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim_trailing()

        result =
          if exit_code == 0 do
            output
          else
            "#{output}\n[exit code: #{exit_code}]"
          end

        {:ok, result}
    after
      remaining ->
        Port.close(port)

        {:error,
         "command timed out after #{div(deadline - System.monotonic_time(:millisecond) + remaining, 1_000)}s"}
    end
  end

  # Port env requires charlist tuples, not string tuples.
  @spec safe_env_charlist() :: [{charlist(), charlist()}]
  defp safe_env_charlist do
    [
      {~c"PAGER", ~c"cat"},
      {~c"GIT_PAGER", ~c"cat"},
      {~c"TERM", ~c"dumb"}
    ]
  end
end
