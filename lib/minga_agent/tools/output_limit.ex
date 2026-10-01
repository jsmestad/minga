defmodule MingaAgent.Tools.OutputLimit do
  @moduledoc """
  UTF-8-safe output truncation for model-facing agent tool results.
  """

  alias MingaAgent.Tools.OutputLimit.Result

  @default_max_bytes 51_200
  @default_timeout_ms 10_000

  @type command_status :: Result.status()
  @type command_result :: Result.t()
  @type command_opts :: [
          cd: String.t(),
          stderr_to_stdout: boolean(),
          max_bytes: pos_integer(),
          timeout_ms: pos_integer()
        ]

  @typep output_state ::
           {chunks :: [binary()], retained_bytes :: non_neg_integer(), truncated? :: boolean()}
  @typep collecting_output_state ::
           {chunks :: [binary()], retained_bytes :: non_neg_integer(), false}

  @doc "Returns the default byte cap used for model-facing tool output."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc "Returns the default wall-clock timeout for bounded command collection."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc "Runs a command through a Port, terminating it when the finite capture allowance is exhausted."
  @spec collect_command(String.t(), [String.t()], command_opts()) :: command_result()
  def collect_command(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    port_opts = [
      :binary,
      :exit_status,
      args: args
    ]

    port_opts =
      if Keyword.get(opts, :stderr_to_stdout, false),
        do: [:stderr_to_stdout | port_opts],
        else: port_opts

    port_opts =
      case Keyword.get(opts, :cd) do
        nil -> port_opts
        cd -> [{:cd, cd} | port_opts]
      end

    port = Port.open({:spawn_executable, cmd}, port_opts)
    collect_port(port, {[], 0, false}, max_bytes, deadline(timeout_ms))
  end

  @doc "Truncates `output` to `max_bytes` without splitting UTF-8 codepoints."
  @spec truncate_utf8(String.t(), non_neg_integer(), String.t()) :: String.t()
  def truncate_utf8(output, max_bytes, _marker) when byte_size(output) <= max_bytes, do: output

  def truncate_utf8(output, max_bytes, marker) do
    utf8_prefix(output, max_bytes) <> marker
  end

  @doc "Returns at most `max_bytes` from the front of `output` without splitting UTF-8 codepoints."
  @spec utf8_prefix(binary(), non_neg_integer()) :: String.t()
  def utf8_prefix(_output, limit) when limit <= 0, do: ""

  def utf8_prefix(output, limit) when is_binary(output) do
    prefix = binary_part(output, 0, min(limit, byte_size(output)))

    if String.valid?(prefix) do
      prefix
    else
      utf8_prefix(output, limit - 1)
    end
  end

  @doc "Splits command output into complete lines, dropping a truncated final line."
  @spec complete_lines(String.t(), boolean()) :: [String.t()]
  def complete_lines(output, true) do
    output
    |> String.split("\n", trim: true)
    |> maybe_drop_truncated_tail(String.ends_with?(output, "\n"))
  end

  def complete_lines(output, false), do: String.split(output, "\n", trim: true)

  @spec maybe_drop_truncated_tail([String.t()], boolean()) :: [String.t()]
  defp maybe_drop_truncated_tail(lines, true), do: lines
  defp maybe_drop_truncated_tail([] = lines, false), do: lines
  defp maybe_drop_truncated_tail(lines, false), do: Enum.drop(lines, -1)

  @spec collect_port(port(), collecting_output_state(), pos_integer(), integer()) ::
          command_result()
  defp collect_port(port, {_chunks, _bytes, false} = output_state, max_bytes, deadline_ms) do
    receive do
      {^port, {:data, data}} ->
        if expired?(deadline_ms) do
          close_port(port)
          Result.new(output_state_to_binary(output_state), :timeout, {:incomplete, :timeout})
        else
          next_state = retain_output(output_state, data, max_bytes)
          collect_after_data(port, next_state, max_bytes, deadline_ms)
        end

      {^port, {:exit_status, exit_code}} ->
        Result.new(output_state_to_binary(output_state), exit_code, :complete)
    after
      remaining_ms(deadline_ms) ->
        close_port(port)
        Result.new(output_state_to_binary(output_state), :timeout, {:incomplete, :timeout})
    end
  end

  @spec collect_after_data(port(), output_state(), pos_integer(), integer()) :: command_result()
  defp collect_after_data(port, {_chunks, _bytes, true} = output_state, _max_bytes, _deadline) do
    close_port(port)

    Result.new(
      output_state_to_binary(output_state),
      :terminated,
      {:incomplete, :capture_byte_limit}
    )
  end

  defp collect_after_data(
         port,
         {_chunks, _bytes, false} = output_state,
         max_bytes,
         deadline_ms
       ) do
    collect_port(port, output_state, max_bytes, deadline_ms)
  end

  @spec retain_output(collecting_output_state(), binary(), pos_integer()) :: output_state()
  defp retain_output({chunks, retained_bytes, false}, data, max_bytes) do
    remaining = max_bytes - retained_bytes

    if byte_size(data) <= remaining do
      {[data | chunks], retained_bytes + byte_size(data), false}
    else
      prefix = binary_part(data, 0, max(remaining, 0))
      chunks = if prefix == "", do: chunks, else: [prefix | chunks]
      {chunks, max_bytes, true}
    end
  end

  @spec output_state_to_binary(output_state()) :: String.t()
  defp output_state_to_binary({chunks, _retained_bytes, truncated?}) do
    output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    if truncated? do
      utf8_prefix(output, byte_size(output))
    else
      output
    end
  end

  @spec deadline(pos_integer()) :: integer()
  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  @spec expired?(integer()) :: boolean()
  defp expired?(deadline_ms), do: System.monotonic_time(:millisecond) >= deadline_ms

  @spec remaining_ms(integer()) :: non_neg_integer()
  defp remaining_ms(deadline_ms), do: max(deadline_ms - System.monotonic_time(:millisecond), 0)

  @doc "Closes a command Port if needed and drains already-delivered Port messages."
  @spec close_port(port()) :: :ok
  def close_port(port) do
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
      {^port, {:data, _data}} -> drain_port(port)
      {^port, {:exit_status, _status}} -> drain_port(port)
      {:EXIT, ^port, _reason} -> drain_port(port)
    after
      0 -> :ok
    end
  end
end
