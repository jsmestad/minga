defmodule Minga.RenderModel.UI.FloatPopupTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.FloatPopup

  describe "%FloatPopup{}" do
    test "defaults to hidden" do
      model = %FloatPopup{}

      refute model.visible?
      assert model.title == ""
      assert model.lines == []
      assert model.width == 0
      assert model.height == 0
    end

    test "stores semantic float popup content" do
      model = %FloatPopup{
        visible?: true,
        title: "Inspect",
        lines: ["line1"],
        width: 40,
        height: 20
      }

      assert model.visible?
      assert model.title == "Inspect"
      assert model.lines == ["line1"]
      assert model.width == 40
      assert model.height == 20
    end
  end
end
