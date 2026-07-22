defmodule MingaEditor.Renderer.FrameAttempt do
  @moduledoc "Carries one renderer attempt identity across scheduling and recovery."
  alias MingaEditor.RenderPipeline.Intent

  @enforce_keys [:intent, :seq, :pushed_at]
  defstruct [:intent, :seq, :pushed_at]

  @type t :: %__MODULE__{
          intent: Intent.t(),
          seq: non_neg_integer(),
          pushed_at: integer()
        }

  @spec new(Intent.t(), non_neg_integer(), integer()) :: t()
  def new(%Intent{} = intent, seq, pushed_at)
      when is_integer(seq) and seq >= 0 and is_integer(pushed_at) do
    %__MODULE__{intent: intent, seq: seq, pushed_at: pushed_at}
  end

  @spec force_keyframe(t()) :: t()
  def force_keyframe(%__MODULE__{} = attempt),
    do: %{attempt | intent: Intent.force_keyframe(attempt.intent)}

  @spec latest(t() | nil, t()) :: t()
  def latest(%__MODULE__{seq: pending_seq} = pending, %__MODULE__{seq: fallback_seq})
      when pending_seq > fallback_seq,
      do: pending

  def latest(_pending, %__MODULE__{} = fallback),
    do: %{fallback | seq: max(System.unique_integer([:positive, :monotonic]), fallback.seq + 1)}
end
