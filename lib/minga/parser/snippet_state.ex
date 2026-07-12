defmodule Minga.Parser.SnippetState do
  @moduledoc """
  Owned state for isolated synchronous snippet-highlight requests.
  """

  alias Minga.Language.Highlight.Span

  @snippet_buffer_id_start 4_000_000_000

  @type pending_highlight :: %{
          from: GenServer.from(),
          names: [String.t()] | nil,
          spans: [Span.t()] | nil,
          timer_ref: reference()
        }

  defstruct next_buffer_id: @snippet_buffer_id_start, pending: %{}

  @type t :: %__MODULE__{
          next_buffer_id: non_neg_integer(),
          pending: %{non_neg_integer() => pending_highlight()}
        }

  @doc "Constructs empty snippet request state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the parser buffer ID allocated by the next request."
  @spec next_buffer_id(t()) :: non_neg_integer()
  def next_buffer_id(%__MODULE__{next_buffer_id: buffer_id}), do: buffer_id

  @doc "Allocates an isolated parser buffer and records its request."
  @spec allocate(t(), pending_highlight()) :: {non_neg_integer(), t()}
  def allocate(%__MODULE__{} = state, request) do
    id = state.next_buffer_id
    {id, %{state | next_buffer_id: id + 1, pending: Map.put(state.pending, id, request)}}
  end

  @doc "Fetches a pending snippet request."
  @spec fetch(t(), non_neg_integer()) :: {:ok, pending_highlight()} | :error
  def fetch(%__MODULE__{} = state, buffer_id), do: Map.fetch(state.pending, buffer_id)

  @doc "Updates a pending snippet request."
  @spec put(t(), non_neg_integer(), pending_highlight()) :: t()
  def put(%__MODULE__{} = state, buffer_id, request),
    do: %{state | pending: Map.put(state.pending, buffer_id, request)}

  @doc "Removes a pending snippet request."
  @spec pop(t(), non_neg_integer()) :: {pending_highlight() | nil, t()}
  def pop(%__MODULE__{} = state, buffer_id) do
    {request, pending} = Map.pop(state.pending, buffer_id)
    {request, %{state | pending: pending}}
  end

  @doc "Removes every pending snippet request."
  @spec take_all(t()) :: {[pending_highlight()], t()}
  def take_all(%__MODULE__{} = state),
    do: {Map.values(state.pending), %{state | pending: %{}}}
end
