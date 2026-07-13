defmodule MingaEditor.State.RenderCorrelation do
  @moduledoc "Immutable Editor-owned render scheduling, keyframe, and receipt-ordering state."

  defstruct timer: nil,
            keyframe_pending?: false,
            latest_intent_revision: 0,
            last_receipt_revision: 0,
            last_receipt_seq: 0

  @type t :: %__MODULE__{
          timer: reference() | nil,
          keyframe_pending?: boolean(),
          latest_intent_revision: non_neg_integer(),
          last_receipt_revision: non_neg_integer(),
          last_receipt_seq: non_neg_integer()
        }

  @type freshness_reason :: :superseded_intent | :stale_receipt_revision | :stale_sequence
  @type freshness :: {:fresh, non_neg_integer()} | {:stale, freshness_reason()}

  @doc "Returns initial render correlation state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Admits one render timer or coalesces into the already scheduled timer."
  @spec schedule(t(), reference()) :: {:scheduled | :coalesced, t()}
  def schedule(%__MODULE__{timer: nil} = correlation, timer) when is_reference(timer),
    do: {:scheduled, %{correlation | timer: timer}}

  def schedule(%__MODULE__{} = correlation, timer) when is_reference(timer),
    do: {:coalesced, correlation}

  @doc "Returns whether a render timer currently owns the throttle window."
  @spec scheduled?(t()) :: boolean()
  def scheduled?(%__MODULE__{timer: timer}), do: is_reference(timer)

  @doc "Clears the render timer after synchronous rendering or timer delivery."
  @spec clear_timer(t()) :: t()
  def clear_timer(%__MODULE__{} = correlation), do: %{correlation | timer: nil}

  @doc "Marks the next completed render as requiring a keyframe."
  @spec request_keyframe(t()) :: t()
  def request_keyframe(%__MODULE__{} = correlation),
    do: %{correlation | keyframe_pending?: true}

  @doc "Resets frontend correlation without making an older receipt fresh again."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = correlation), do: request_keyframe(correlation)

  @doc "Marks a newly ready frontend as requiring a correlated keyframe."
  @spec frontend_ready(t()) :: t()
  def frontend_ready(%__MODULE__{} = correlation), do: reset(correlation)

  @doc "Returns whether render intent construction must force a keyframe."
  @spec force_keyframe?(t()) :: boolean()
  def force_keyframe?(%__MODULE__{keyframe_pending?: pending?}), do: pending?

  @doc "Advances the Editor-owned semantic intent revision."
  @spec submit(t()) :: {t(), pos_integer()}
  def submit(%__MODULE__{} = correlation) do
    revision = correlation.latest_intent_revision + 1
    {%{correlation | latest_intent_revision: revision}, revision}
  end

  @doc "Classifies asynchronous receipt ordering and normalizes legacy revision zero."
  @spec classify_receipt(t(), non_neg_integer(), non_neg_integer()) :: freshness()
  def classify_receipt(%__MODULE__{} = correlation, intent_revision, frame_seq)
      when is_integer(intent_revision) and intent_revision >= 0 and is_integer(frame_seq) and
             frame_seq >= 0 do
    revision = normalize_revision(correlation, intent_revision, frame_seq)
    classify_normalized(correlation, revision, frame_seq)
  end

  @doc "Records one accepted asynchronous receipt and clears a fulfilled keyframe request."
  @spec accept_receipt(t(), non_neg_integer(), non_neg_integer(), boolean()) :: t()
  def accept_receipt(%__MODULE__{} = correlation, revision, frame_seq, keyframe?)
      when is_integer(revision) and revision >= 0 and is_integer(frame_seq) and frame_seq >= 0 and
             is_boolean(keyframe?) do
    %{
      correlation
      | keyframe_pending?: pending_after_receipt?(correlation, keyframe?),
        last_receipt_revision: revision,
        last_receipt_seq: frame_seq
    }
  end

  @doc "Records a synchronous receipt while preserving monotonic ordering evidence."
  @spec accept_synchronous_receipt(t(), non_neg_integer(), non_neg_integer(), boolean()) :: t()
  def accept_synchronous_receipt(%__MODULE__{} = correlation, revision, frame_seq, keyframe?)
      when is_integer(revision) and revision >= 0 and is_integer(frame_seq) and frame_seq >= 0 and
             is_boolean(keyframe?) do
    %{
      correlation
      | keyframe_pending?: pending_after_receipt?(correlation, keyframe?),
        last_receipt_revision: max(correlation.last_receipt_revision, revision),
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

  @spec pending_after_receipt?(t(), boolean()) :: boolean()
  defp pending_after_receipt?(%__MODULE__{keyframe_pending?: false}, _keyframe?), do: false
  defp pending_after_receipt?(%__MODULE__{keyframe_pending?: true}, keyframe?), do: not keyframe?
end
