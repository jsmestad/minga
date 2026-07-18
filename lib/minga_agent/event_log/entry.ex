defmodule MingaAgent.EventLog.Entry do
  @moduledoc """
  One admitted EventLog item and its delivery contract.

  Critical entries carry the receipt and caller that receive the later durability result. Best-effort entries share ordering and backpressure without requesting an acknowledgment.
  """

  alias MingaAgent.EventLog.EventRecord

  @type delivery :: :best_effort | {:critical, receipt :: reference(), caller :: pid()}

  @enforce_keys [:delivery, :payload_bytes, :record]
  defstruct [:delivery, :payload_bytes, :record]

  @type t :: %__MODULE__{
          delivery: delivery(),
          payload_bytes: non_neg_integer(),
          record: EventRecord.t()
        }

  @doc "Builds a durability-critical queue entry."
  @spec critical(EventRecord.t(), non_neg_integer(), reference(), pid()) :: t()
  def critical(%EventRecord{} = record, payload_bytes, receipt, caller)
      when is_integer(payload_bytes) and payload_bytes >= 0 and is_reference(receipt) and
             is_pid(caller) do
    %__MODULE__{
      delivery: {:critical, receipt, caller},
      payload_bytes: payload_bytes,
      record: record
    }
  end

  @doc "Builds a best-effort queue entry."
  @spec best_effort(EventRecord.t(), non_neg_integer()) :: t()
  def best_effort(%EventRecord{} = record, payload_bytes)
      when is_integer(payload_bytes) and payload_bytes >= 0 do
    %__MODULE__{delivery: :best_effort, payload_bytes: payload_bytes, record: record}
  end
end
