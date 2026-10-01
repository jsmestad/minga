defmodule MingaAgent.Tool.Output.Range do
  @moduledoc "Explicit zero-based bounds for a full capture, requested slice, or retained page."

  @type kind :: :full | :requested | :page | :captured_prefix
  @type unit :: :bytes | :lines | :items
  @type total :: non_neg_integer() | :unknown
  @type t :: %__MODULE__{
          kind: kind(),
          unit: unit(),
          start: non_neg_integer(),
          count: non_neg_integer(),
          total: total()
        }

  @enforce_keys [:kind, :unit, :start, :count, :total]
  defstruct [:kind, :unit, :start, :count, :total]

  @doc "Builds valid bounds. A known total must contain the selected interval."
  @spec new(kind(), unit(), non_neg_integer(), non_neg_integer(), total()) ::
          {:ok, t()} | {:error, :invalid_range}
  def new(kind, unit, start, count, total)
      when kind in [:full, :requested, :page, :captured_prefix] and
             unit in [:bytes, :lines, :items] and
             is_integer(start) and start >= 0 and is_integer(count) and count >= 0 do
    build(kind, unit, start, count, total)
  end

  def new(_kind, _unit, _start, _count, _total), do: {:error, :invalid_range}

  @spec build(kind(), unit(), non_neg_integer(), non_neg_integer(), total()) ::
          {:ok, t()} | {:error, :invalid_range}
  defp build(:full, unit, 0, count, count) do
    {:ok, %__MODULE__{kind: :full, unit: unit, start: 0, count: count, total: count}}
  end

  defp build(:full, _unit, _start, _count, _total), do: {:error, :invalid_range}

  defp build(kind, unit, start, count, :unknown) do
    {:ok, %__MODULE__{kind: kind, unit: unit, start: start, count: count, total: :unknown}}
  end

  defp build(kind, unit, start, count, total) when is_integer(total) and total >= start + count do
    {:ok, %__MODULE__{kind: kind, unit: unit, start: start, count: count, total: total}}
  end

  defp build(_kind, _unit, _start, _count, _total), do: {:error, :invalid_range}
end
