defmodule MingaEditor.State.RenderCorrelation do
  @moduledoc "Immutable Editor-owned render scheduling, keyframe, and receipt-ordering state."

  defstruct timer: nil,
            timer_identity: nil,
            timer_sequence: 0,
            keyframe_pending?: false,
            latest_intent_revision: 0,
            last_receipt_revision: 0,
            last_receipt_seq: 0

  @opaque timer_identity :: {:render_window, pos_integer()}

  @opaque t :: %__MODULE__{
            timer: reference() | nil,
            timer_identity: timer_identity() | nil,
            timer_sequence: non_neg_integer(),
            keyframe_pending?: boolean(),
            latest_intent_revision: non_neg_integer(),
            last_receipt_revision: non_neg_integer(),
            last_receipt_seq: non_neg_integer()
          }

  @type freshness_reason :: :superseded_intent | :stale_receipt_revision | :stale_sequence
  @type freshness :: {:fresh, non_neg_integer()} | {:stale, freshness_reason()}
  @type timer_delivery :: {:current, t()} | {:stale, t()}

  @doc "Returns initial render correlation state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the semantic identity for the next render window."
  @spec next_timer_identity(t()) :: timer_identity()
  def next_timer_identity(%__MODULE__{timer_sequence: sequence}),
    do: {:render_window, sequence + 1}

  @doc "Admits one render timer or coalesces into the already scheduled timer."
  @spec schedule(t(), timer_identity(), reference()) :: {:scheduled | :coalesced, t()}
  def schedule(
        %__MODULE__{timer: nil, timer_sequence: sequence} = correlation,
        {:render_window, next_sequence} = identity,
        timer
      )
      when next_sequence == sequence + 1 and is_reference(timer) do
    {:scheduled,
     %{
       correlation
       | timer: timer,
         timer_identity: identity,
         timer_sequence: next_sequence
     }}
  end

  def schedule(%__MODULE__{} = correlation, {:render_window, sequence}, timer)
      when is_integer(sequence) and sequence > 0 and is_reference(timer),
      do: {:coalesced, correlation}

  @doc "Returns whether a render timer currently owns the throttle window."
  @spec scheduled?(t()) :: boolean()
  def scheduled?(%__MODULE__{timer: timer, timer_identity: identity}),
    do: is_reference(timer) and not is_nil(identity)

  @doc "Returns the current timer reference for cancellation at the Editor boundary."
  @spec timer_reference(t()) :: reference() | nil
  def timer_reference(%__MODULE__{timer: timer}), do: timer

  @doc "Returns the identity of the currently scheduled render window."
  @spec scheduled_identity(t()) :: timer_identity() | nil
  def scheduled_identity(%__MODULE__{timer_identity: identity}), do: identity

  @doc "Clears the scheduled render window while preserving its monotonic identity sequence."
  @spec clear_timer(t()) :: t()
  def clear_timer(%__MODULE__{} = correlation),
    do: %{correlation | timer: nil, timer_identity: nil}

  @doc "Accepts only delivery for the currently scheduled render window."
  @spec deliver(t(), timer_identity()) :: timer_delivery()
  def deliver(
        %__MODULE__{timer_identity: {:render_window, sequence}} = correlation,
        {:render_window, sequence}
      ),
      do: {:current, clear_timer(correlation)}

  def deliver(%__MODULE__{} = correlation, {:render_window, sequence})
      when is_integer(sequence) and sequence > 0,
      do: {:stale, correlation}

  @doc "Queues a keyframe request for one handoff to the renderer process."
  @spec request_keyframe(t()) :: t()
  def request_keyframe(%__MODULE__{} = correlation),
    do: %{correlation | keyframe_pending?: true}

  @doc "Takes a queued keyframe request so the renderer becomes its sole durable owner."
  @spec take_keyframe_request(t()) :: {boolean(), t()}
  def take_keyframe_request(%__MODULE__{keyframe_pending?: true} = correlation),
    do: {true, %{correlation | keyframe_pending?: false}}

  def take_keyframe_request(%__MODULE__{} = correlation), do: {false, correlation}

  @doc "Resets frontend correlation without making an older receipt fresh again."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = correlation), do: request_keyframe(correlation)

  @doc "Marks a newly ready frontend as requiring a renderer-owned keyframe reset."
  @spec frontend_ready(t()) :: t()
  def frontend_ready(%__MODULE__{} = correlation), do: reset(correlation)

  @doc "Advances the Editor-owned semantic intent revision."
  @spec submit(t()) :: {t(), pos_integer()}
  def submit(%__MODULE__{} = correlation) do
    revision = correlation.latest_intent_revision + 1
    {%{correlation | latest_intent_revision: revision}, revision}
  end

  @doc "Returns the latest submitted render intent revision."
  @spec latest_intent_revision(t()) :: non_neg_integer()
  def latest_intent_revision(%__MODULE__{latest_intent_revision: revision}), do: revision

  @doc "Returns the last accepted render receipt revision."
  @spec last_receipt_revision(t()) :: non_neg_integer()
  def last_receipt_revision(%__MODULE__{last_receipt_revision: revision}), do: revision

  @doc "Returns the last accepted renderer frame sequence."
  @spec last_receipt_sequence(t()) :: non_neg_integer()
  def last_receipt_sequence(%__MODULE__{last_receipt_seq: sequence}), do: sequence

  @doc "Classifies asynchronous receipt ordering and normalizes legacy revision zero."
  @spec classify_receipt(t(), non_neg_integer(), non_neg_integer()) :: freshness()
  def classify_receipt(%__MODULE__{} = correlation, intent_revision, frame_seq)
      when is_integer(intent_revision) and intent_revision >= 0 and is_integer(frame_seq) and
             frame_seq >= 0 do
    revision = normalize_revision(correlation, intent_revision, frame_seq)
    classify_normalized(correlation, revision, frame_seq)
  end

  @doc "Records one accepted asynchronous receipt."
  @spec accept_receipt(t(), non_neg_integer(), non_neg_integer()) :: t()
  def accept_receipt(%__MODULE__{} = correlation, revision, frame_seq)
      when is_integer(revision) and revision >= 0 and is_integer(frame_seq) and frame_seq >= 0 do
    %{
      correlation
      | last_receipt_revision: revision,
        last_receipt_seq: frame_seq
    }
  end

  @doc "Records a synchronous receipt while preserving monotonic ordering evidence."
  @spec accept_synchronous_receipt(t(), non_neg_integer(), non_neg_integer()) :: t()
  def accept_synchronous_receipt(%__MODULE__{} = correlation, revision, frame_seq)
      when is_integer(revision) and revision >= 0 and is_integer(frame_seq) and frame_seq >= 0 do
    %{
      correlation
      | last_receipt_revision: max(correlation.last_receipt_revision, revision),
        last_receipt_seq: max(correlation.last_receipt_seq, frame_seq)
    }
  end

  @spec normalize_revision(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp normalize_revision(%__MODULE__{latest_intent_revision: 0}, 0, frame_seq), do: frame_seq
  defp normalize_revision(%__MODULE__{}, intent_revision, _frame_seq), do: intent_revision

  @spec classify_normalized(t(), non_neg_integer(), non_neg_integer()) :: freshness()
  defp classify_normalized(correlation, revision, _frame_seq)
       when revision < correlation.latest_intent_revision,
       do: {:stale, :superseded_intent}

  defp classify_normalized(correlation, revision, _frame_seq)
       when revision <= correlation.last_receipt_revision,
       do: {:stale, :stale_receipt_revision}

  defp classify_normalized(correlation, _revision, frame_seq)
       when frame_seq <= correlation.last_receipt_seq,
       do: {:stale, :stale_sequence}

  defp classify_normalized(_correlation, revision, _frame_seq), do: {:fresh, revision}
end
