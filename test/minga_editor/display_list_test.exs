defmodule MingaEditor.DisplayListTest do
  use ExUnit.Case, async: true

  alias MingaEditor.DisplayList
  alias Minga.Core.Face

  describe "draw/4" do
    test "creates a draw tuple with default empty style" do
      assert DisplayList.draw(0, 5, "hello") == {0, 5, "hello", Face.new()}
    end

    test "creates a draw tuple with style" do
      d = DisplayList.draw(1, 10, "world", Face.new(fg: 0xFF0000, bold: true))
      assert d == {1, 10, "world", Face.new(fg: 0xFF0000, bold: true)}
    end
  end
end
