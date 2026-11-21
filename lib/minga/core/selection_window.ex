defmodule Minga.Core.SelectionWindow do
  @moduledoc "Projects a centered window of an ordered selection list."

  @doc "Returns the visible items and the selection's offset in that window."
  @spec visible([item], non_neg_integer(), non_neg_integer()) :: {[item], non_neg_integer()}
        when item: term()
  def visible([], _selected, _capacity), do: {[], 0}
  def visible(_items, _selected, 0), do: {[], 0}

  def visible(items, selected, capacity) do
    total = length(items)

    if total <= capacity do
      {items, selected}
    else
      start = max(0, min(selected - div(capacity, 2), total - capacity))
      {Enum.slice(items, start, capacity), selected - start}
    end
  end
end
