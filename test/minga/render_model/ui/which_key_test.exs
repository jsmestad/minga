defmodule Minga.RenderModel.UI.WhichKeyTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.WhichKey

  test "a hidden panel has no path, breadcrumb, hints or entries" do
    assert %WhichKey{
             visible: false,
             path: "",
             breadcrumb: [],
             count: %{text: "", tone: :muted},
             hints: [],
             entries: []
           } =
             %WhichKey{visible: false}
  end
end
