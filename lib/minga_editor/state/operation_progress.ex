defmodule MingaEditor.State.OperationProgress do
  @moduledoc "Domain-authored completed-unit progress for an operation."

  @enforce_keys [:current, :total]
  @derive JSON.Encoder
  defstruct [:current, :total]

  @type t :: %__MODULE__{current: non_neg_integer(), total: pos_integer()}
  @type error :: :invalid_progress_range

  @max_wire_value 0xFFFFFFFF

  @doc "Builds progress when current is non-negative and does not exceed a positive wire-safe total."
  @spec new(integer(), integer()) :: {:ok, t()} | {:error, error()}
  def new(current, total)
      when is_integer(current) and is_integer(total) and current >= 0 and total > 0 and
             current <= total and total <= @max_wire_value do
    {:ok, %__MODULE__{current: current, total: total}}
  end

  def new(_current, _total), do: {:error, :invalid_progress_range}

  @doc "Builds valid progress or raises for an impossible range."
  @spec new!(integer(), integer()) :: t()
  def new!(current, total) do
    case new(current, total) do
      {:ok, progress} -> progress
      {:error, :invalid_progress_range} -> raise ArgumentError, "invalid operation progress range"
    end
  end
end
