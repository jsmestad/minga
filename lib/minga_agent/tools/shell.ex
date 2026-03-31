defmodule MingaAgent.Tools.Shell do
  @moduledoc """
  Runs a shell command in the project root directory.

  Commands execute via a BEAM Port for incremental output streaming.
  When an `on_output` callback is provided, output is debounced and
  flushed at most every 200ms to avoid flooding the UI. If the command
  produces no output for 3 seconds, a "running..." indicator is sent.
  Stdout and stderr are merged. The exit code is included in the result
  so the caller knows if the command succeeded.
  """

  @typedoc "Options for shell execution."
  @type execute_opts :: [
          on_output: (String.t() -> :ok),
          running_indicator_ms: pos_integer()
        ]

  @debounce_ms 200
  @running_indicator_ms 3_000

  @doc """
  Runs `command` in the given `cwd` with a `timeout_secs` limit.

  The command is passed to `/bin/sh -c` for shell expansion (pipes, globs, etc.).
  Returns `{:ok, output}` with the combined stdout/stderr and exit code.

  Options:
    - `:on_output` — callback function invoked with batched output chunks.
      Debounced to at most one call every #{@debounce_ms}ms. If the command
      produces no output for #{@running_indicator_ms}ms, a "running..."
      indicator is sent.
    - `:running_indicator_ms` — override the silence threshold before sending
      a "running..." indicator (default: #{@running_indicator_ms})
  """
  @spec execute(String.t(), String.t(), pos_integer(), execute_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(command, cwd, timeout_secs, opts \\ [])
      when is_binary(command) and is_binary(cwd) and is_integer(timeout_secs) do
    on_output = Keyword.get(opts, :on_output)
    indicator_ms = Keyword.get(opts, :running_indicator_ms, @running_indicator_ms)
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
    now = System.monotonic_time(:millisecond)

    collect_output(port, deadline, on_output, indicator_ms, [], [], now, now)
  rescue
    e ->
      {:error, "command failed: #{Exception.message(e)}"}
  end

  # Collect output from the Port until it exits or times out.
  # `pending` accumulates chunks between flushes. `last_flush` tracks
  # when we last called on_output. `last_data` tracks when we last
  # received any data (for the "running..." indicator).
  @spec collect_output(
          port(),
          integer(),
          (String.t() -> :ok) | nil,
          pos_integer(),
          [String.t()],
          [String.t()],
          integer(),
          integer()
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp collect_output(
         port,
         deadline,
         on_output,
         indicator_ms,
         acc,
         pending,
         last_flush,
         last_data
       ) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    # Wake up at the sooner of: deadline, next debounce window, or running indicator
    wait_ms = min(remaining, @debounce_ms)

    receive do
      {^port, {:data, data}} ->
        now = System.monotonic_time(:millisecond)
        new_pending = [data | pending]

        if on_output != nil and now - last_flush >= @debounce_ms do
          flush_pending(on_output, new_pending)
          collect_output(port, deadline, on_output, indicator_ms, [data | acc], [], now, now)
        else
          collect_output(
            port,
            deadline,
            on_output,
            indicator_ms,
            [data | acc],
            new_pending,
            last_flush,
            now
          )
        end

      {^port, {:exit_status, exit_code}} ->
        # Flush any remaining pending output
        if on_output != nil and pending != [], do: flush_pending(on_output, pending)

        output = acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim_trailing()

        result =
          if exit_code == 0 do
            output
          else
            "#{output}\n[exit code: #{exit_code}]"
          end

        {:ok, result}
    after
      wait_ms ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          # Flush before timing out
          if on_output != nil and pending != [], do: flush_pending(on_output, pending)
          Port.close(port)
          elapsed_s = div(now - (deadline - remaining), 1_000)
          {:error, "command timed out after #{elapsed_s}s"}
        else
          # Check if we should flush pending output or send a running indicator
          {new_pending, new_flush, new_data} =
            maybe_flush_or_indicate(on_output, pending, last_flush, last_data, now, indicator_ms)

          collect_output(
            port,
            deadline,
            on_output,
            indicator_ms,
            acc,
            new_pending,
            new_flush,
            new_data
          )
        end
    end
  end

  @spec maybe_flush_or_indicate(
          (String.t() -> :ok) | nil,
          [String.t()],
          integer(),
          integer(),
          integer(),
          pos_integer()
        ) :: {[String.t()], integer(), integer()}
  defp maybe_flush_or_indicate(nil, pending, last_flush, last_data, _now, _indicator_ms) do
    {pending, last_flush, last_data}
  end

  defp maybe_flush_or_indicate(on_output, pending, last_flush, last_data, now, indicator_ms) do
    if pending != [] and now - last_flush >= @debounce_ms do
      # Flush accumulated output
      flush_pending(on_output, pending)
      {[], now, last_data}
    else
      if pending == [] and now - last_data >= indicator_ms do
        # No output for a while, send a running indicator
        on_output.("[running...]\n")
        {[], now, now}
      else
        {pending, last_flush, last_data}
      end
    end
  end

  @spec flush_pending((String.t() -> :ok), [String.t()]) :: :ok
  defp flush_pending(on_output, pending) do
    batch = pending |> Enum.reverse() |> IO.iodata_to_binary()
    on_output.(batch)
    :ok
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
