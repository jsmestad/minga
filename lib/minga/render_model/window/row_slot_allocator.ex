defmodule Minga.RenderModel.Window.RowSlotAllocator do
  @moduledoc """
  Persistent producer-owned allocator for the 28-bit row slot field.

  Slots are monotonic within `{content_epoch, source_id, identity_kind}` and a
  key keeps its slot for the epoch. Allocation never reuses removed keys.
  """

  @max_slot 0x0FFF_FFFF

  @type scope :: {non_neg_integer(), non_neg_integer(), atom()}
  @type key :: term()
  @type slot :: 0..0x0FFF_FFFF

  defstruct slots: %{}, next: %{}

  @type t :: %__MODULE__{
          slots: %{optional({scope(), key()}) => slot()},
          next: %{optional(scope()) => non_neg_integer()}
        }

  @doc "Creates an empty allocator."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns an existing slot or monotonically allocates one."
  @spec allocate(t(), scope(), key()) :: {:ok, slot(), t()} | :reset_required
  def allocate(%__MODULE__{} = allocator, scope, key) do
    case Map.fetch(allocator.slots, {scope, key}) do
      {:ok, slot} -> {:ok, slot, allocator}
      :error -> allocate_new(allocator, scope, key, Map.get(allocator.next, scope, 0))
    end
  end

  @spec allocate_new(t(), scope(), key(), non_neg_integer()) ::
          {:ok, slot(), t()} | :reset_required
  defp allocate_new(_allocator, _scope, _key, next) when next > @max_slot,
    do: :reset_required

  defp allocate_new(allocator, scope, key, next) do
    updated = %{
      allocator
      | slots: Map.put(allocator.slots, {scope, key}, next),
        next: Map.put(allocator.next, scope, next + 1)
    }

    {:ok, next, updated}
  end
end
