defmodule MingaEditor.Effect.Outcome do
  @moduledoc """
  Lifecycle or terminal outcome for an admitted slow effect.

  `queued` and `running` are lifecycle feedback. `canceled`, `failed`, `stale`,
  and `completed` are terminal. Domain handlers may reclassify a completed
  worker result as stale while atomically applying it to current editor state.
  """

  alias MingaEditor.Effect.Request
  alias MingaEditor.State.OperationQueue

  @enforce_keys [:request, :value]
  defstruct [:request, :value]

  @type value ::
          {:queued, OperationQueue.t()}
          | :running
          | {:completed, term()}
          | {:failed, term()}
          | {:canceled, term()}
          | {:stale, term()}

  @type t :: %__MODULE__{
          request: Request.t(),
          value: value()
        }

  @doc "Builds a queued lifecycle outcome with scheduler-authored queue metadata."
  @spec queued(Request.t(), pos_integer(), pos_integer()) :: t()
  def queued(%Request{} = request, position, total) do
    %__MODULE__{
      request: request,
      value: {:queued, OperationQueue.new!(position, total)}
    }
  end

  @doc "Builds a running lifecycle outcome."
  @spec running(Request.t()) :: t()
  def running(%Request{} = request), do: %__MODULE__{request: request, value: :running}

  @doc "Builds a completed terminal candidate."
  @spec completed(Request.t(), term()) :: t()
  def completed(%Request{} = request, result) do
    %__MODULE__{request: request, value: {:completed, result}}
  end

  @doc "Builds a failed terminal candidate."
  @spec failed(Request.t(), term()) :: t()
  def failed(%Request{} = request, reason) do
    %__MODULE__{request: request, value: {:failed, reason}}
  end

  @doc "Builds a canceled terminal candidate."
  @spec canceled(Request.t(), term()) :: t()
  def canceled(%Request{} = request, reason) do
    %__MODULE__{request: request, value: {:canceled, reason}}
  end

  @doc "Reclassifies an outcome as stale after domain-owned application."
  @spec stale(t(), term()) :: t()
  def stale(%__MODULE__{} = outcome, reason) do
    %__MODULE__{request: outcome.request, value: {:stale, reason}}
  end

  @doc "Returns whether the outcome is terminal."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{value: :running}), do: false
  def terminal?(%__MODULE__{value: {:queued, %OperationQueue{}}}), do: false

  def terminal?(%__MODULE__{value: {status, _payload}})
      when status in [:completed, :failed, :canceled, :stale],
      do: true
end
