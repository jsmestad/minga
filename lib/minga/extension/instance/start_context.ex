defmodule Minga.Extension.Instance.StartContext do
  @moduledoc "Phase-owned state for one extension start transition."

  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.Worker

  @enforce_keys [:waiters, :stop_waiters, :previous]
  defstruct [:waiters, :stop_waiters, :previous, runtime: nil, worker: nil]

  @type t :: %__MODULE__{
          waiters: [GenServer.from()],
          stop_waiters: [GenServer.from()],
          previous: term(),
          runtime: Runtime.t() | nil,
          worker: Worker.t() | nil
        }

  @doc "Starts a transition with its callers and previous phase."
  @spec new([GenServer.from()], term()) :: t()
  def new(waiters, previous),
    do: %__MODULE__{waiters: waiters, stop_waiters: [], previous: previous}

  @doc "Adds a caller waiting for the in-flight start."
  @spec join(t(), GenServer.from()) :: t()
  def join(context, from), do: %{context | waiters: [from | context.waiters]}

  @doc "Queues a stop caller behind the in-flight start."
  @spec queue_stop(t(), GenServer.from()) :: t()
  def queue_stop(context, from), do: %{context | stop_waiters: [from | context.stop_waiters]}

  @doc "Records the bounded worker performing the transition."
  @spec begin_work(t(), Worker.t()) :: t()
  def begin_work(context, worker), do: %{context | worker: worker}

  @doc "Records the runtime started by the transition."
  @spec runtime_started(t(), Runtime.t()) :: t()
  def runtime_started(context, runtime), do: %{context | runtime: runtime}

  @doc "Clears completed or failed worker bookkeeping."
  @spec finish_work(t()) :: t()
  def finish_work(context), do: %{context | worker: nil}

  @doc "Clears runtime and worker ownership after the runtime exits during start."
  @spec runtime_exited(t()) :: t()
  def runtime_exited(context), do: %{context | runtime: nil, worker: nil}
end
