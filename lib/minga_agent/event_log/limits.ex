defmodule MingaAgent.EventLog.Limits do
  @moduledoc "Count and serialized-byte accounting for outstanding event-log work."

  @enforce_keys [:max_count, :max_bytes]
  defstruct max_count: nil, max_bytes: nil, outstanding_count: 0, outstanding_bytes: 0

  @type t :: %__MODULE__{
          max_count: pos_integer(),
          max_bytes: pos_integer(),
          outstanding_count: non_neg_integer(),
          outstanding_bytes: non_neg_integer()
        }

  @doc "Builds empty outstanding-work limits."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(max_count, max_bytes)
      when is_integer(max_count) and max_count > 0 and is_integer(max_bytes) and max_bytes > 0 do
    %__MODULE__{max_count: max_count, max_bytes: max_bytes}
  end

  @doc "Returns whether one event of the given serialized size can be admitted."
  @spec available?(t(), non_neg_integer()) :: boolean()
  def available?(limits, bytes) when is_integer(bytes) and bytes >= 0 do
    limits.outstanding_count < limits.max_count and
      limits.outstanding_bytes + bytes <= limits.max_bytes
  end

  @doc "Accounts for one newly admitted event."
  @spec admit(t(), non_neg_integer()) :: t()
  def admit(limits, bytes) when is_integer(bytes) and bytes >= 0 do
    %{
      limits
      | outstanding_count: limits.outstanding_count + 1,
        outstanding_bytes: limits.outstanding_bytes + bytes
    }
  end

  @doc "Releases one terminally completed or failed event."
  @spec release(t(), non_neg_integer()) :: t()
  def release(limits, bytes) when is_integer(bytes) and bytes >= 0 do
    %{
      limits
      | outstanding_count: limits.outstanding_count - 1,
        outstanding_bytes: limits.outstanding_bytes - bytes
    }
  end

  @doc "Clears accounting after all outstanding events have terminally failed."
  @spec reset(t()) :: t()
  def reset(limits), do: %{limits | outstanding_count: 0, outstanding_bytes: 0}
end
