defmodule MingaEditor.Renderer.AckLease do
  @moduledoc "Owns the identity and timeout of a frame awaiting frontend acknowledgement."
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Renderer.FrameAttempt

  @enforce_keys [:attempt, :generation, :timer_ref, :output]
  defstruct [:attempt, :generation, :timer_ref, :output]

  @type t :: %__MODULE__{
          attempt: FrameAttempt.t(),
          generation: non_neg_integer(),
          timer_ref: reference(),
          output: Input.t()
        }
  @spec start(FrameAttempt.t(), Input.t(), pos_integer()) :: t()
  def start(%FrameAttempt{} = attempt, %Input{} = output, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    generation = output.caches.recovery_generation

    %__MODULE__{
      attempt: attempt,
      generation: generation,
      timer_ref:
        Process.send_after(self(), {:frame_ack_timeout, generation, attempt.seq}, timeout_ms),
      output: output
    }
  end

  @spec matches?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def matches?(%__MODULE__{} = lease, generation, seq),
    do: lease.generation == generation and lease.attempt.seq == seq

  @spec matches_base?(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: boolean()
  def matches_base?(%__MODULE__{} = lease, generation, seq, last_applied, last_acknowledged_seq) do
    matches?(lease, generation, seq) and last_applied == last_acknowledged_seq
  end

  @spec cancel_timer(t() | nil) :: :ok
  def cancel_timer(nil), do: :ok

  def cancel_timer(%__MODULE__{timer_ref: timer_ref}) do
    Process.cancel_timer(timer_ref)
    :ok
  end
end
