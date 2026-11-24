defmodule MingaEditor.Shell.Traditional.SpaceLeader do
  @moduledoc """
  Pure lifecycle owner for the TUI CUA space-leader timeout window.

  Each installation advances a generation. Timeout delivery carries that
  generation, so cancellation and replacement remain safe even when an old
  timer message is already in the Editor mailbox.

  The window records the buffer that took the typed space, so a leader key retracts the space from that buffer only. It is nil when the focused surface took no text, and then there is nothing to retract.

  The GUI path has no window: the frontend holds SPC, sends it as an ordinary key when the hold outlasts its grace period, and sends a retract with the next key. `held_space` records where that ordinary space went, independently of the TUI window, until the next key consumes or clears it.
  """

  alias MingaEditor.Input.CUA.SpaceTarget

  @type generation :: non_neg_integer()
  @type t :: %__MODULE__{
          pending: boolean(),
          generation: generation(),
          timer: reference() | nil,
          space_buffer: pid() | nil,
          held_space: SpaceTarget.t() | nil
        }

  defstruct pending: false, generation: 0, timer: nil, space_buffer: nil, held_space: nil

  @doc "Begins a new pending leader window that records the buffer holding the typed space, or nil, and returns its generation."
  @spec begin(t(), pid() | nil) :: {generation(), t()}
  def begin(%__MODULE__{} = leader, space_buffer)
      when is_pid(space_buffer) or is_nil(space_buffer) do
    generation = leader.generation + 1

    {generation, %__MODULE__{pending: true, generation: generation, space_buffer: space_buffer}}
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
  def reset(%__MODULE__{} = leader),
    do: %{leader | pending: false, timer: nil, space_buffer: nil}

  @doc "Returns whether a space-leader window is pending."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{pending: pending}), do: pending

  @doc "Returns the buffer that holds the typed space of the pending window, or nil when the focused surface took no text."
  @spec space_buffer(t()) :: pid() | nil
  def space_buffer(%__MODULE__{space_buffer: buffer}), do: buffer

  @doc "Returns the timer handle for best-effort cancellation by a handler."
  @spec timer(t()) :: reference() | nil
  def timer(%__MODULE__{timer: timer}), do: timer

  @doc "Records where a frontend-sent space went, or nil when the last key was not a space."
  @spec hold_space(t(), SpaceTarget.t() | nil) :: t()
  def hold_space(%__MODULE__{} = leader, target), do: %{leader | held_space: target}

  @doc "Returns where the last frontend-sent space went, or nil."
  @spec held_space(t()) :: SpaceTarget.t() | nil
  def held_space(%__MODULE__{held_space: target}), do: target
end
