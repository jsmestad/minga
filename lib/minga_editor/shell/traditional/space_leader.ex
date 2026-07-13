defmodule MingaEditor.Shell.Traditional.SpaceLeader do
  @moduledoc """
  Pure lifecycle owner for the TUI CUA space-leader timeout window.

  Each installation advances a generation. Timeout delivery carries that
  generation, so cancellation and replacement remain safe even when an old
  timer message is already in the Editor mailbox.
  """

  @type generation :: non_neg_integer()
  @type t :: %__MODULE__{
          pending: boolean(),
          generation: generation(),
          timer: reference() | nil
        }

  defstruct pending: false, generation: 0, timer: nil

  @doc "Begins a new pending leader window and returns its generation."
  @spec begin(t()) :: {generation(), t()}
  def begin(%__MODULE__{} = leader) do
    generation = leader.generation + 1
    {generation, %__MODULE__{pending: true, generation: generation}}
  end

  @doc "Records the timer handle only for the current pending generation."
  @spec install_timer(t(), generation(), reference()) :: t()
  def install_timer(
        %__MODULE__{pending: true, generation: generation} = leader,
        generation,
        timer
      )
      when is_reference(timer),
      do: %{leader | timer: timer}

  def install_timer(%__MODULE__{} = leader, _generation, _timer), do: leader

  @doc "Expires only the current pending generation."
  @spec expire(t(), generation()) :: {:expired | :stale, t()}
  def expire(%__MODULE__{pending: true, generation: generation} = leader, generation),
    do: {:expired, reset(leader)}

  def expire(%__MODULE__{} = leader, _generation), do: {:stale, leader}

  @doc "Cancels or consumes the current pending window without changing identity."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = leader), do: %{leader | pending: false, timer: nil}

  @doc "Returns whether a space-leader window is pending."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{pending: pending}), do: pending

  @doc "Returns the timer handle for best-effort cancellation by a handler."
  @spec timer(t()) :: reference() | nil
  def timer(%__MODULE__{timer: timer}), do: timer
end
