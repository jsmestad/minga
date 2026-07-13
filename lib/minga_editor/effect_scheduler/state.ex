defmodule MingaEditor.EffectScheduler.State do
  @moduledoc "Typed process state for the editor-owned slow-effect scheduler."

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request

  @typedoc "A running request and its supervised worker, if the worker started."
  @type running :: %{task: Task.t() | nil, request: Request.t()}

  @typedoc "One resource lane with a stable scheduling policy."
  @type lane :: %{
          policy: Policy.t(),
          running: running() | nil,
          queue: :queue.queue(Request.t())
        }

  @enforce_keys [
    :task_supervisor,
    :owner,
    :owner_monitor,
    :observer,
    :max_admitted,
    :admitted,
    :lanes,
    :tasks,
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
    :pending,
    :claimed
  ]

  @type t :: %__MODULE__{
          task_supervisor: GenServer.server(),
          owner: pid() | nil,
          owner_monitor: reference() | nil,
          observer: pid() | nil,
          max_admitted: pos_integer(),
          admitted: MapSet.t(reference()),
          lanes: %{optional(Request.resource()) => lane()},
          tasks: %{optional(reference()) => Request.resource()},
          pending: %{optional(reference()) => Outcome.t()},
          claimed: MapSet.t(reference())
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
      pending: %{},
      claimed: MapSet.new()
    }
  end
end
