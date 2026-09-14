defmodule MingaEditor.NativeIPC.Server.State do
  @moduledoc "Internal state owned by the native IPC endpoint server."

  alias MingaEditor.NativeIPC.Endpoint
  alias MingaEditor.NativeIPC.OperationLedger

  defmodule Waiter do
    @moduledoc false
    @enforce_keys [:ref, :operation_id, :pid, :monitor]
    defstruct [:ref, :operation_id, :pid, :monitor]

    @type t :: %__MODULE__{
            ref: reference(),
            operation_id: pos_integer(),
            pid: pid(),
            monitor: reference()
          }
  end

  @enforce_keys [:endpoint, :acceptor]
  defstruct [:endpoint, :acceptor, ledger: %OperationLedger{}, waiters: %{}, waiter_monitors: %{}]

  @typedoc "Native IPC endpoint server state."
  @type t :: %__MODULE__{
          endpoint: Endpoint.t(),
          acceptor: pid(),
          ledger: OperationLedger.t(),
          waiters: %{optional(reference()) => Waiter.t()},
          waiter_monitors: %{optional(reference()) => reference()}
        }

  @doc "Builds server state after the endpoint and acceptor are ready."
  @spec new(Endpoint.t(), pid()) :: t()
  def new(%Endpoint{} = endpoint, acceptor) when is_pid(acceptor) do
    %__MODULE__{endpoint: endpoint, acceptor: acceptor}
  end

  @doc "Registers one bounded receipt waiter and monitors its connection process."
  @spec register_waiter(t(), pos_integer(), pid(), reference(), pos_integer()) ::
          {:ok, t()} | {:error, :waiter_capacity}
  def register_waiter(%__MODULE__{} = state, operation_id, pid, ref, maximum)
      when is_pid(pid) and is_reference(ref) and maximum > 0 do
    if map_size(state.waiters) >= maximum do
      {:error, :waiter_capacity}
    else
      monitor = Process.monitor(pid)
      waiter = %Waiter{ref: ref, operation_id: operation_id, pid: pid, monitor: monitor}

      {:ok,
       %{
         state
         | waiters: Map.put(state.waiters, ref, waiter),
           waiter_monitors: Map.put(state.waiter_monitors, monitor, ref)
       }}
    end
  end

  @doc "Removes one waiter by public reference."
  @spec remove_waiter(t(), reference()) :: {Waiter.t() | nil, t()}
  def remove_waiter(%__MODULE__{} = state, ref) when is_reference(ref) do
    case Map.pop(state.waiters, ref) do
      {nil, waiters} ->
        {nil, %{state | waiters: waiters}}

      {%Waiter{} = waiter, waiters} ->
        Process.demonitor(waiter.monitor, [:flush])

        {waiter,
         %{
           state
           | waiters: waiters,
             waiter_monitors: Map.delete(state.waiter_monitors, waiter.monitor)
         }}
    end
  end

  @doc "Removes the waiter whose connection monitor went down."
  @spec remove_waiter_monitor(t(), reference()) :: {Waiter.t() | nil, t()}
  def remove_waiter_monitor(%__MODULE__{} = state, monitor) when is_reference(monitor) do
    case Map.get(state.waiter_monitors, monitor) do
      nil -> {nil, state}
      ref -> remove_waiter(state, ref)
    end
  end

  @doc "Takes every waiter observing one completed operation."
  @spec take_operation_waiters(t(), pos_integer()) :: {[Waiter.t()], t()}
  def take_operation_waiters(%__MODULE__{} = state, operation_id) do
    refs =
      state.waiters
      |> Enum.filter(fn {_ref, waiter} -> waiter.operation_id == operation_id end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(refs, {[], state}, fn ref, {taken, current} ->
      case remove_waiter(current, ref) do
        {%Waiter{} = waiter, updated} -> {[waiter | taken], updated}
        {nil, updated} -> {taken, updated}
      end
    end)
  end
end
