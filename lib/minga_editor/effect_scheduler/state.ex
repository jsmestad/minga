defmodule MingaEditor.EffectScheduler.State do
  @moduledoc "Typed process state for the editor-owned slow-effect scheduler."

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler.Lane

  @typedoc "Scheduler-owned worker identity kept outside lane values."
  @type task_entry :: {Request.resource(), Request.id(), Task.t()}

  @enforce_keys [
    :task_supervisor,
    :owner,
    :owner_monitor,
    :observer,
    :max_admitted,
    :admitted,
    :lanes,
    :tasks,
    :timers,
    :pending,
    :claimed
  ]
  defstruct [
    :task_supervisor,
    :owner,
    :owner_monitor,
    :observer,
    :max_admitted,
    :admitted,
    :lanes,
    :tasks,
    :timers,
    :pending,
    :claimed
  ]

  @type t :: %__MODULE__{
          task_supervisor: GenServer.server(),
          owner: pid() | nil,
          owner_monitor: reference() | nil,
          observer: pid() | nil,
          max_admitted: pos_integer(),
          admitted: MapSet.t(Request.id()),
          lanes: %{optional(Request.resource()) => Lane.t()},
          tasks: %{optional(reference()) => task_entry()},
          timers: %{optional(reference()) => Request.id()},
          pending: %{optional(Request.id()) => Outcome.t()},
          claimed: MapSet.t(Request.id())
        }

  @doc "Builds initial scheduler state from validated process options."
  @spec new(GenServer.server(), pid() | nil, pos_integer()) :: t()
  def new(task_supervisor, observer, max_admitted) do
    %__MODULE__{
      task_supervisor: task_supervisor,
      owner: nil,
      owner_monitor: nil,
      observer: observer,
      max_admitted: max_admitted,
      admitted: MapSet.new(),
      lanes: %{},
      tasks: %{},
      timers: %{},
      pending: %{},
      claimed: MapSet.new()
    }
  end
end
