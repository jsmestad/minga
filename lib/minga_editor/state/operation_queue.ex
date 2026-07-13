defmodule MingaEditor.State.OperationQueue do
  @moduledoc "Scheduler-authored queue position metadata for an operation."

  @enforce_keys [:position, :total]
  @derive JSON.Encoder
  defstruct [:position, :total]

  @type t :: %__MODULE__{position: pos_integer(), total: pos_integer()}
  @type error :: :invalid_queue_range

  @max_wire_value 0xFFFF

  @doc "Builds queue metadata when the position is within the positive wire-safe queue total."
  @spec new(integer(), integer()) :: {:ok, t()} | {:error, error()}
  def new(position, total)
      when is_integer(position) and is_integer(total) and position > 0 and total > 0 and
             position <= total and total <= @max_wire_value do
    {:ok, %__MODULE__{position: position, total: total}}
  end

  def new(_position, _total), do: {:error, :invalid_queue_range}

  @doc "Builds valid queue metadata or raises for an impossible range."
  @spec new!(integer(), integer()) :: t()
  def new!(position, total) do
    case new(position, total) do
      {:ok, queue} -> queue
      {:error, :invalid_queue_range} -> raise ArgumentError, "invalid operation queue range"
    end
  end
end
