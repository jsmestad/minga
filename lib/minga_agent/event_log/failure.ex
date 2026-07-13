defmodule MingaAgent.EventLog.Failure do
  @moduledoc "Typed, observable failure of EventLog admission or durable commitment."

  alias MingaAgent.EventLog.EventRecord

  @enforce_keys [:stage, :event_type, :reason]
  defstruct [:stage, :event_type, :reason, :receipt]

  @type stage :: :admission | :persistence
  @type t :: %__MODULE__{
          stage: stage(),
          event_type: EventRecord.event_type(),
          reason: term(),
          receipt: reference() | nil
        }

  @doc "Builds an admission failure, which has no durability receipt."
  @spec admission(EventRecord.event_type(), term()) :: t()
  def admission(event_type, reason) do
    %__MODULE__{stage: :admission, event_type: event_type, reason: reason}
  end

  @doc "Builds a post-admission persistence failure."
  @spec persistence(reference(), EventRecord.event_type(), term()) :: t()
  def persistence(receipt, event_type, reason) when is_reference(receipt) do
    %__MODULE__{
      stage: :persistence,
      event_type: event_type,
      reason: reason,
      receipt: receipt
    }
  end

  @doc "Removes the original receipt before replaying a retained failure to a later subscriber."
  @spec retained(t()) :: t()
  def retained(failure), do: %{failure | receipt: nil}
end
