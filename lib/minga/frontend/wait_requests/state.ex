defmodule Minga.Frontend.WaitRequests.State do
  @moduledoc "Internal state owned by the native wait-request tracker."

  alias Minga.Events

  @typedoc "One native waiter bound to its exact target path."
  @type entry :: %{target: String.t(), waiter: pid(), waiter_monitor: reference()}

  @typedoc "All waiter entries sharing one monitored buffer."
  @type request :: %{buffer_monitor: reference(), entries: %{String.t() => entry()}}

  @typedoc "A completion frame waiting for client acknowledgement."
  @type pending_ack :: %{waiter: pid(), waiter_monitor: reference()}

  @typedoc "A timer-backed caller waiting for all completion acknowledgements."
  @type drain_waiter :: {GenServer.from(), reference()}

  @enforce_keys [:events_registry, :requests, :pending_acks, :drain_waiters]
  defstruct [:events_registry, :requests, :pending_acks, :drain_waiters]

  @typedoc "Wait-request tracker state."
  @type t :: %__MODULE__{
          events_registry: Events.registry(),
          requests: %{optional(pid()) => request()},
          pending_acks: %{optional(String.t()) => pending_ack()},
          drain_waiters: [drain_waiter()]
        }

  @doc "Builds an empty tracker state subscribed to the given event registry."
  @spec new(Events.registry()) :: t()
  def new(events_registry) do
    %__MODULE__{
      events_registry: events_registry,
      requests: %{},
      pending_acks: %{},
      drain_waiters: []
    }
  end

  @doc "Records an updated set of active requests."
  @spec requests_updated(t(), %{optional(pid()) => request()}) :: t()
  def requests_updated(%__MODULE__{} = state, requests), do: %{state | requests: requests}

  @doc "Records pending acknowledgements created by emitted completions."
  @spec completions_emitted(t(), %{optional(String.t()) => pending_ack()}) :: t()
  def completions_emitted(%__MODULE__{} = state, pending_acks),
    do: %{state | pending_acks: pending_acks}

  @doc "Records active requests and acknowledgements after a waiter exits."
  @spec waiter_removed(
          t(),
          %{optional(pid()) => request()},
          %{optional(String.t()) => pending_ack()}
        ) :: t()
  def waiter_removed(%__MODULE__{} = state, requests, pending_acks) do
    %{state | requests: requests, pending_acks: pending_acks}
  end

  @doc "Records the remaining acknowledgements after one is received."
  @spec acknowledgement_received(t(), %{optional(String.t()) => pending_ack()}) :: t()
  def acknowledgement_received(%__MODULE__{} = state, pending_acks),
    do: %{state | pending_acks: pending_acks}

  @doc "Adds a caller waiting for all completion acknowledgements."
  @spec drain_waiter_added(t(), drain_waiter()) :: t()
  def drain_waiter_added(%__MODULE__{} = state, drain_waiter),
    do: %{state | drain_waiters: [drain_waiter | state.drain_waiters]}

  @doc "Records callers still waiting after one times out."
  @spec drain_waiter_timed_out(t(), [drain_waiter()]) :: t()
  def drain_waiter_timed_out(%__MODULE__{} = state, remaining),
    do: %{state | drain_waiters: remaining}

  @doc "Clears callers after every pending completion has been acknowledged."
  @spec drain_completed(t()) :: t()
  def drain_completed(%__MODULE__{} = state), do: %{state | drain_waiters: []}
end
