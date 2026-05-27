defmodule Minga.RenderModel.UI.WhichKeyTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.WhichKey

  describe "%WhichKey{}" do
    test "requires visible" do
      wk = %WhichKey{visible: false}

      assert wk.visible == false
      assert wk.prefix == ""
      assert wk.page == 0
      assert wk.page_count == 1
      assert wk.bindings == []
    end

    test "accepts all fields" do
      bindings = [%{key: "j", description: "down", kind: :command, icon: nil}]

      wk = %WhichKey{
        visible: true,
        prefix: "SPC",
        page: 1,
        page_count: 3,
        bindings: bindings
      }

      assert wk.visible == true
      assert wk.prefix == "SPC"
      assert wk.page == 1
      assert wk.page_count == 3
      assert length(wk.bindings) == 1
    end
  end
end
