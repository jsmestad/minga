defmodule MingaEditor.Effect.Outcome do
  @moduledoc """
  Lifecycle or terminal outcome for an admitted slow effect.

  `queued` and `running` are lifecycle feedback. `canceled`, `failed`, `stale`,
  and `completed` are terminal. Domain handlers may reclassify a completed
  worker result as stale while atomically applying it to current editor state.
  """

  alias MingaEditor.Effect.Request

  @enforce_keys [:request, :status]
  defstruct [:request, :status, :result, :reason]

  @type lifecycle_status :: :queued | :running
  @type terminal_status :: :canceled | :failed | :stale | :completed
  @type status :: lifecycle_status() | terminal_status()

  @type t :: %__MODULE__{
          request: Request.t(),
          status: status(),
          result: term() | nil,
          reason: term() | nil
        }

  @doc "Builds a queued lifecycle outcome."
  @spec queued(Request.t()) :: t()
  def queued(%Request{} = request), do: %__MODULE__{request: request, status: :queued}

  @doc "Builds a running lifecycle outcome."
  @spec running(Request.t()) :: t()
  def running(%Request{} = request), do: %__MODULE__{request: request, status: :running}

  @doc "Builds a completed terminal candidate."
  @spec completed(Request.t(), term()) :: t()
  def completed(%Request{} = request, result) do
    %__MODULE__{request: request, status: :completed, result: result}
  end

  @doc "Builds a failed terminal candidate."
  @spec failed(Request.t(), term()) :: t()
  def failed(%Request{} = request, reason) do
    %__MODULE__{request: request, status: :failed, reason: reason}
  end

  @doc "Builds a canceled terminal candidate."
  @spec canceled(Request.t(), term()) :: t()
  def canceled(%Request{} = request, reason) do
    %__MODULE__{request: request, status: :canceled, reason: reason}
  end

  @doc "Reclassifies an outcome as stale after domain-owned application."
  @spec stale(t(), term()) :: t()
  def stale(%__MODULE__{} = outcome, reason) do
    %{outcome | status: :stale, reason: reason}
  end

  @doc "Returns whether the outcome is terminal."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}) do
    status in [:canceled, :failed, :stale, :completed]
  end
end
