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
          running_indicator_ms: pos_integer(),
          env: [{String.t(), String.t()}]
        ]

  alias MingaAgent.Tools.OutputLimit

  @debounce_ms 200
  @running_indicator_ms 3_000
  @max_output_bytes OutputLimit.default_max_bytes()

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
    - `:env` — additional environment variables to include in the command process.
  """
  @spec execute(String.t(), String.t(), pos_integer(), execute_opts()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(command, cwd, timeout_secs, opts \\ [])
      when is_binary(command) and is_binary(cwd) and is_integer(timeout_secs) do
    on_output = Keyword.get(opts, :on_output)
    indicator_ms = Keyword.get(opts, :running_indicator_ms, @running_indicator_ms)
    timeout_ms = timeout_secs * 1_000
    env = Keyword.get(opts, :env, [])

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-c", command],
          cd: cwd,
          env: safe_env_charlist(env)
        ]
      )

    now = System.monotonic_time(:millisecond)
    deadline = now + timeout_ms

    collect_output(port, %{
      deadline: deadline,
      on_output: on_output,
      indicator_ms: indicator_ms,
      acc: empty_output_state(),
      pending: empty_output_state(),
      last_flush: now,
      last_data: now,
      stream_state: {0, false, ""}
    })
  rescue
    e ->
      {:error, "command failed: #{Exception.message(e)}"}
  end

  @typep output_state ::
           {chunks :: [binary()], retained_bytes :: non_neg_integer(), truncated? :: boolean()}
  @typep stream_state ::
           {sent_bytes :: non_neg_integer(), truncated? :: boolean(), utf8_tail :: binary()}
  @typep collect_state :: %{
           deadline: integer(),
           on_output: (String.t() -> :ok) | nil,
           indicator_ms: pos_integer(),
           acc: output_state(),
           pending: output_state(),
           last_flush: integer(),
           last_data: integer(),
           stream_state: stream_state()
         }

  @spec collect_output(port(), collect_state()) :: {:ok, String.t()} | {:error, String.t()}
  defp collect_output(port, state) do
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)
    wait_ms = min(remaining, @debounce_ms)

    receive do
      {^port, {:data, data}} -> handle_port_data(port, data, state)
      {^port, {:exit_status, exit_code}} -> handle_port_exit(exit_code, state)
    after
      wait_ms -> handle_port_wait(port, state)
    end
  end

  @spec handle_port_data(port(), binary(), collect_state()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp handle_port_data(port, data, state) do
    now = System.monotonic_time(:millisecond)

    if now >= state.deadline do
      timeout_result(port, state)
    else
      state = %{state | acc: retain_output(state.acc, data), last_data: now}
      state = retain_pending(data, state)
      maybe_flush_pending_and_continue(port, now, state)
    end
  end

  @spec handle_port_exit(integer(), collect_state()) :: {:ok, String.t()}
  defp handle_port_exit(exit_code, state) do
    flush_if_needed(state)
    output = state.acc |> output_state_to_binary() |> String.trim_trailing()

    result = if exit_code == 0, do: output, else: "#{output}\n[exit code: #{exit_code}]"
    {:ok, result}
  end

  @spec handle_port_wait(port(), collect_state()) :: {:ok, String.t()} | {:error, String.t()}
  defp handle_port_wait(port, state) do
    now = System.monotonic_time(:millisecond)

    if now >= state.deadline do
      timeout_result(port, state)
    else
      {pending, last_flush, last_data, stream_state} =
        maybe_flush_or_indicate(
          state.on_output,
          state.pending,
          state.last_flush,
          state.last_data,
          now,
          state.indicator_ms,
          state.stream_state
        )

      collect_output(port, %{
        state
        | pending: pending,
          last_flush: last_flush,
          last_data: last_data,
          stream_state: stream_state
      })
    end
  end

  @spec timeout_result(port(), collect_state()) :: {:error, String.t()}
  defp timeout_result(port, state) do
    flush_if_needed(state)
    close_port(port)
    {:error, "command timed out"}
  end

  @spec flush_if_needed(collect_state()) :: :ok
  defp flush_if_needed(%{on_output: nil}), do: :ok
  defp flush_if_needed(%{pending: pending}) when pending == {[], 0, false}, do: :ok

  defp flush_if_needed(state) do
    _stream_state = flush_pending(state.on_output, state.pending, state.stream_state)
    :ok
  end

  @spec retain_pending(binary(), collect_state()) :: collect_state()
  defp retain_pending(_data, %{on_output: nil} = state), do: state

  defp retain_pending(data, state) do
    %{state | pending: retain_output(state.pending, data, pending_limit(state.stream_state))}
  end

  @spec maybe_flush_pending_and_continue(port(), integer(), collect_state()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp maybe_flush_pending_and_continue(port, now, state) do
    if state.on_output != nil and now - state.last_flush >= @debounce_ms do
      stream_state = flush_pending(state.on_output, state.pending, state.stream_state)

      collect_output(port, %{
        state
        | pending: empty_output_state(),
          last_flush: now,
          stream_state: stream_state
      })
    else
      collect_output(port, state)
    end
  end

  @spec maybe_flush_or_indicate(
          (String.t() -> :ok) | nil,
          output_state(),
          integer(),
          integer(),
          integer(),
          pos_integer(),
          stream_state()
        ) :: {output_state(), integer(), integer(), stream_state()}
  defp maybe_flush_or_indicate(
         nil,
         pending,
         last_flush,
         last_data,
         _now,
         _indicator_ms,
         stream_state
       ) do
    {pending, last_flush, last_data, stream_state}
  end

  defp maybe_flush_or_indicate(
         on_output,
         pending,
         last_flush,
         last_data,
         now,
         indicator_ms,
         stream_state
       ) do
    if not output_state_empty?(pending) and now - last_flush >= @debounce_ms do
      stream_state = flush_pending(on_output, pending, stream_state)
      {empty_output_state(), now, last_data, stream_state}
    else
      if output_state_empty?(pending) and now - last_data >= indicator_ms do
        stream_state = emit_stream_chunk(on_output, "[running...]\n", stream_state)
        {empty_output_state(), now, now, stream_state}
      else
        {pending, last_flush, last_data, stream_state}
      end
    end
  end

  @spec flush_pending((String.t() -> :ok), output_state(), stream_state()) :: stream_state()
  defp flush_pending(on_output, pending, stream_state) do
    stream_state = emit_stream_chunk(on_output, output_state_content(pending), stream_state)
    maybe_emit_stream_truncation(on_output, stream_state, elem(pending, 2))
  end

  @spec maybe_emit_stream_truncation((String.t() -> :ok), stream_state(), boolean()) ::
          stream_state()
  defp maybe_emit_stream_truncation(_on_output, stream_state, false), do: stream_state

  defp maybe_emit_stream_truncation(_on_output, {_sent_bytes, true, _tail} = stream_state, true),
    do: stream_state

  defp maybe_emit_stream_truncation(on_output, _stream_state, true) do
    on_output.("\n\n[stream truncated at #{div(@max_output_bytes, 1000)}KB]\n")
    {@max_output_bytes, true, ""}
  end

  @spec emit_stream_chunk((String.t() -> :ok), binary(), stream_state()) :: stream_state()
  defp emit_stream_chunk(_on_output, _batch, {_sent_bytes, true, _tail} = stream_state),
    do: stream_state

  defp emit_stream_chunk(on_output, batch, {sent_bytes, false, tail}) do
    batch = tail <> batch
    remaining = @max_output_bytes - sent_bytes

    if byte_size(batch) <= remaining do
      {prefix, tail} = split_valid_prefix(batch)
      if prefix != "", do: on_output.(prefix)
      {sent_bytes + byte_size(prefix), false, tail}
    else
      chunk = OutputLimit.utf8_prefix(batch, remaining)
      if chunk != "", do: on_output.(chunk)
      on_output.("\n\n[stream truncated at #{div(@max_output_bytes, 1000)}KB]\n")
      {@max_output_bytes, true, ""}
    end
  end

  @spec split_valid_prefix(binary()) :: {String.t(), binary()}
  defp split_valid_prefix(batch) do
    prefix = OutputLimit.utf8_prefix(batch, byte_size(batch))
    tail_size = byte_size(batch) - byte_size(prefix)
    tail = binary_part(batch, byte_size(prefix), tail_size)
    {prefix, tail}
  end

  @spec empty_output_state() :: output_state()
  defp empty_output_state, do: {[], 0, false}

  @spec output_state_empty?(output_state()) :: boolean()
  defp output_state_empty?({[], 0, false}), do: true
  defp output_state_empty?(_output_state), do: false

  @spec pending_limit(stream_state()) :: non_neg_integer()
  defp pending_limit({sent_bytes, _truncated?, _tail}), do: max(@max_output_bytes - sent_bytes, 0)

  @spec retain_output(output_state(), binary()) :: output_state()
  defp retain_output(output_state, data), do: retain_output(output_state, data, @max_output_bytes)

  @spec retain_output(output_state(), binary(), non_neg_integer()) :: output_state()
  defp retain_output({_chunks, _retained_bytes, true} = output_state, _data, _max_bytes),
    do: output_state

  defp retain_output({chunks, retained_bytes, false}, data, max_bytes) do
    remaining = max(max_bytes - retained_bytes, 0)

    if byte_size(data) <= remaining do
      {[data | chunks], retained_bytes + byte_size(data), false}
    else
      prefix = binary_part(data, 0, remaining)
      chunks = if prefix == "", do: chunks, else: [prefix | chunks]
      {chunks, max_bytes, true}
    end
  end

  @spec output_state_content(output_state()) :: binary()
  defp output_state_content({chunks, _retained_bytes, _truncated?}) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @spec output_state_to_binary(output_state()) :: String.t()
  defp output_state_to_binary({_chunks, _retained_bytes, truncated?} = output_state) do
    output = output_state_content(output_state)

    if truncated? do
      OutputLimit.utf8_prefix(output, byte_size(output)) <>
        "\n\n[truncated at #{div(@max_output_bytes, 1000)}KB]"
    else
      output
    end
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec safe_env_charlist([{String.t(), String.t()}]) :: [{charlist(), charlist()}]
  defp safe_env_charlist(extra_env) do
    base = [
      {"PAGER", "cat"},
      {"GIT_PAGER", "cat"},
      {"TERM", "dumb"}
    ]

    Enum.map(base ++ extra_env, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end
end
