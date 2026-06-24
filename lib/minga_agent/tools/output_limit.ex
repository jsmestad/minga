defmodule MingaAgent.Tools.OutputLimit do
  @moduledoc """
  UTF-8-safe output truncation for model-facing agent tool results.
  """

  @default_max_bytes 64_000

  @type command_result ::
          {output :: String.t(), exit_code :: non_neg_integer(), truncated? :: boolean()}
  @type command_opts :: [cd: String.t(), stderr_to_stdout: boolean(), max_bytes: pos_integer()]
  @typep output_state ::
           {chunks :: [String.t()], retained_bytes :: non_neg_integer(), truncated? :: boolean()}

  @doc "Returns the default byte cap used for model-facing tool output."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc "Runs a command through a Port and retains at most `max_bytes` of output."
  @spec collect_command(String.t(), [String.t()], command_opts()) :: command_result()
  def collect_command(cmd, args, opts \\ []) when is_binary(cmd) and is_list(args) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

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
    collect_port(port, {[], 0, false}, max_bytes)
  end

  @doc "Truncates `output` to `max_bytes` without splitting UTF-8 codepoints."
  @spec truncate_utf8(String.t(), non_neg_integer(), String.t()) :: String.t()
  def truncate_utf8(output, max_bytes, _marker) when byte_size(output) <= max_bytes, do: output

  def truncate_utf8(output, max_bytes, marker) do
    utf8_prefix(output, max_bytes) <> marker
  end

  @doc "Returns at most `max_bytes` from the front of `output` without splitting UTF-8 codepoints."
  @spec utf8_prefix(String.t(), non_neg_integer()) :: String.t()
  def utf8_prefix(_output, limit) when limit <= 0, do: ""

  def utf8_prefix(output, limit) do
    prefix = binary_part(output, 0, min(limit, byte_size(output)))

    if String.valid?(prefix) do
      prefix
    else
      utf8_prefix(output, limit - 1)
    end
  end

  @spec collect_port(port(), output_state(), pos_integer()) :: command_result()
  defp collect_port(port, output_state, max_bytes) do
    receive do
      {^port, {:data, data}} ->
        output_state = retain_output(output_state, data, max_bytes)

        case output_state do
          {_chunks, _retained, true} ->
            close_port(port)
            {output_state_to_binary(output_state), 0, true}

          _ ->
            collect_port(port, output_state, max_bytes)
        end

      {^port, {:exit_status, exit_code}} ->
        {output_state_to_binary(output_state), exit_code, elem(output_state, 2)}
    end
  end

  @spec retain_output(output_state(), String.t(), pos_integer()) :: output_state()
  defp retain_output({_chunks, _retained_bytes, true} = output_state, _data, _max_bytes),
    do: output_state

  defp retain_output({chunks, retained_bytes, false}, data, max_bytes) do
    remaining = max_bytes - retained_bytes

    if byte_size(data) <= remaining do
      {[data | chunks], retained_bytes + byte_size(data), false}
    else
      prefix = utf8_prefix(data, remaining)
      chunks = if prefix == "", do: chunks, else: [prefix | chunks]
      {chunks, max_bytes, true}
    end
  end

  @spec output_state_to_binary(output_state()) :: String.t()
  defp output_state_to_binary({chunks, _retained_bytes, _truncated?}) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
