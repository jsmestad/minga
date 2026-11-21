defmodule MingaEditor.Renderer.WrapLayoutTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Core.WidthOracle.Monospace
  alias MingaEditor.Renderer.WrapLayout

  test "inline virtual text moves the source cursor onto a continuation row" do
    decorations = Decorations.new()
    options = WrapLayout.options(2, %Monospace{}, %{})
    cursor = {0, 1}

    assert {"abcd", [_, _], 0} =
             WrapLayout.measure("abcd", 0, decorations, options, false, cursor)

    {_id, decorations} =
      Decorations.add_virtual_text(decorations, {0, 1},
        segments: [{"XY", Face.new()}],
        placement: :inline
      )

    assert {"aXYbcd", [%{text: "aX"}, %{text: "Yb"}, %{text: "cd"}], 1} =
             WrapLayout.measure("abcd", 0, decorations, options, false, cursor)
  end
end
