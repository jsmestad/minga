defmodule MingaEditor.Frontend.Manager.OutputHandler do
  @moduledoc "Owns non-suspending Port admission, bounded frame retention, and recovery correlation."

  alias Minga.Protocol.Opcodes
  alias Minga.Telemetry
  alias MingaEditor.Frontend.FrameTransaction
  alias MingaEditor.Frontend.Manager
  alias MingaEditor.Frontend.Manager.OutputPressure
  alias MingaEditor.Frontend.Manager.PendingFrame
  alias MingaEditor.Frontend.Manager.State
  alias MingaEditor.Frontend.Protocol

  @clipboard_write Opcodes.clipboard_write()

  @doc "Attempts one command batch without suspending the Port owner."
  @spec admit_commands(State.t(), [binary()]) :: {Manager.admission(), State.t()}
  def admit_commands(%{port: nil} = state, _commands), do: {:unwritable, state}

  def admit_commands(state, commands) do
    log_frame_transaction_violation(commands)

    case PendingFrame.from_commands(commands) do
      {:ok, frame} -> admit_frame(state, frame)
      {:error, _reason} -> admit_control(state, commands)
    end
  end

  @doc "Retries the retained current frame for the matching timer token."
  @spec retry(State.t(), reference()) :: State.t()
  def retry(state, token) do
    case OutputPressure.consume_retry(state.output_pressure, token) do
      {:ok, output_pressure} ->
        {_admission, state} = attempt_output(%{state | output_pressure: output_pressure})
        state

      :stale ->
        state
    end
  end

  @doc "Broadcasts a correlated acknowledgement or rejects it as stale."
  @spec frame_applied(
          State.t(),
          Protocol.input_event(),
          non_neg_integer(),
          non_neg_integer()
        ) :: State.t()
  def frame_applied(state, event, generation, frame_seq) do
    case OutputPressure.acknowledge(state.output_pressure, generation, frame_seq) do
      {:accepted, output_pressure} ->
        broadcast(state.subscribers, {:minga_input, event})
        %{state | output_pressure: output_pressure}

      :stale ->
        Minga.Log.debug(
          :port,
          "Ignored stale frontend acknowledgement generation #{generation} frame #{frame_seq}"
        )

        state
    end
  end

  @doc "Clears retained output when the frontend transport disconnects."
  @spec disconnect(State.t()) :: State.t()
  def disconnect(state),
    do: %{state | port: nil, ready: false, output_pressure: OutputPressure.new()}

  @doc "Attempts and, if needed, retains one out-of-band control write."
  @spec write_control(State.t(), binary()) :: {Manager.admission(), State.t()}
  def write_control(%{port: nil} = state, _batch), do: {:unwritable, state}
  def write_control(state, batch), do: admit_control_batch(state, first_opcode(batch), batch)

  @spec admit_frame(State.t(), PendingFrame.t()) :: {Manager.admission(), State.t()}
  defp admit_frame(state, frame) do
    case OutputPressure.enqueue(state.output_pressure, frame) do
      {:attempt, output_pressure} -> attempt_output(%{state | output_pressure: output_pressure})
      {:coalesced, output_pressure} -> {:unwritable, %{state | output_pressure: output_pressure}}
    end
  end

  @spec attempt_output(State.t()) :: {Manager.admission(), State.t()}
  defp attempt_output(state) do
    now = System.monotonic_time(:millisecond)

    case expired_current(state, now) do
      nil -> attempt_next_output(state)
      failed -> {:unwritable, require_keyframe_recovery(state, failed)}
    end
  end

  @spec attempt_next_output(State.t()) :: {Manager.admission(), State.t()}
  defp attempt_next_output(state) do
    case OutputPressure.next_control(state.output_pressure) do
      nil -> attempt_current(state)
      {key, batch} -> attempt_control(state, key, batch)
    end
  end

  @spec attempt_current(State.t()) :: {Manager.admission(), State.t()}
  defp attempt_current(%{output_pressure: %{current: nil}} = state) do
    output_pressure = OutputPressure.settled(state.output_pressure)
    {:accepted, %{state | output_pressure: output_pressure}}
  end

  defp attempt_current(%{output_pressure: %{current: current}} = state) do
    case write_batch(state, current.batch) do
      :accepted -> current_admitted(state)
      :unwritable -> current_unwritable(state, current)
    end
  end

  @spec current_admitted(State.t()) :: {Manager.admission(), State.t()}
  defp current_admitted(state) do
    {admitted, output_pressure} = OutputPressure.admitted(state.output_pressure)
    state = %{state | output_pressure: output_pressure}

    case output_pressure.current do
      nil ->
        attempt_output(state)

      successor ->
        admit_successor(state, successor, admitted)
    end
  end

  @spec admit_successor(State.t(), PendingFrame.t(), PendingFrame.t()) ::
          {Manager.admission(), State.t()}
  defp admit_successor(state, successor, admitted) do
    if PendingFrame.follows?(successor, admitted) do
      {_successor_admission, state} = attempt_output(state)
      {:accepted, state}
    else
      {:accepted, require_keyframe_recovery(state, successor)}
    end
  end

  @spec current_unwritable(State.t(), PendingFrame.t()) :: {Manager.admission(), State.t()}
  defp current_unwritable(state, _current) do
    now = System.monotonic_time(:millisecond)
    retry_or_recover_current(state, now)
  end

  @spec retry_or_recover_current(State.t(), integer()) :: {Manager.admission(), State.t()}
  defp retry_or_recover_current(state, now) do
    case expired_current(state, now) do
      nil -> {:unwritable, ensure_retry(state, now)}
      failed -> {:unwritable, require_keyframe_recovery(state, failed)}
    end
  end

  @spec expired_current(State.t(), integer()) :: PendingFrame.t() | nil
  defp expired_current(
         %{output_pressure: %OutputPressure{current: %PendingFrame{} = current}} = state,
         now
       ) do
    if OutputPressure.expired?(state.output_pressure, now, state.output_failure_ms),
      do: current,
      else: nil
  end

  defp expired_current(%{output_pressure: %OutputPressure{current: nil}}, _now), do: nil

  @spec ensure_retry(State.t(), integer()) :: State.t()
  defp ensure_retry(state, now) do
    if OutputPressure.retry_scheduled?(state.output_pressure) do
      state
    else
      token = make_ref()
      Process.send_after(self(), {:retry_frontend_output, token}, state.output_retry_ms)
      output_pressure = OutputPressure.mark_unwritable(state.output_pressure, now, token)
      %{state | output_pressure: output_pressure}
    end
  end

  @spec require_keyframe_recovery(State.t(), PendingFrame.t()) :: State.t()
  defp require_keyframe_recovery(state, failed) do
    stats = OutputPressure.stats(state.output_pressure)
    output_pressure = OutputPressure.require_recovery(state.output_pressure, failed)

    Minga.Log.warning(
      :port,
      "Frontend output remained unwritable for frame #{failed.frame_seq}; requesting keyframe recovery"
    )

    broadcast(
      state.subscribers,
      {:minga_input, {:request_keyframe, stats.last_applied_frame_seq, failed.generation}}
    )

    %{state | output_pressure: output_pressure}
  end

  @spec admit_control(State.t(), [binary()]) :: {Manager.admission(), State.t()}
  defp admit_control(state, []), do: {write_batch(state, <<>>), state}

  defp admit_control(state, [first | _commands] = commands),
    do: admit_control_batch(state, first_opcode(first), IO.iodata_to_binary(commands))

  @spec admit_control_batch(State.t(), non_neg_integer(), binary()) ::
          {Manager.admission(), State.t()}
  defp admit_control_batch(state, opcode, batch) do
    if output_pending?(state.output_pressure) do
      retain_control(state, opcode, batch)
    else
      case write_batch(state, batch) do
        :accepted -> {:accepted, state}
        :unwritable -> retain_control(state, opcode, batch)
      end
    end
  end

  @spec attempt_control(State.t(), OutputPressure.control_key(), binary()) ::
          {Manager.admission(), State.t()}
  defp attempt_control(state, key, batch) do
    case write_batch(state, batch) do
      :accepted ->
        output_pressure = OutputPressure.control_admitted(state.output_pressure, key)
        attempt_output(%{state | output_pressure: output_pressure})

      :unwritable ->
        retry_or_recover_current(state, System.monotonic_time(:millisecond))
    end
  end

  @spec retain_control(State.t(), non_neg_integer(), binary()) ::
          {Manager.admission(), State.t()}
  defp retain_control(state, opcode, batch) do
    key = control_key(opcode, batch)
    output_pressure = OutputPressure.retain_control(state.output_pressure, key, batch)
    state = %{state | output_pressure: output_pressure}
    {:unwritable, ensure_retry(state, System.monotonic_time(:millisecond))}
  end

  @spec output_pending?(OutputPressure.t()) :: boolean()
  defp output_pending?(%OutputPressure{current: current} = pressure),
    do: current != nil or OutputPressure.controls_pending?(pressure)

  @spec control_key(non_neg_integer(), binary()) :: OutputPressure.control_key()
  defp control_key(
         @clipboard_write,
         <<@clipboard_write, _payload_length::32, target::8, _payload::binary>>
       ),
       do: {@clipboard_write, target}

  defp control_key(opcode, _batch), do: opcode

  @spec first_opcode(binary()) :: non_neg_integer()
  defp first_opcode(<<opcode, _::binary>>), do: opcode
  defp first_opcode(<<>>), do: 0

  @spec write_batch(State.t(), binary()) :: Manager.admission()
  defp write_batch(state, batch) do
    Telemetry.span_with_stop_metadata([:minga, :port, :write], %{}, fn ->
      admission = port_admission(state, batch)
      {admission, %{byte_count: byte_size(batch), admission: admission}}
    end)
  end

  @spec port_admission(State.t(), binary()) :: Manager.admission()
  defp port_admission(state, batch) do
    if state.port_commander.(state.port, batch, [:nosuspend]),
      do: :accepted,
      else: :unwritable
  rescue
    ArgumentError -> :unwritable
  end

  @spec log_frame_transaction_violation([binary()]) :: :ok
  defp log_frame_transaction_violation(commands) do
    case FrameTransaction.validate(commands) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(
          :port,
          "Frontend command batch violates frame transaction: #{FrameTransaction.format_error(reason)}"
        )
    end
  end

  @spec broadcast([pid()], term()) :: :ok
  defp broadcast(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
  end
end
