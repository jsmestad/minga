defmodule MingaEditor.Frontend.Manager.OutputPressure do
  @moduledoc "Bounded frontend output retention and acknowledgement correlation state."

  alias MingaEditor.Frontend.Manager.PendingFrame

  defstruct current: nil,
            replacement: nil,
            controls: %{},
            unwritable_since: nil,
            retry_token: nil,
            minimum_ack_generation: 0,
            last_admitted_generation: 0,
            last_admitted_frame_seq: 0,
            last_applied_generation: 0,
            last_applied_frame_seq: 0

  @type control_key :: non_neg_integer() | {non_neg_integer(), non_neg_integer()}
  @type timeout_disposition :: :continue | {:recover_frame, PendingFrame.t()} | :transport_failure

  @type t :: %__MODULE__{
          current: PendingFrame.t() | nil,
          replacement: PendingFrame.t() | nil,
          controls: %{control_key() => binary()},
          unwritable_since: integer() | nil,
          retry_token: reference() | nil,
          minimum_ack_generation: non_neg_integer(),
          last_admitted_generation: non_neg_integer(),
          last_admitted_frame_seq: non_neg_integer(),
          last_applied_generation: non_neg_integer(),
          last_applied_frame_seq: non_neg_integer()
        }

  @type stats :: %{
          current_frame_seq: non_neg_integer() | nil,
          replacement_frame_seq: non_neg_integer() | nil,
          current_bytes: non_neg_integer(),
          replacement_bytes: non_neg_integer(),
          retained_bytes: non_neg_integer(),
          control_batches: non_neg_integer(),
          control_bytes: non_neg_integer(),
          total_retained_bytes: non_neg_integer(),
          minimum_ack_generation: non_neg_integer(),
          last_admitted_generation: non_neg_integer(),
          last_admitted_frame_seq: non_neg_integer(),
          last_applied_generation: non_neg_integer(),
          last_applied_frame_seq: non_neg_integer()
        }

  @doc "Returns empty pressure state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Retains a first unwritable frame or replaces the single coalesced successor."
  @spec enqueue(t(), PendingFrame.t()) :: {:attempt, t()} | {:coalesced, t()}
  def enqueue(%__MODULE__{current: nil} = pressure, %PendingFrame{} = frame),
    do: {:attempt, %{pressure | current: frame}}

  def enqueue(%__MODULE__{} = pressure, %PendingFrame{} = frame),
    do: {:coalesced, %{pressure | replacement: frame}}

  @doc "Coalesces the latest unwritable out-of-band control batch by resource key."
  @spec retain_control(t(), control_key(), binary()) :: t()
  def retain_control(%__MODULE__{} = pressure, key, batch)
      when is_integer(key) and key >= 0 and is_binary(batch),
      do: put_control(pressure, key, batch)

  def retain_control(%__MODULE__{} = pressure, {opcode, resource} = key, batch)
      when is_integer(opcode) and opcode >= 0 and is_integer(resource) and resource >= 0 and
             is_binary(batch),
      do: put_control(pressure, key, batch)

  @doc "Returns the next retained control batch in deterministic resource-key order."
  @spec next_control(t()) :: {control_key(), binary()} | nil
  def next_control(%__MODULE__{controls: controls}) when map_size(controls) == 0, do: nil

  def next_control(%__MODULE__{controls: controls}) do
    key = controls |> Map.keys() |> Enum.min()
    {key, Map.fetch!(controls, key)}
  end

  @doc "Drops one admitted control batch."
  @spec control_admitted(t(), control_key()) :: t()
  def control_admitted(%__MODULE__{} = pressure, key),
    do: %{pressure | controls: Map.delete(pressure.controls, key)}

  @doc "Drops retained frames while preserving controls and the shared unwritable interval."
  @spec revoke_frames(t()) :: t()
  def revoke_frames(%__MODULE__{} = pressure),
    do: %{pressure | current: nil, replacement: nil}

  @doc "Reserves the next recovery generation and revokes frames from the superseded generation."
  @spec reserve_recovery_generation(t()) :: {pos_integer(), t()}
  def reserve_recovery_generation(%__MODULE__{} = pressure) do
    generation =
      max(
        pressure.minimum_ack_generation,
        max(pressure.last_admitted_generation, pressure.last_applied_generation)
      ) + 1

    {generation,
     %{
       pressure
       | current: nil,
         replacement: nil,
         minimum_ack_generation: generation
     }}
  end

  @doc "Clears the unwritable interval after every retained batch drains."
  @spec settled(t()) :: t()
  def settled(%__MODULE__{current: nil, replacement: nil, controls: controls} = pressure)
      when map_size(controls) == 0,
      do: %{pressure | unwritable_since: nil, retry_token: nil}

  def settled(%__MODULE__{} = pressure), do: pressure

  @doc "Returns whether any control batch is retained."
  @spec controls_pending?(t()) :: boolean()
  def controls_pending?(%__MODULE__{controls: controls}), do: map_size(controls) > 0

  @doc "Returns whether a retry timer is already correlated."
  @spec retry_scheduled?(t()) :: boolean()
  def retry_scheduled?(%__MODULE__{retry_token: token}), do: is_reference(token)

  @doc "Marks the current admission unwritable and correlates one retry token."
  @spec mark_unwritable(t(), integer(), reference()) :: t()
  def mark_unwritable(%__MODULE__{} = pressure, now, retry_token)
      when is_integer(now) and is_reference(retry_token) do
    since = pressure.unwritable_since || now
    %{pressure | unwritable_since: since, retry_token: retry_token}
  end

  @doc "Consumes the matching retry token and rejects stale timer messages."
  @spec consume_retry(t(), reference()) :: {:ok, t()} | :stale
  def consume_retry(%__MODULE__{retry_token: token} = pressure, token) when is_reference(token),
    do: {:ok, %{pressure | retry_token: nil}}

  def consume_retry(%__MODULE__{}, _token), do: :stale

  @doc "Returns whether the current unwritable interval reached its failure budget."
  @spec expired?(t(), integer(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{unwritable_since: since}, now, failure_ms)
      when is_integer(since) and is_integer(now) and is_integer(failure_ms) and failure_ms >= 0,
      do: now - since >= failure_ms

  def expired?(%__MODULE__{}, _now, _failure_ms), do: false

  @doc "Classifies an expired shared interval, giving retained controls terminal precedence."
  @spec classify_timeout(t(), integer(), non_neg_integer()) :: timeout_disposition()
  def classify_timeout(%__MODULE__{} = pressure, now, failure_ms) do
    if expired?(pressure, now, failure_ms),
      do: classify_expired_output(pressure),
      else: :continue
  end

  @doc "Advances after the current frame is admitted and returns the admitted frame."
  @spec admitted(t()) :: {PendingFrame.t(), t()}
  def admitted(%__MODULE__{current: %PendingFrame{} = current} = pressure) do
    {generation, frame_seq} = admission_watermark(pressure, current)

    {current,
     %{
       pressure
       | current: pressure.replacement,
         replacement: nil,
         last_admitted_generation: generation,
         last_admitted_frame_seq: frame_seq
     }}
  end

  @doc "Drops retained output and requires acknowledgements from the next generation."
  @spec require_recovery(t(), PendingFrame.t()) :: t()
  def require_recovery(
        %__MODULE__{controls: controls} = pressure,
        %PendingFrame{} = failed
      )
      when map_size(controls) == 0 do
    %{
      pressure
      | current: nil,
        replacement: nil,
        unwritable_since: nil,
        retry_token: nil,
        minimum_ack_generation: max(pressure.minimum_ack_generation, failed.generation + 1)
    }
  end

  @doc "Drops retained output and invalidates retry correlation after terminal transport failure."
  @spec fail_transport(t()) :: t()
  def fail_transport(%__MODULE__{} = pressure) do
    %{
      pressure
      | current: nil,
        replacement: nil,
        controls: %{},
        unwritable_since: nil,
        retry_token: nil
    }
  end

  @doc "Accepts a correlated acknowledgement or rejects stale generation and sequence values."
  @spec acknowledge(t(), non_neg_integer(), non_neg_integer()) :: {:accepted, t()} | :stale
  def acknowledge(%__MODULE__{} = pressure, generation, frame_seq)
      when is_integer(generation) and generation >= 0 and is_integer(frame_seq) and frame_seq >= 0 do
    if stale_ack?(pressure, generation, frame_seq) do
      :stale
    else
      {:accepted,
       %{
         pressure
         | last_applied_generation: generation,
           last_applied_frame_seq: frame_seq
       }}
    end
  end

  @doc "Returns bounded retained-byte and acknowledgement diagnostics."
  @spec stats(t()) :: stats()
  def stats(%__MODULE__{} = pressure) do
    current_bytes = frame_bytes(pressure.current)
    replacement_bytes = frame_bytes(pressure.replacement)

    control_bytes =
      pressure.controls
      |> Map.values()
      |> Enum.reduce(0, fn batch, total -> total + byte_size(batch) end)

    %{
      current_frame_seq: frame_seq(pressure.current),
      replacement_frame_seq: frame_seq(pressure.replacement),
      current_bytes: current_bytes,
      replacement_bytes: replacement_bytes,
      retained_bytes: current_bytes + replacement_bytes,
      control_batches: map_size(pressure.controls),
      control_bytes: control_bytes,
      total_retained_bytes: current_bytes + replacement_bytes + control_bytes,
      minimum_ack_generation: pressure.minimum_ack_generation,
      last_admitted_generation: pressure.last_admitted_generation,
      last_admitted_frame_seq: pressure.last_admitted_frame_seq,
      last_applied_generation: pressure.last_applied_generation,
      last_applied_frame_seq: pressure.last_applied_frame_seq
    }
  end

  @spec stale_ack?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp stale_ack?(pressure, generation, frame_seq) do
    generation < pressure.minimum_ack_generation or
      generation > pressure.last_admitted_generation or
      (generation == pressure.last_admitted_generation and
         frame_seq > pressure.last_admitted_frame_seq) or
      generation < pressure.last_applied_generation or
      (generation == pressure.last_applied_generation and
         frame_seq <= pressure.last_applied_frame_seq)
  end

  @spec admission_watermark(t(), PendingFrame.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp admission_watermark(pressure, %PendingFrame{generation: generation, frame_seq: frame_seq})
       when generation > pressure.last_admitted_generation,
       do: {generation, frame_seq}

  defp admission_watermark(pressure, %PendingFrame{generation: generation, frame_seq: frame_seq})
       when generation == pressure.last_admitted_generation and
              frame_seq > pressure.last_admitted_frame_seq,
       do: {generation, frame_seq}

  defp admission_watermark(pressure, %PendingFrame{}),
    do: {pressure.last_admitted_generation, pressure.last_admitted_frame_seq}

  @spec classify_expired_output(t()) :: timeout_disposition()
  defp classify_expired_output(%__MODULE__{controls: controls}) when map_size(controls) > 0,
    do: :transport_failure

  defp classify_expired_output(%__MODULE__{current: %PendingFrame{} = current}),
    do: {:recover_frame, current}

  defp classify_expired_output(%__MODULE__{}), do: :continue

  @spec put_control(t(), control_key(), binary()) :: t()
  defp put_control(pressure, key, batch),
    do: %{pressure | controls: Map.put(pressure.controls, key, batch)}

  @spec frame_bytes(PendingFrame.t() | nil) :: non_neg_integer()
  defp frame_bytes(nil), do: 0
  defp frame_bytes(frame), do: PendingFrame.byte_size(frame)

  @spec frame_seq(PendingFrame.t() | nil) :: non_neg_integer() | nil
  defp frame_seq(nil), do: nil
  defp frame_seq(%PendingFrame{frame_seq: frame_seq}), do: frame_seq
end
