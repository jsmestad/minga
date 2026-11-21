defmodule Minga.Core.SelectionWindowTest do
  use ExUnit.Case, async: true

  alias Minga.Core.SelectionWindow

  test "keeps the selection visible at the start, middle, and end" do
    items = Enum.to_list(0..14)

    for {selected, capacity, first, last, offset} <- [
          {0, 10, 0, 9, 0},
          {7, 10, 2, 11, 5},
          {14, 10, 5, 14, 9},
          {12, 5, 10, 14, 2}
        ] do
      assert SelectionWindow.visible(items, selected, capacity) ==
               {Enum.to_list(first..last), offset}
    end
  end

  test "keeps all rows when they fit and shows none at zero capacity" do
    items = ~w(a b c d)

    assert SelectionWindow.visible(items, 3, 4) == {items, 3}
    assert SelectionWindow.visible(items, 2, 0) == {[], 0}
  end
end
