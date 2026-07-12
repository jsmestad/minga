defmodule Minga.Parser.RequestState do
  @moduledoc """
  Owned state for sequence-fenced synchronous parser requests.

  Request handlers perform replies and Port writes; this module alone constructs
  and updates the request aggregate installed by `Minga.Parser.Manager`.
  """

  @type command_builder :: (pos_integer(), non_neg_integer() -> binary())
  @type deferred_request :: %{
          from: GenServer.from(),
          buffer: pid(),
          command_builder: command_builder(),
          required_sequence: non_neg_integer() | nil
        }
  @type in_flight_request :: %{from: GenServer.from(), buffer: pid(), token: reference()}

  defstruct next_id: 1, deferred: %{}, fences: %{}, in_flight: %{}

  @type t :: %__MODULE__{
          next_id: pos_integer(),
          deferred: %{reference() => deferred_request()},
          fences: %{reference() => pid()},
          in_flight: %{non_neg_integer() => in_flight_request()}
        }

  @doc "Constructs empty parser request state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds a deferred request and its buffer fence."
  @spec defer(t(), reference(), deferred_request()) :: t()
  def defer(%__MODULE__{} = state, token, request) when is_reference(token) do
    %{
      state
      | deferred: Map.put(state.deferred, token, request),
        fences: Map.put(state.fences, token, request.buffer)
    }
  end

  @doc "Consumes a matching fence and records the snapshot sequence."
  @spec satisfy_fence(t(), reference(), pid(), non_neg_integer()) :: {:ok, t()} | :stale
  def satisfy_fence(%__MODULE__{} = state, token, buffer, sequence) do
    case Map.pop(state.fences, token) do
      {^buffer, fences} ->
        deferred =
          Map.update(state.deferred, token, nil, &Map.put(&1, :required_sequence, sequence))
          |> Map.reject(fn {_token, request} -> is_nil(request) end)

        {:ok, %{state | fences: fences, deferred: deferred}}

      {_other, _fences} ->
        :stale
    end
  end

  @doc "Splits ready deferred requests for one synchronized buffer."
  @spec take_ready(t(), pid(), (deferred_request() -> boolean())) ::
          {[{reference(), deferred_request()}], t()}
  def take_ready(%__MODULE__{} = state, buffer, ready?) when is_function(ready?, 1) do
    {ready, waiting} =
      Enum.split_with(state.deferred, fn {_token, request} ->
        request.buffer == buffer and ready?.(request)
      end)

    {ready, %{state | deferred: Map.new(waiting)}}
  end

  @doc "Allocates an ID and records an emitted request."
  @spec emit(t(), in_flight_request()) :: {pos_integer(), t()}
  def emit(%__MODULE__{} = state, request) do
    id = state.next_id
    {id, %{state | next_id: id + 1, in_flight: Map.put(state.in_flight, id, request)}}
  end

  @doc "Returns the ID that will be allocated to the next emitted request."
  @spec next_id(t()) :: pos_integer()
  def next_id(%__MODULE__{next_id: id}), do: id

  @doc "Removes a deferred request by token."
  @spec pop_deferred(t(), reference()) :: {deferred_request() | nil, t()}
  def pop_deferred(%__MODULE__{} = state, token) do
    {request, deferred} = Map.pop(state.deferred, token)
    {request, %{state | deferred: deferred}}
  end

  @doc "Removes a fence by token."
  @spec drop_fence(t(), reference()) :: t()
  def drop_fence(%__MODULE__{} = state, token),
    do: %{state | fences: Map.delete(state.fences, token)}

  @doc "Removes an in-flight request by parser request ID."
  @spec pop_in_flight(t(), non_neg_integer()) :: {in_flight_request() | nil, t()}
  def pop_in_flight(%__MODULE__{} = state, id) do
    {request, in_flight} = Map.pop(state.in_flight, id)
    {request, %{state | in_flight: in_flight}}
  end

  @doc "Removes the in-flight request associated with a fence token."
  @spec pop_in_flight_by_token(t(), reference()) :: {in_flight_request() | nil, t()}
  def pop_in_flight_by_token(%__MODULE__{} = state, token) do
    case Enum.find(state.in_flight, fn {_id, request} -> request.token == token end) do
      nil -> {nil, state}
      {id, _request} -> pop_in_flight(state, id)
    end
  end

  @doc "Removes every deferred, fenced, and in-flight request for one buffer."
  @spec take_buffer(t(), pid()) :: {[GenServer.from()], t()}
  def take_buffer(%__MODULE__{} = state, buffer) do
    {failed_deferred, kept_deferred} =
      Enum.split_with(state.deferred, fn {_token, request} -> request.buffer == buffer end)

    failed_tokens = MapSet.new(failed_deferred, &elem(&1, 0))

    {failed_in_flight, kept_in_flight} =
      Enum.split_with(state.in_flight, fn {_id, request} -> request.buffer == buffer end)

    fences =
      Map.reject(state.fences, fn {token, pid} ->
        pid == buffer or MapSet.member?(failed_tokens, token)
      end)

    replies =
      Enum.map(failed_deferred, fn {_token, request} -> request.from end) ++
        Enum.map(failed_in_flight, fn {_id, request} -> request.from end)

    {replies,
     %{
       state
       | deferred: Map.new(kept_deferred),
         fences: fences,
         in_flight: Map.new(kept_in_flight)
     }}
  end

  @doc "Removes every deferred, fenced, and in-flight request."
  @spec take_all(t()) :: {[GenServer.from()], t()}
  def take_all(%__MODULE__{} = state) do
    replies =
      Enum.map(state.deferred, fn {_token, request} -> request.from end) ++
        Enum.map(state.in_flight, fn {_id, request} -> request.from end)

    {replies, %{state | deferred: %{}, fences: %{}, in_flight: %{}}}
  end
end
